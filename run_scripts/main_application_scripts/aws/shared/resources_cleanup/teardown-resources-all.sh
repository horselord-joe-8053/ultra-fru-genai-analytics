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
# REQUIRED: --container-type (eks | ecs | all)
#
# OPTIONS: --force, --skip-confirmation, --dry-run, --clean-local-only, --help
#
set -e

# --- Timeouts and heartbeat (override via env) ---
TEARDOWN_STEP_TIMEOUT_SEC="${TEARDOWN_STEP_TIMEOUT_SEC:-0}"   # Per-step timeout (seconds). 0 = no timeout.
HEARTBEAT_INTERVAL_SEC="${TEARDOWN_HEARTBEAT_INTERVAL:-60}"   # Heartbeat message interval (seconds).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
source "$REPO_ROOT/orchestration/shared/logger.sh"
source "$REPO_ROOT/orchestration/shared/load-env.sh"

# Optional: reuse cleanup helper for local Docker images
CLEANUP_HELPER="$REPO_ROOT/run_scripts/main_application_scripts/aws/shared/helpers/cleanup-local-docker-images.sh"
[ -f "$CLEANUP_HELPER" ] && source "$CLEANUP_HELPER" || true
# Heartbeat helper for long-running steps (continuous feedback)
HEARTBEAT_HELPER="$REPO_ROOT/run_scripts/main_application_scripts/aws/shared/helpers/run-with-heartbeat.sh"
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
CONTAINER_TYPE=""
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${1:-dev}"
PROJECT_NAME="fru"
ECR_REPO_NAME="fru-api"

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
    source "$REPO_ROOT/orchestration/shared/load-image-identifiers.sh"
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

# --- Step 1: Pre-destroy (stop services, empty S3) via sub_proc ---
run_pre_destroy() {
    local ct="$1"
    log_step "Pre-destroy ($(echo "$ct" | tr '[:lower:]' '[:upper:]'))"
    local pre_script="$SCRIPT_DIR/sub_proc/${ct}_pre_destroy.py"
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
        log_warning "Pre-destroy ($ct) had issues (continuing)"
    fi
    echo ""
}

# --- Step 2: Terraform destroy (single app layer: eks or ecs) via sub_proc ---
run_terraform_teardown_layer() {
    local ct="$1"
    log_step "Terraform destroy ($(echo "$ct" | tr '[:lower:]' '[:upper:]') layer only)"
    local tf_wrapper="$SCRIPT_DIR/sub_proc/${ct}_terraform_teardown.sh"
    [ ! -f "$tf_wrapper" ] && { log_error "Terraform teardown wrapper not found: $tf_wrapper"; return 1; }
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would run: $tf_wrapper $ENVIRONMENT"
        echo ""
        return 0
    fi
    export AWS_PROFILE AWS_REGION
    [ "$SKIP_CONFIRMATION" = "true" ] || [ "${PREEMPT:-false}" = "true" ] && export PREEMPT=true
    local r=0
    if type run_with_heartbeat >/dev/null 2>&1; then
        _run_with_heartbeat_step "Terraform destroy ($ct layer)" -- "$tf_wrapper" "$ENVIRONMENT"
        r=$?
    else
        "$tf_wrapper" "$ENVIRONMENT"
        r=$?
    fi
    if [ "$r" -eq 0 ]; then
        log_success "Terraform teardown ($ct layer) complete"
    else
        log_warning "Terraform teardown ($ct) had issues (retry or use remove-all-aws-resources as fallback)"
        return 1
    fi
    echo ""
}

# --- Terraform destroy shared (infrastructure) layer ---
run_terraform_teardown_shared() {
    log_step "Terraform destroy (shared infrastructure)"
    local tf_wrapper="$SCRIPT_DIR/sub_proc/shared_terraform_teardown.sh"
    [ ! -f "$tf_wrapper" ] && { log_error "Shared teardown wrapper not found: $tf_wrapper"; return 1; }
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would run: $tf_wrapper $ENVIRONMENT"
        echo ""
        return 0
    fi
    export AWS_PROFILE AWS_REGION
    [ "$SKIP_CONFIRMATION" = "true" ] || [ "${PREEMPT:-false}" = "true" ] && export PREEMPT=true
    local r=0
    if type run_with_heartbeat >/dev/null 2>&1; then
        _run_with_heartbeat_step "Terraform destroy (shared)" -- "$tf_wrapper" "$ENVIRONMENT"
        r=$?
    else
        "$tf_wrapper" "$ENVIRONMENT"
        r=$?
    fi
    if [ "$r" -eq 0 ]; then
        log_success "Terraform teardown (shared) complete"
    else
        log_warning "Terraform teardown (shared) had issues"
        return 1
    fi
    echo ""
}

# --- Step 3: Optional orphan cleanup (sub_proc Python) ---
cleanup_orphaned() {
    local ct="$1"
    log_step "Optional orphan cleanup (container-type: $ct)"
    local helper="$SCRIPT_DIR/sub_proc/cleanup_orphaned.py"
    [ ! -f "$helper" ] && { log_info "Orphan cleanup script not found; skipping"; echo ""; return 0; }
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would run: $helper --environment $ENVIRONMENT --container-type $ct --dry-run"
        echo ""
        return 0
    fi
    local cmd=("$PYTHON_CMD" "$helper" "--environment" "$ENVIRONMENT" "--container-type" "$ct" "--profile" "$AWS_PROFILE" "--region" "$AWS_REGION")
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
            run_pre_destroy "eks" || failed=true
            run_terraform_teardown_layer "eks" || failed=true
            cleanup_orphaned "eks" || true
            ;;
        ecs)
            run_pre_destroy "ecs" || failed=true
            run_terraform_teardown_layer "ecs" || failed=true
            cleanup_orphaned "ecs" || true
            ;;
        all)
            run_pre_destroy "eks" || failed=true
            run_pre_destroy "ecs" || failed=true
            run_terraform_teardown_layer "eks" || failed=true
            run_terraform_teardown_layer "ecs" || failed=true
            if [ "$DRY_RUN" = "false" ] && [ "${TEARDOWN_WAIT_BETWEEN_LAYERS:-0}" -gt 0 ]; then
                log_step "Waiting ${TEARDOWN_WAIT_BETWEEN_LAYERS}s before shared destroy"
                if type sleep_with_heartbeat >/dev/null 2>&1; then
                    sleep_with_heartbeat "${TEARDOWN_WAIT_BETWEEN_LAYERS}" 30 "Waiting before shared destroy"
                else
                    sleep "${TEARDOWN_WAIT_BETWEEN_LAYERS}"
                fi
            fi
            run_pre_destroy "shared" || failed=true
            run_terraform_teardown_shared || failed=true
            cleanup_orphaned "ecs" || true
            cleanup_orphaned "eks" || true
            ;;
        *) log_error "Unreachable: CONTAINER_TYPE=$CONTAINER_TYPE"; exit 1 ;;
    esac

    cleanup_local_images || true

    log_step "Destruction Summary"
    if [ "$DRY_RUN" = "true" ]; then
        log_info "DRY-RUN: no resources destroyed"
    elif [ "$failed" = "true" ]; then
        log_warning "Teardown completed with issues; retry or use remove-all-aws-resources as fallback"
    else
        log_success "Teardown completed for $ENVIRONMENT (container-type: $CONTAINER_TYPE)"
    fi

    [ "$failed" = "true" ] && exit 1
    return 0
}

main "$@"
