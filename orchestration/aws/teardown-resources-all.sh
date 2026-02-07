#!/bin/bash
# Teardown orchestrator: destroy EKS-only, ECS-only, or everything (EKS + ECS + shared).
#
# SYNOPSIS:
#   ./teardown-resources-all.sh <ENVIRONMENT> --container-type <eks|ecs|all> [OPTIONS]
#
# DESCRIPTION:
#   - eks: Destroy EKS-specific infra only (EKS app layer). ECS and shared infra left standing.
#   - ecs: Destroy ECS-specific infra only (ECS app layer). EKS and shared infra left standing.
#   - all: Destroy EKS + ECS app layers, then shared infra (VPC, Aurora, IAM). Nothing left standing.
#
# STEPS (per mode):
#   Pre-destroy (stop services, empty S3) → Terraform destroy (layer(s)) → optional orphan cleanup → optional local Docker cleanup.
#
# HEARTBEAT: Shown every HEARTBEAT_INTERVAL_SEC during pre-destroy, terraform, and cleanup steps only.
#   Initial "Loading AWS image identifiers" (before steps) is not wrapped; it may take up to ~3 min with no heartbeat.
#
# TIMEOUT: Script has no overall run timeout. To limit per-step duration, set TEARDOWN_STEP_TIMEOUT_SEC (seconds).
#   Example: TEARDOWN_STEP_TIMEOUT_SEC=1800 ./teardown-resources-all.sh ... (30 min per step; step is killed and script exits non-zero).
#   If unset or 0, steps run until completion. (External timeouts, e.g. CI/IDE, may still kill the process.)
#
# WAIT BEFORE SHARED DESTROY (container-type all): Set TEARDOWN_WAIT_BETWEEN_LAYERS (seconds) as max wait / retry window after EKS/ECS destroy.
#   Shared destroy is tried immediately, then every 30s on DependencyViolation (ENI/subnet), until success or timeout. run.sh --preempt sets 900 by default. Use 0 to skip wait/retry.
#
# FAIL-FAST: Set TEARDOWN_FAIL_FAST=true to exit on first step failure (default: continue and try all steps, then exit 1).
#   run.sh --preempt sets TEARDOWN_FAIL_FAST=true so preempt stops immediately on error (e.g. state lock).
#
# STDERR/ERROR in output: Terragrunt (when it runs terraform destroy) uses a default log format that prefixes each
#   line with a timestamp and a level: STDOUT (terraform stdout), STDERR (terraform stderr), ERROR (terragrunt's own
#   errors). So "STDERR" and "ERROR" in the log are added by Terragrunt, not by our scripts. When teardown fails,
#   look for the actual message (e.g. "Error acquiring the state lock", "DependencyViolation"). State lock fix:
#   cd <layer-dir> && terragrunt force-unlock <LOCK_ID> (use the Lock ID from the error), then re-run.
#
# REQUIRED: --container-type (eks | ecs | all)
#
# OPTIONS: --force, --skip-confirmation, --dry-run, --clean-local-only, --help
#
set -e

# --- Timeouts and heartbeat (override via env) ---
TEARDOWN_STEP_TIMEOUT_SEC="${TEARDOWN_STEP_TIMEOUT_SEC:-0}"   # Per-step timeout (seconds). 0 = no timeout.
HEARTBEAT_INTERVAL_SEC="${TEARDOWN_HEARTBEAT_INTERVAL:-60}"   # Heartbeat message interval (seconds).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
source "$REPO_ROOT/lib/logger.sh"
source "$REPO_ROOT/orchestration/common/env/load-env.sh"

