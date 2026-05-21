#
# Shared library for Terraform import scripts (import_preexist).
# Source this from scripts in the parent directory; provides bootstrap, dir/init,
# lock parsing, import_one_resource, and import_batch.
#
# Usage from a script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/common/lib_import_common.sh"
#   import_parse_args "$@"
#   import_validate_env
#   LAYER_DIR="$REPO_ROOT/..."; import_ensure_dir_and_cd "$LAYER_DIR" "LayerName"
#   import_init_soft   # or import_init_strict
#   import_one_resource "addr" "id"   # or import_batch "addr:id" ...
#

# Resolve REPO_ROOT from lib location if not set (common/ -> import_preexist -> terraform -> orchestration -> repo)
_import_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$_import_lib_dir/../../../.." && pwd)}"
source "$REPO_ROOT/lib/logger.sh"
source "$REPO_ROOT/orchestration/common/env/load-env.sh"
load_env_file || true

# Parse CLI args into ENVIRONMENT and PROJECT_NAME
import_parse_args() {
    ENVIRONMENT="${1:-dev}"
    PROJECT_NAME="${2:-fru}"
}

# Exit if ENVIRONMENT is not dev|staging|prod
import_validate_env() {
    if [[ ! "${ENVIRONMENT}" =~ ^(dev|staging|prod)$ ]]; then
        log_error "Invalid environment: $ENVIRONMENT"
        log_info "Usage: $0 [dev|staging|prod] [project_name]"
        exit 1
    fi
}

# Ensure directory exists, cd into it; exit 1 if dir missing. $1=dir, $2=display name for errors
import_ensure_dir_and_cd() {
    local dir="$1" name="${2:-layer}"
    if [ ! -d "$dir" ]; then
        log_error "${name} directory not found: $dir"
        exit 1
    fi
    cd "$dir"
}

# Run terragrunt init -input=false; exit 1 on failure
import_init_strict() {
    log_info "Ensuring Terragrunt is initialized..."
    if ! terragrunt init -input=false; then
        log_error "terragrunt init failed"
        exit 1
    fi
}

# Run terragrunt init -input=false; ignore failure (|| true)
import_init_soft() {
    log_info "Ensuring Terragrunt is initialized..."
    terragrunt init -input=false || true
}

# Parse Terraform state lock ID from a log file (Terragrunt may prefix lines with timestamp/ANSI).
# Outputs the UUID or nothing. Same logic as orchestration/terraform/teardown.sh.
import_parse_lock_id_from_file() {
    local log_path="$1"
    [ -f "$log_path" ] || return 0
    local clean_log
    clean_log="$(mktemp)"
    sed -E 's/\x1B\[[0-9;]*[mK]//g' "$log_path" > "$clean_log" 2>/dev/null || cp "$log_path" "$clean_log"
    grep -iE 'ID:[[:space:]]+[0-9a-fA-F]{8}-' "$clean_log" | head -1 | grep -Eo '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | head -1
    rm -f "$clean_log"
}

# Extended skip patterns: resource does not exist in AWS (safe to skip for teardown-mode imports)
_IMPORT_SKIP_PATTERNS="Cannot import non-existent remote object|NoSuchEntity|ResourceNotFoundException|cannot be found|does not exist|NoSuchKey"

