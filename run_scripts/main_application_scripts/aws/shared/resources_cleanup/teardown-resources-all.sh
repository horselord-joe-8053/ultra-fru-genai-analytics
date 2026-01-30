#!/bin/bash
# Complete infrastructure destruction (including shared) - single orchestrator
#
# SYNOPSIS:
#   ./teardown-resources-all.sh <ENVIRONMENT> --container-type <ecs|eks> [OPTIONS]
#
# DESCRIPTION:
#   Single teardown orchestrator: pre-destroy (stop services, empty S3) →
#   terraform/teardown.sh (app layer then infrastructure) → optional orphan cleanup →
#   optional local Docker cleanup. No long VPC/Aurora waits; rely on Terraform destroy
#   order. If infra destroy fails (e.g. ENI eventual consistency), retry later or use
#   remove-all-aws-resources as fallback (see README_ALL_TEARDOWN.md).
#
# EXECUTION STEPS:
#   1. Stop ECS/EKS services (scale to 0, wait for tasks to stop)
#   2. Empty S3 buckets (analytics, frontend) so Terraform can destroy them
#   3. Terraform destroy: app layer (ecs|eks) then infrastructure (single terraform/teardown.sh ENV all)
#   4. Optional: cleanup orphaned AWS resources (S3, ECR, ECS task definitions)
#   5. Optional: clean local Docker images (fru-api:*)
#
# REQUIRED: --container-type (ecs or eks)
#
# OPTIONS: --force, --skip-confirmation, --dry-run, --clean-local-only, --help
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"

# Optional: reuse cleanup helper for local Docker images
CLEANUP_HELPER="$REPO_ROOT/run_scripts/main_application_scripts/aws/shared/helpers/cleanup-local-docker-images.sh"
[ -f "$CLEANUP_HELPER" ] && source "$CLEANUP_HELPER" || true

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

# Allow --help as first argument (no ENVIRONMENT required)
if [ "$ENVIRONMENT" = "--help" ] || [ "$ENVIRONMENT" = "-h" ]; then
    cat << EOF
Usage: $0 <environment> --container-type <ecs|eks> [options...]

Complete infrastructure destruction - single orchestrator.

Steps: stop services → empty S3 → terraform destroy (app then infra) → optional orphan cleanup → optional local Docker cleanup.

Required: --container-type ecs or eks
Options: --force, --dry-run, --clean-local-only, --help
EOF
    exit 0
fi

# Parse arguments (skip first arg which is environment)
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
                [[ "$CONTAINER_TYPE" != "ecs" && "$CONTAINER_TYPE" != "eks" ]] && { log_error "Invalid container type: $CONTAINER_TYPE"; exit 1; }
                shift 2
            else
                log_error "--container-type requires a value (ecs or eks)"; exit 1
            fi
            ;;
        --help|-h)
            cat << EOF
Usage: $0 <environment> --container-type <ecs|eks> [options...]

Complete infrastructure destruction - single orchestrator.

Steps: stop services → empty S3 → terraform destroy (app then infra) → optional orphan cleanup → optional local Docker cleanup.

Required: --container-type ecs or eks
Options: --force, --dry-run, --clean-local-only, --help
EOF
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Validation
[[ ! "$ENVIRONMENT" =~ ^(dev|staging|prod)$ ]] && { log_error "Invalid environment: $ENVIRONMENT"; exit 1; }
[ -z "$CONTAINER_TYPE" ] && { log_error "--container-type is required"; exit 1; }

# AWS account ID for S3 bucket names
if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
    source "$REPO_ROOT/run_scripts/shared/load-image-identifiers.sh"
    load_image_identifiers "aws" || exit 1
fi

log_step "Infrastructure Destruction (slim orchestrator)"
log_warning "════════════════════════════════════════════════════════════════"
log_warning "WARNING: This will DESTROY ALL infrastructure for $ENVIRONMENT"
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

# --- Step 1: Stop ECS/EKS services ---
stop_services() {
    log_step "Step 1: Stopping $(echo "$CONTAINER_TYPE" | tr '[:lower:]' '[:upper:]') services"
    local cluster_name="${PROJECT_NAME}-${ENVIRONMENT}-cluster"
    if [ "$CONTAINER_TYPE" = "ecs" ]; then
        source "$REPO_ROOT/run_scripts/main_application_scripts/aws/ecs/helpers/stop-ecs-services.sh"
        stop_ecs_services "$cluster_name" "$AWS_PROFILE" "$AWS_REGION" "$DRY_RUN"
    elif [ "$CONTAINER_TYPE" = "eks" ]; then
        source "$REPO_ROOT/run_scripts/main_application_scripts/aws/eks/helpers/stop-eks-services.sh"
        stop_eks_services "$cluster_name" "$AWS_PROFILE" "$AWS_REGION" "$DRY_RUN"
    fi
    echo ""
}