# Optional: reuse cleanup helper for local Docker images
CLEANUP_HELPER="$REPO_ROOT/orchestration/common/deploy/cleanup-local-docker-images.sh"
[ -f "$CLEANUP_HELPER" ] && source "$CLEANUP_HELPER" || true
# Heartbeat helper for long-running steps (continuous feedback)
HEARTBEAT_HELPER="$REPO_ROOT/orchestration/common/feedback/run-with-heartbeat.sh"
[ -f "$HEARTBEAT_HELPER" ] && source "$HEARTBEAT_HELPER" || true
# Wrapper: run with heartbeat and optional per-step timeout (TEARDOWN_STEP_TIMEOUT_SEC)
_run_with_heartbeat_step() {
    local desc="$1"
    shift
    if [ -n "$TEARDOWN_STEP_TIMEOUT_SEC" ] && [ "$TEARDOWN_STEP_TIMEOUT_SEC" -gt 0 ]; then
        run_with_heartbeat "$desc" "$HEARTBEAT_INTERVAL_SEC" "$TEARDOWN_STEP_TIMEOUT_SEC" "$@"
    else
        run_with_heartbeat "$desc" "$HEARTBEAT_INTERVAL_SEC" "$@"
    fi
}

DRY_RUN="false"
FORCE_DELETE="false"
SKIP_CONFIRMATION="false"
CLEAN_LOCAL_ONLY="false"
TEARDOWN_FAIL_FAST="${TEARDOWN_FAIL_FAST:-false}"
CONTAINER_TYPE=""
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${1:-dev}"
PROJECT_NAME="fru"
ECR_REPO_NAME="fru-api"

# Paths to teardown scripts (pre-destroy in trees; shared scripts in orchestration)
EKS_PRE_DESTROY="$REPO_ROOT/module_infra_kubetypes/kube/aws/teardown/eks_pre_destroy.py"
ECS_PRE_DESTROY="$REPO_ROOT/module_infra_kubetypes/nonkube/aws/teardown/ecs_pre_destroy.py"
SHARED_PRE_DESTROY="$REPO_ROOT/orchestration/aws/teardown/shared_pre_destroy.py"
CLEANUP_ORPHANED="$REPO_ROOT/orchestration/aws/teardown/cleanup_orphaned.py"
TF_TEARDOWN="$REPO_ROOT/orchestration/terraform/teardown.sh"
ECR_DELETE_BY_CT="$REPO_ROOT/orchestration/aws/cli/ecr-delete-by-container-type.sh"

show_help() {
    cat << EOF
Usage: $0 <environment> --container-type <eks|ecs|all> [options...]

  --container-type eks  Destroy EKS app layer only (ECS and shared left standing).
  --container-type ecs  Destroy ECS app layer only (EKS and shared left standing).
  --container-type all  Destroy EKS + ECS + shared infra (everything).

Options: --force, --dry-run, --clean-local-only, --help
EOF
}
if [ "$ENVIRONMENT" = "--help" ] || [ "$ENVIRONMENT" = "-h" ]; then
    show_help
    exit 0
fi

shift 1 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE_DELETE="true"; SKIP_CONFIRMATION="true"; shift ;;
        --skip-confirmation) SKIP_CONFIRMATION="true"; shift ;;
        --dry-run) DRY_RUN="true"; shift ;;
        --clean-local-only) CLEAN_LOCAL_ONLY="true"; shift ;;
        --container-type)
            if [ $# -ge 2 ]; then
                CONTAINER_TYPE="$2"
                [[ "$CONTAINER_TYPE" != "ecs" && "$CONTAINER_TYPE" != "eks" && "$CONTAINER_TYPE" != "all" ]] && { log_error "Invalid container type: $CONTAINER_TYPE (must be eks, ecs, or all)"; exit 1; }
                shift 2
            else
                log_error "--container-type requires a value (eks, ecs, or all)"; exit 1
            fi
            ;;
        --help|-h) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Validation
[[ ! "$ENVIRONMENT" =~ ^(dev|staging|prod)$ ]] && { log_error "Invalid environment: $ENVIRONMENT"; exit 1; }
[ -z "$CONTAINER_TYPE" ] && { log_error "--container-type is required"; exit 1; }

# AWS account ID for S3 bucket names (can take up to ~3 min; no heartbeat during this phase)
if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
    log_info "Resolving AWS account and ECR URI (may take up to ~3 min; no heartbeat during this phase)..."
    source "$REPO_ROOT/orchestration/common/env/load-image-identifiers.sh"
    load_image_identifiers "aws" || exit 1