# Run a single terragrunt import; on state lock, force-unlock and retry once.
# Returns 0 on success or skip, 1 on failure.
# Must be called from the layer directory (already cd'd).
import_one_resource() {
    local addr="$1" id="$2"
    local tmp_log
    tmp_log="$(mktemp)"
    trap "rm -f '$tmp_log'" RETURN

    if terragrunt import "$addr" "$id" >"$tmp_log" 2>&1; then
        if grep -qiE "Import (prepared|successful|complete)|Resource already managed" "$tmp_log"; then
            log_success "  OK: $addr"
        elif grep -qiE "Error|error" "$tmp_log"; then
            log_warning "  Import may have issues for $addr"
            tail -5 "$tmp_log" | while IFS= read -r line; do log_info "    $line"; done
        else
            log_success "  OK: $addr"
        fi
        return 0
    fi

    if grep -qi "already managed by Terraform\|Resource already managed" "$tmp_log"; then
        log_success "  OK (already in state): $addr (Terraform state already tracks this resource; no import needed)"
        return 0
    fi
    if grep -qiE "$_IMPORT_SKIP_PATTERNS" "$tmp_log"; then
        log_info "  Skip (resource does not exist in AWS; safe to ignore for teardown-mode import): $addr"
        return 0
    fi

    # State lock: force-unlock and retry once, then re-classify the retry output
    if grep -qiE "Error (acquiring|releasing) the state lock" "$tmp_log"; then
        local lock_id
        lock_id="$(import_parse_lock_id_from_file "$tmp_log")"
        if [ -n "$lock_id" ]; then
            if terragrunt force-unlock -force "$lock_id" >/dev/null 2>&1; then
                log_info "  State lock detected; force-unlocked, retrying import for $addr..."
                local rc2=0
                terragrunt import "$addr" "$id" >"$tmp_log" 2>&1 || rc2=$?
                if [ "$rc2" -eq 0 ]; then
                    if grep -qiE "Import (prepared|successful|complete)|Resource already managed" "$tmp_log"; then
                        log_success "  OK: $addr (after unlock retry)"
                    elif grep -qiE "Error|error" "$tmp_log"; then
                        log_warning "  Import may have issues for $addr (after unlock retry)"
                        tail -5 "$tmp_log" | while IFS= read -r line; do log_info "    $line"; done
                    else
                        log_success "  OK: $addr (after unlock retry)"
                    fi
                    return 0
                fi
                # Non-zero after retry: treat "already managed" and skip patterns as non-fatal
                if grep -qi "already managed by Terraform\|Resource already managed" "$tmp_log"; then
                    log_success "  OK (already in state): $addr (Terraform state already tracks this resource; no import needed)"
                    return 0
                fi
                if grep -qiE "$_IMPORT_SKIP_PATTERNS" "$tmp_log"; then
                    log_info "  Skip (resource does not exist in AWS; safe to ignore for teardown-mode import): $addr"
                    return 0
                fi
            else
                log_warning "  State lock detected but force-unlock failed for $addr"
            fi
        else
            log_warning "  State lock detected for $addr but could not parse Lock ID."
            log_info "    Check for 'ID:' in the output below."
        fi
    fi

    log_warning "  Import failed for $addr"
    local err_lines
    err_lines="$(grep -iE 'Error|error:' "$tmp_log" 2>/dev/null | tail -5)"

    # If we only captured Terragrunt's generic "error occurred" wrapper,
    # print a larger tail of the raw log to surface the real Terraform error.
    if [ -n "$err_lines" ] && echo "$err_lines" | grep -qi "error occurred" && ! echo "$err_lines" | grep -qi "Error: "; then
        log_info "    (Generic Terragrunt error wrapper; showing broader context below)"
        tail -20 "$tmp_log" | while IFS= read -r line; do log_info "    $line"; done
    elif [ -n "$err_lines" ]; then
        echo "$err_lines" | while IFS= read -r line; do log_info "    $line"; done
    else
        tail -10 "$tmp_log" | while IFS= read -r line; do log_info "    $line"; done
    fi
    return 1
}

# Run imports for a list of "address:id" specs. Logs "Importing ..." per resource,
# calls import_one_resource, counts failures. At end logs "Some imports failed (N)"
# or "Import phase completed." Returns 0 if no failures, 1 otherwise.
import_batch() {
    local failed=0 spec
    for spec in "$@"; do
        [[ "$spec" != *:* ]] && continue
        local resource="${spec%%:*}" id="${spec#*:}"
        log_info "Importing $resource..."
        if import_one_resource "$resource" "$id"; then
            :
        else
            (( failed++ )) || true
        fi
    done
    if [ "$failed" -gt 0 ]; then
        log_warning "Some imports failed ($failed). Run 'terragrunt plan' to see remaining differences."
        return 1
    fi
    log_success "Import phase completed."
    return 0
}
