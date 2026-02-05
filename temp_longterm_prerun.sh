#!/usr/bin/env bash
# =============================================================================
# One-time migration: pre–Option B → Option B (separate infrastructure-longterm).
# Run this ONCE before the first ./run.sh aws kube dev --preempt after the Option B
# refactor, if you had Secrets Manager in the infrastructure layer and have not
# yet adopted longterm or cleaned infrastructure state.
#
# What it does:
#   1. Import existing AWS secrets into infrastructure-longterm state.
#   2. Apply the longterm layer so longterm state is consistent.
#   3. Remove old module.secrets_manager.* from infrastructure state so
#      teardown/destroy does not try to delete secrets and so infrastructure
#      apply can use remote_state (longterm) for secret ARNs.
#
# After this, run: ./run.sh aws kube dev --preempt
#
# Usage: ./temp_longterm_prerun.sh [dev|prod]
# Env:   HEARTBEAT_INTERVAL_SEC (default 60), PRERUN_STEP_TIMEOUT_SEC (default 600)
#
# Fail-fast: any failed step exits immediately with status 1 (no continue on error).
# =============================================================================

set -e
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$SCRIPT_DIR}"
export REPO_ROOT

source "$REPO_ROOT/lib/logger.sh"
source "$REPO_ROOT/orchestration/common/env/load-env.sh"
load_env_file 2>/dev/null || true

HEARTBEAT_INTERVAL_SEC="${HEARTBEAT_INTERVAL_SEC:-60}"
PRERUN_STEP_TIMEOUT_SEC="${PRERUN_STEP_TIMEOUT_SEC:-600}"

HEARTBEAT_HELPER="$REPO_ROOT/orchestration/common/feedback/run-with-heartbeat.sh"
[ -f "$HEARTBEAT_HELPER" ] && source "$HEARTBEAT_HELPER" || true

_run_step() {
    local desc="$1"
    shift
    if [ -n "$PRERUN_STEP_TIMEOUT_SEC" ] && [ "$PRERUN_STEP_TIMEOUT_SEC" -gt 0 ]; then
        run_with_heartbeat "$desc" "$HEARTBEAT_INTERVAL_SEC" "$PRERUN_STEP_TIMEOUT_SEC" "$@"
    else
        run_with_heartbeat "$desc" "$HEARTBEAT_INTERVAL_SEC" "$@"
    fi
}

ENVIRONMENT="${1:-dev}"
if [[ ! "$ENVIRONMENT" =~ ^(dev|prod)$ ]]; then
    log_error "Invalid environment: $ENVIRONMENT"
    log_info "Usage: $0 [dev|prod]"
    exit 1
fi

INFRA_TERRAFORM_DIR="$REPO_ROOT/module_infra_basic/aws/terra/environments"
LONGTERM_DIR="$INFRA_TERRAFORM_DIR/$ENVIRONMENT/infrastructure-longterm"
INFRA_DIR="$INFRA_TERRAFORM_DIR/$ENVIRONMENT/infrastructure"
IMPORT_LONGTERM="$REPO_ROOT/orchestration/terraform/import_preexist/import-existing-longterm.sh"

log_step "One-time migration: adopt longterm layer and clean infrastructure state"
log_info "Environment: $ENVIRONMENT"
log_info "Heartbeat every ${HEARTBEAT_INTERVAL_SEC}s; step timeout ${PRERUN_STEP_TIMEOUT_SEC}s"

# -----------------------------------------------------------------------------
# Step 1: Import existing AWS secrets into longterm state
# -----------------------------------------------------------------------------
if [ ! -d "$LONGTERM_DIR" ]; then
    log_error "Longterm directory not found: $LONGTERM_DIR"
    exit 1
fi
if [ ! -x "$IMPORT_LONGTERM" ]; then
    log_error "Import script not found or not executable: $IMPORT_LONGTERM"
    exit 1
fi

log_step "Step 1/3: Import existing Secrets Manager into longterm state"
_run_step "import longterm" -- "$IMPORT_LONGTERM" "$ENVIRONMENT" "fru" || { log_error "Step 1 failed: import longterm"; exit 1; }
log_success "Step 1/3 done."

# -----------------------------------------------------------------------------
# Step 2: Apply longterm layer (init, plan, apply)
# -----------------------------------------------------------------------------
log_step "Step 2/3: Apply infrastructure-longterm layer"
export AWS_PROFILE="${AWS_PROFILE:-admin}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
cd "$LONGTERM_DIR"
log_info "Initializing longterm layer..."
terragrunt init -reconfigure -input=false || { log_error "Step 2 failed: longterm init"; exit 1; }
_run_step "plan longterm" -- terragrunt plan -lock-timeout=30s -refresh=true -input=false || { log_error "Step 2 failed: longterm plan"; exit 1; }
_run_step "apply longterm" -- terragrunt apply -auto-approve -lock-timeout=30s -input=false || { log_error "Step 2 failed: longterm apply"; exit 1; }
log_success "Step 2/3 done."

# -----------------------------------------------------------------------------
# Step 3: Remove old module.secrets_manager.* from infrastructure state
# -----------------------------------------------------------------------------
log_step "Step 3/3: Remove old Secrets Manager from infrastructure state"
if [ ! -d "$INFRA_DIR" ]; then
    log_error "Infrastructure directory not found: $INFRA_DIR"
    exit 1
fi
cd "$INFRA_DIR"
log_info "Initializing infrastructure layer (to read state)..."
terragrunt init -reconfigure || { log_error "Step 3 failed: infrastructure init"; exit 1; }

STATE_RM_RESOURCES=(
    "module.secrets_manager.aws_secretsmanager_secret_version.openai_key"
    "module.secrets_manager.aws_secretsmanager_secret.openai_key"
    "module.secrets_manager.aws_secretsmanager_secret_version.openai_key_plain"
    "module.secrets_manager.aws_secretsmanager_secret.openai_key_plain"
    "module.secrets_manager.aws_secretsmanager_secret_version.db_password"
    "module.secrets_manager.aws_secretsmanager_secret.db_password"
    "module.secrets_manager.aws_secretsmanager_secret_version.db_password_plain"
    "module.secrets_manager.aws_secretsmanager_secret.db_password_plain"
    "module.secrets_manager.aws_secretsmanager_secret_version.db_username[0]"
    "module.secrets_manager.aws_secretsmanager_secret.db_username[0]"
)

removed=0
for res in "${STATE_RM_RESOURCES[@]}"; do
    if terragrunt state list 2>/dev/null | grep -Fx -- "$res" | grep -q .; then
        log_info "  Removing from state: $res"
        terragrunt state rm "$res" || { log_error "Step 3 failed: state rm $res (if state lock, run: cd $INFRA_DIR && terragrunt force-unlock <LOCK_ID>)"; exit 1; }
        removed=$((removed + 1))
    fi
done
if [ "$removed" -eq 0 ]; then
    log_info "No old secrets in infrastructure state (already migrated or fresh)."
else
    log_success "Removed $removed resource(s) from infrastructure state."
fi
log_success "Step 3/3 done."

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
log_success "One-time migration complete."
log_info ""
log_info "You can now run: ./run.sh aws kube dev --preempt"
log_info "You only need to run this script once per environment (dev/prod)."