fi

log_step "Infrastructure Teardown"
log_warning "════════════════════════════════════════════════════════════════"
if [ "$CONTAINER_TYPE" = "all" ]; then
    log_warning "WARNING: This will DESTROY ALL infrastructure for $ENVIRONMENT (EKS + ECS + shared)"
else
    log_warning "WARNING: This will DESTROY $CONTAINER_TYPE-specific infrastructure for $ENVIRONMENT"
fi
log_warning "════════════════════════════════════════════════════════════════"
log_info "Environment: $ENVIRONMENT | Container type: $CONTAINER_TYPE | Region: $AWS_REGION"
[ "$DRY_RUN" = "true" ] && log_info "Mode: DRY-RUN" || log_warning "Mode: DESTRUCTION"
echo ""

# Confirmation (unless --force, --dry-run, or PREEMPT)
if [ "$DRY_RUN" = "false" ] && [ "$SKIP_CONFIRMATION" = "false" ] && [ "${PREEMPT:-false}" != "true" ]; then
    read -p "Type 'yes' to confirm destruction: " confirm
    [ "$confirm" != "yes" ] && { log_info "Destruction cancelled"; exit 0; }
    echo ""
fi

# --- Step 1: Pre-destroy (stop services, empty S3) via module teardown ---
run_pre_destroy() {
    local ct="$1"
    log_step "Pre-destroy ($(echo "$ct" | tr '[:lower:]' '[:upper:]'))"
    local pre_script=""
    case "$ct" in
        eks) pre_script="$EKS_PRE_DESTROY" ;;
        ecs) pre_script="$ECS_PRE_DESTROY" ;;
        shared) pre_script="$SHARED_PRE_DESTROY" ;;
        *) log_error "Unknown container type for pre-destroy: $ct"; return 1 ;;
    esac
    [ ! -f "$pre_script" ] && { log_error "Pre-destroy script not found: $pre_script"; return 1; }
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would run: $pre_script --environment $ENVIRONMENT --dry-run"
        echo ""
        return 0
    fi
    export AWS_PROFILE AWS_REGION
    local r=0
    if type run_with_heartbeat >/dev/null 2>&1; then
        _run_with_heartbeat_step "Pre-destroy ($ct)" -- "$PYTHON_CMD" "$pre_script" --environment "$ENVIRONMENT" --profile "$AWS_PROFILE" --region "$AWS_REGION"
        r=$?
    else
        "$PYTHON_CMD" "$pre_script" --environment "$ENVIRONMENT" --profile "$AWS_PROFILE" --region "$AWS_REGION"
        r=$?
    fi
    if [ "$r" -eq 0 ]; then
        log_success "Pre-destroy ($ct) done"
    else
        log_error "Pre-destroy ($ct) failed (FAIL-FAST). Infrastructure may be in an inconsistent state."
        exit 1
    fi
    echo ""
}