# --- Step 2: Empty S3 buckets ---
empty_s3_buckets() {
    log_step "Step 2: Emptying S3 buckets"
    local buckets_to_empty=(
        "${PROJECT_NAME}-${ENVIRONMENT}-analytics-data-${AWS_ACCOUNT_ID}"
        "${PROJECT_NAME}-${ENVIRONMENT}-frontend-${AWS_ACCOUNT_ID}"
    )
    for bucket in "${buckets_to_empty[@]}"; do
        if aws s3 ls --profile "$AWS_PROFILE" "s3://$bucket" >/dev/null 2>&1; then
            local count; count=$(aws s3 ls "s3://$bucket" --profile "$AWS_PROFILE" --recursive 2>/dev/null | wc -l | tr -d ' ' || echo "0")
            if [ "$count" -gt 0 ]; then
                [ "$DRY_RUN" = "true" ] && { log_info "  [DRY-RUN] Would empty: $bucket"; continue; }
                log_info "  Emptying: $bucket"
                aws s3 rm "s3://$bucket" --profile "$AWS_PROFILE" --recursive 2>&1 || true
                local versioned_json
                versioned_json=$(aws s3api list-object-versions --bucket "$bucket" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null || echo '{"Objects":[],"DeleteMarkers":[]}')
                local delete_payload
                delete_payload=$(echo "$versioned_json" | python3 -c "import sys,json; d=json.load(sys.stdin); o=d.get('Objects',[])+d.get('DeleteMarkers',[]); print(json.dumps({'Objects':o,'Quiet':True}) if o else '')" 2>/dev/null || echo "")
                [ -n "$delete_payload" ] && echo "$delete_payload" | aws s3api delete-objects --bucket "$bucket" --delete file:///dev/stdin --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>&1 || true
                log_success "  Emptied: $bucket"
            else
                log_info "  Already empty: $bucket"
            fi
        else
            log_info "  Bucket does not exist: $bucket"
        fi
    done
    echo ""
}

# --- Step 3: Terraform destroy (app layer then infrastructure) ---
terraform_destroy_all() {
    log_step "Step 3: Terraform destroy (app layer then infrastructure)"
    local tf_script="$REPO_ROOT/run_scripts/main_application_scripts/aws/terraform/teardown.sh"
    [ ! -f "$tf_script" ] && { log_error "Terraform teardown not found: $tf_script"; return 1; }
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would run: $tf_script $ENVIRONMENT all (CONTAINER_TYPE=$CONTAINER_TYPE)"
        echo ""
        return 0
    fi
    export CONTAINER_TYPE
    export AWS_PROFILE AWS_REGION
    [ "$SKIP_CONFIRMATION" = "true" ] || [ "${PREEMPT:-false}" = "true" ] && export PREEMPT=true
    if "$tf_script" "$ENVIRONMENT" "all"; then
        log_success "Terraform teardown complete (app + infrastructure)"
    else
        log_warning "Terraform teardown had issues (retry or use remove-all-aws-resources as fallback)"
        return 1
    fi
    echo ""
}

# --- Step 4: Optional orphan cleanup ---
cleanup_orphaned() {
    log_step "Step 4: Optional orphan cleanup"
    local helper="$SCRIPT_DIR/helpers/cleanup-orphaned-resources.sh"
    [ ! -f "$helper" ] && { log_info "Orphan cleanup script not found; skipping"; echo ""; return 0; }
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would run: $helper --environment $ENVIRONMENT --cont-sys $CONTAINER_TYPE"
        echo ""
        return 0
    fi
    local cmd=("$helper" "--environment" "$ENVIRONMENT" "--cont-sys" "$CONTAINER_TYPE")
    [ "$SKIP_CONFIRMATION" = "true" ] || [ "${PREEMPT:-false}" = "true" ] && cmd+=(--force)
    if "${cmd[@]}"; then
        log_success "Orphan cleanup done"
    else
        log_warning "Orphan cleanup had issues (non-fatal)"
    fi
    echo ""
}

# --- Step 5: Optional local Docker cleanup ---
cleanup_local_images() {
    log_step "Step 5: Local Docker image cleanup"
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

    stop_services || failed=true
    empty_s3_buckets || failed=true
    terraform_destroy_all || failed=true
    cleanup_orphaned || true
    cleanup_local_images || true

    log_step "Destruction Summary"
    if [ "$DRY_RUN" = "true" ]; then
        log_info "DRY-RUN: no resources destroyed"
    elif [ "$failed" = "true" ]; then
        log_warning "Teardown completed with issues; retry or use remove-all-aws-resources as fallback"
    else
        log_success "Complete infrastructure destruction completed for $ENVIRONMENT"
    fi

    [ "$failed" = "true" ] && exit 1
    return 0
}

main "$@"