# --- Step 2: Terraform destroy (single app layer: eks or ecs) via module teardown ---
# Run import scripts for this layer before destroy so state is populated and destroy can remove orphaned resources (same idea as shared/infrastructure).
run_import_before_layer_destroy() {
    local ct="$1"
    [ "$DRY_RUN" = "true" ] && return 0
    export AWS_PROFILE AWS_REGION
    case "$ct" in
        eks)
            local import_eks="$REPO_ROOT/orchestration/terraform/import_preexist/import-existing-eks.sh"
            local import_fe="$REPO_ROOT/orchestration/terraform/import_preexist/import-existing-frontend-eks.sh"
            local eks_dir="$REPO_ROOT/module_infra_kubetypes/kube/aws/terra/environments/$ENVIRONMENT/eks"
            if [ -d "$eks_dir" ] && [ -x "$import_eks" ]; then
                log_info "Reconciling EKS state (import before destroy)..."
                "$import_eks" "$ENVIRONMENT" "$PROJECT_NAME" || { log_error "EKS import failed"; exit 1; }
            fi
            local fe_dir="$REPO_ROOT/module_infra_frontend/aws/terra/environments/$ENVIRONMENT/frontend-eks"
            if [ -d "$fe_dir" ] && [ -x "$import_fe" ]; then
                log_info "Reconciling frontend-eks state (import before destroy)..."
                "$import_fe" "$ENVIRONMENT" "$PROJECT_NAME" || { log_error "Frontend-eks import failed"; exit 1; }
            fi
            ;;
        ecs)
            local import_ecs="$REPO_ROOT/orchestration/terraform/import_preexist/import-existing-ecs.sh"
            local import_fe="$REPO_ROOT/orchestration/terraform/import_preexist/import-existing-frontend-ecs.sh"
            local ecs_dir="$REPO_ROOT/module_infra_kubetypes/nonkube/aws/terra/environments/$ENVIRONMENT/ecs"
            if [ -d "$ecs_dir" ] && [ -x "$import_ecs" ]; then
                log_info "Reconciling ECS state (import before destroy)..."
                "$import_ecs" "$ENVIRONMENT" "$PROJECT_NAME" || { log_error "ECS import failed"; exit 1; }
            fi
            local fe_dir="$REPO_ROOT/module_infra_frontend/aws/terra/environments/$ENVIRONMENT/frontend-ecs"
            if [ -d "$fe_dir" ] && [ -x "$import_fe" ]; then
                log_info "Reconciling frontend-ecs state (import before destroy)..."
                "$import_fe" "$ENVIRONMENT" "$PROJECT_NAME" || { log_error "Frontend-ecs import failed"; exit 1; }
            fi
            ;;
        *) ;;
    esac
    echo ""
}

run_terraform_teardown_layer() {
    local ct="$1"
    log_step "Terraform destroy ($(echo "$ct" | tr '[:lower:]' '[:upper:]') layer only)"
    [ ! -f "$TF_TEARDOWN" ] && { log_error "Terraform teardown script not found: $TF_TEARDOWN"; return 1; }
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would run: $TF_TEARDOWN $ENVIRONMENT $ct"
        echo ""
        return 0
    fi
    run_import_before_layer_destroy "$ct"
    export AWS_PROFILE AWS_REGION CONTAINER_TYPE
    [ "$SKIP_CONFIRMATION" = "true" ] || [ "${PREEMPT:-false}" = "true" ] && export PREEMPT=true
    local r=0
    local tmp_output
    tmp_output="$(mktemp)"
    if type run_with_heartbeat >/dev/null 2>&1; then
        _run_with_heartbeat_step "Terraform destroy ($ct layer)" -- bash -c "\"$TF_TEARDOWN\" \"$ENVIRONMENT\" \"$ct\" 2>&1 | tee \"$tmp_output\""
        r=${PIPESTATUS[0]}
    else
        "$TF_TEARDOWN" "$ENVIRONMENT" "$ct" 2>&1 | tee "$tmp_output"
        r=${PIPESTATUS[0]}
    fi
    if [ "$r" -eq 0 ]; then
        log_success "Terraform teardown ($ct layer) complete"
        rm -f "$tmp_output"
    else
        log_error "Terraform teardown ($ct) FAILED with exit code $r"
        log_error "════════════════════════════════════════════════════════════════"
        log_error "Error output from terraform destroy ($ct):"
        log_error "════════════════════════════════════════════════════════════════"
        cat "$tmp_output" | sed 's/^/  /' >&2
        log_error "════════════════════════════════════════════════════════════════"
        log_warning "To retry: cd $(dirname $TF_TEARDOWN) && terragrunt destroy (from appropriate env dir)"
        log_warning "Or use: remove-all-aws-resources as fallback"
        rm -f "$tmp_output"
        if [ "$TEARDOWN_FAIL_FAST" = "true" ]; then
            log_error "TEARDOWN_FAIL_FAST=true: exiting immediately on terraform error"
            exit 1
        fi
        exit 1
    fi
    echo ""
}

# --- Terraform destroy shared (infrastructure) layer ---
run_terraform_teardown_shared() {
    log_step "Terraform destroy (shared infrastructure)"
    [ ! -f "$TF_TEARDOWN" ] && { log_error "Terraform teardown script not found: $TF_TEARDOWN"; return 1; }
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would run: $TF_TEARDOWN $ENVIRONMENT infra_basic"
        echo ""
        return 0
    fi
    export AWS_PROFILE AWS_REGION CONTAINER_TYPE
    [ "$SKIP_CONFIRMATION" = "true" ] || [ "${PREEMPT:-false}" = "true" ] && export PREEMPT=true
    local r=0
    local tmp_output
    tmp_output="$(mktemp)"
    if type run_with_heartbeat >/dev/null 2>&1; then
        _run_with_heartbeat_step "Terraform destroy (shared)" -- bash -c "\"$TF_TEARDOWN\" \"$ENVIRONMENT\" \"infra_basic\" 2>&1 | tee \"$tmp_output\""
        r=${PIPESTATUS[0]}
    else
        "$TF_TEARDOWN" "$ENVIRONMENT" "infra_basic" 2>&1 | tee "$tmp_output"
        r=${PIPESTATUS[0]}
    fi
    if [ "$r" -eq 0 ]; then
        log_success "Terraform teardown (shared) complete"
        rm -f "$tmp_output"
    else
        log_error "Terraform teardown (shared) FAILED with exit code $r"
        log_error "════════════════════════════════════════════════════════════════"
        log_error "Error output from terraform destroy (shared):"
        log_error "════════════════════════════════════════════════════════════════"
        cat "$tmp_output" | sed 's/^/  /' >&2
        log_error "════════════════════════════════════════════════════════════════"
        log_warning "To retry: cd $(dirname $TF_TEARDOWN) && terragrunt destroy (from appropriate env dir)"
        log_warning "Or use: remove-all-aws-resources as fallback"
        rm -f "$tmp_output"
        if [ "$TEARDOWN_FAIL_FAST" = "true" ]; then
            log_error "TEARDOWN_FAIL_FAST=true: exiting immediately on terraform error"
            exit 1
        fi
        exit 1
    fi
    echo ""
}

# --- Step 3: Optional orphan cleanup (module_infra_basic, module_infra_frontend) ---
cleanup_orphaned() {
    local ct="$1"
    log_step "Optional orphan cleanup (container-type: $ct)"
    [ ! -f "$CLEANUP_ORPHANED" ] && { log_info "Orphan cleanup script not found; skipping"; echo ""; return 0; }
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would run: $CLEANUP_ORPHANED --environment $ENVIRONMENT --container-type $ct --dry-run"
        echo ""
        return 0
    fi
    local cmd=("$PYTHON_CMD" "$CLEANUP_ORPHANED" "--environment" "$ENVIRONMENT" "--container-type" "$ct" "--profile" "$AWS_PROFILE" "--region" "$AWS_REGION")
    [ "$SKIP_CONFIRMATION" = "true" ] || [ "${PREEMPT:-false}" = "true" ] && cmd+=(--force)
    local r=0
    if type run_with_heartbeat >/dev/null 2>&1; then
        _run_with_heartbeat_step "Orphan cleanup ($ct)" -- "${cmd[@]}"
        r=$?
    else
        "${cmd[@]}"
        r=$?
    fi
    if [ "$r" -eq 0 ]; then
        log_success "Orphan cleanup ($ct) done"
    else
        log_warning "Orphan cleanup ($ct) had issues (non-fatal)"
    fi
    echo ""
}

# --- ECR cleanup by container-type (delete only images with tag eks, ecs, or all) ---
run_ecr_cleanup() {
    log_step "ECR cleanup (container-type: $CONTAINER_TYPE)"
    if [ ! -x "$ECR_DELETE_BY_CT" ]; then
        log_info "ECR delete script not found or not executable: $ECR_DELETE_BY_CT; skipping."
        echo ""
        return 0
    fi
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would run: $ECR_DELETE_BY_CT --container-type $CONTAINER_TYPE --repo $ECR_REPO_NAME --dry-run"
        echo ""
        return 0
    fi
    export AWS_PROFILE AWS_REGION ECR_REPO_NAME
    local r=0
    "$ECR_DELETE_BY_CT" --container-type "$CONTAINER_TYPE" --repo "$ECR_REPO_NAME" --profile "$AWS_PROFILE" --region "$AWS_REGION" || r=$?
    if [ "$r" -eq 0 ]; then
        log_success "ECR cleanup ($CONTAINER_TYPE) done"
    else
        log_warning "ECR cleanup ($CONTAINER_TYPE) had issues (non-fatal)"
    fi
    echo ""
}

# --- Step 4: Optional local Docker cleanup ---
cleanup_local_images() {
    log_step "Step 4: Local Docker image cleanup"
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would clean local images: ${ECR_REPO_NAME}:*"
        echo ""
        return 0
    fi
    if type cleanup_local_images_by_pattern >/dev/null 2>&1; then
        cleanup_local_images_by_pattern "${ECR_REPO_NAME}" "${DRY_RUN:-false}" || true
    else
        if docker info >/dev/null 2>&1; then
            local ids
            ids=$(docker images "${ECR_REPO_NAME}" --format "{{.ID}}" 2>/dev/null || true)
            if [ -n "$ids" ]; then
                echo "$ids" | while read -r id; do [ -n "$id" ] && docker rmi -f "$id" 2>/dev/null || true; done
            else
                log_info "No local images matching ${ECR_REPO_NAME}"
            fi
        else
            log_info "Docker not running; skipping local image cleanup"
        fi
    fi
    echo ""
}

# --- Main ---
main() {
    local failed=false

    if [ "$CLEAN_LOCAL_ONLY" = "true" ]; then
        cleanup_local_images
        log_success "Local Docker cleanup only (AWS untouched)"
        return 0
    fi

    case "$CONTAINER_TYPE" in
        eks)
            run_pre_destroy "eks" || { failed=true; [ "$TEARDOWN_FAIL_FAST" = "true" ] && exit 1; }
            run_terraform_teardown_layer "eks" || { failed=true; [ "$TEARDOWN_FAIL_FAST" = "true" ] && exit 1; }
            cleanup_orphaned "eks" || true
            run_ecr_cleanup || true
            ;;
        ecs)
            run_pre_destroy "ecs" || { failed=true; [ "$TEARDOWN_FAIL_FAST" = "true" ] && exit 1; }
            run_terraform_teardown_layer "ecs" || { failed=true; [ "$TEARDOWN_FAIL_FAST" = "true" ] && exit 1; }
            cleanup_orphaned "ecs" || true
            run_ecr_cleanup || true
            ;;
        all)
            run_pre_destroy "eks" || { failed=true; [ "$TEARDOWN_FAIL_FAST" = "true" ] && exit 1; }
            run_pre_destroy "ecs" || { failed=true; [ "$TEARDOWN_FAIL_FAST" = "true" ] && exit 1; }
            run_terraform_teardown_layer "eks" || { failed=true; [ "$TEARDOWN_FAIL_FAST" = "true" ] && exit 1; }
            run_terraform_teardown_layer "ecs" || { failed=true; [ "$TEARDOWN_FAIL_FAST" = "true" ] && exit 1; }
            # Import existing infrastructure into state before destroy so terragrunt destroy can remove orphaned resources (e.g. DB subnet group in old VPC). Otherwise state is empty and destroy no-ops; deploy then re-imports and hits VPC mismatch.
            if [ "$DRY_RUN" = "false" ]; then
                IMPORT_INFRA="$REPO_ROOT/orchestration/terraform/import_preexist/import-existing-infrastructure.sh"
                INFRA_DIR="$REPO_ROOT/module_infra_basic/aws/terra/environments/$ENVIRONMENT/infrastructure"
                if [ -d "$INFRA_DIR" ] && [ -x "$IMPORT_INFRA" ]; then
                    log_step "Reconciling infrastructure state (import before destroy)"
                    export AWS_PROFILE AWS_REGION
                    if ! "$IMPORT_INFRA" "$ENVIRONMENT" "$PROJECT_NAME"; then
                        log_warning "Infrastructure import had issues; continuing with destroy."
                    fi
                    echo ""
                fi
            fi
            run_pre_destroy "shared" || { failed=true; [ "$TEARDOWN_FAIL_FAST" = "true" ] && exit 1; }
            # Shared destroy: when TEARDOWN_WAIT_BETWEEN_LAYERS > 0, retry every 30s on DependencyViolation until success or timeout; otherwise run once.
            if [ "$DRY_RUN" = "false" ] && [ "${TEARDOWN_WAIT_BETWEEN_LAYERS:-0}" -gt 0 ]; then
                wait_timeout="${TEARDOWN_WAIT_BETWEEN_LAYERS}"
                interval=30
                start_time=$(date +%s)
                log_step "Terraform destroy (shared infrastructure); will retry every ${interval}s on ENI/subnet dependency until success or ${wait_timeout}s timeout"
                while true; do
                    _tmp_out=$(mktemp)
                    set +e
                    export AWS_PROFILE AWS_REGION
                    [ "$SKIP_CONFIRMATION" = "true" ] || [ "${PREEMPT:-false}" = "true" ] && export PREEMPT=true
                    [ ! -f "$TF_TEARDOWN" ] && { log_error "Terraform teardown script not found: $TF_TEARDOWN"; set -e; failed=true; rm -f "$_tmp_out"; break; }
                    "$TF_TEARDOWN" "$ENVIRONMENT" "infra_basic" 2>&1 | tee "$_tmp_out"
                    r=${PIPESTATUS[0]}
                    set -e
                    if [ "$r" -eq 0 ]; then
                        log_success "Terraform teardown (shared) complete"
                        rm -f "$_tmp_out"
                        break
                    fi
                    if ! grep -qEi "DependencyViolation|has dependencies and cannot be deleted" "$_tmp_out" 2>/dev/null; then
                        log_error "Shared destroy failed with non-retryable error"
                        rm -f "$_tmp_out"
                        failed=true
                        [ "$TEARDOWN_FAIL_FAST" = "true" ] && exit 1
                        break
                    fi
                    now=$(date +%s)
                    elapsed=$((now - start_time))
                    if [ "$elapsed" -ge "$wait_timeout" ]; then
                        log_warning "Shared destroy still failing after ${wait_timeout}s; giving up"
                        rm -f "$_tmp_out"
                        failed=true
                        [ "$TEARDOWN_FAIL_FAST" = "true" ] && exit 1
                        break
                    fi
                    remaining=$((wait_timeout - elapsed))
                    log_info "Shared destroy failed (ENI/subnet dependencies); retrying in ${interval}s (timeout in ${remaining}s)..."
                    rm -f "$_tmp_out"
                    sleep "$interval"
                done
                echo ""
            else
                run_terraform_teardown_shared || { failed=true; [ "$TEARDOWN_FAIL_FAST" = "true" ] && exit 1; }
            fi
            cleanup_orphaned "ecs" || true
            cleanup_orphaned "eks" || true
            run_ecr_cleanup || true
            ;;
        *) log_error "Unreachable: CONTAINER_TYPE=$CONTAINER_TYPE"; exit 1 ;;
    esac

    cleanup_local_images || true

    log_step "Destruction Summary"
    if [ "$DRY_RUN" = "true" ]; then
        log_info "DRY-RUN: no resources destroyed"
    elif [ "$failed" = "true" ]; then
        log_warning "Teardown completed with issues; retry or use remove-all-aws-resources as fallback"
        log_info "Check the output above for STDERR/ERROR. State lock: cd <layer-dir> && terragrunt force-unlock <LOCK_ID>; then re-run."
    else
        log_success "Teardown completed for $ENVIRONMENT (container-type: $CONTAINER_TYPE)"
    fi

    [ "$failed" = "true" ] && exit 1
    return 0
}

main "$@"
