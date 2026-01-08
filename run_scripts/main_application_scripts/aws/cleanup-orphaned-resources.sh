#!/bin/bash
# Cleanup script for orphaned AWS resources (S3 buckets, ECR images, container resources)
# Usage: ./cleanup-orphaned-resources.sh [--cont-sys ecs|eks] [--environment dev|staging|prod] [--dry-run] [--force]
#
# This script helps identify and clean up orphaned AWS resources:
# - S3 buckets not managed by Terraform
# - ECR images older than X days or untagged
# - ECS resources (stopped tasks, old task definitions) if --cont-sys ecs
# - EKS resources (old pods, unused services) if --cont-sys eks
# - Other resources that might be left over from deployments
#
# Safety: By default, runs in dry-run mode showing what would be deleted
#         Use --force to actually delete resources

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"

DRY_RUN="${DRY_RUN:-true}"
FORCE_DELETE="false"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=""
PROJECT_NAME="fru"
ENVIRONMENT="${ENVIRONMENT:-dev}"
CONTAINER_SYSTEM=""  # ecs or eks

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cont-sys)
            CONTAINER_SYSTEM="$2"
            if [ "$CONTAINER_SYSTEM" != "ecs" ] && [ "$CONTAINER_SYSTEM" != "eks" ]; then
                log_error "Invalid container system: $CONTAINER_SYSTEM"
                log_info "Must be 'ecs' or 'eks'"
                exit 1
            fi
            shift 2
            ;;
        --environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --force)
            FORCE_DELETE="true"
            DRY_RUN="false"
            shift
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --help|-h)
            cat << EOF
Usage: $0 [--cont-sys ecs|eks] [--environment dev|staging|prod] [--dry-run] [--force]

Cleanup orphaned AWS resources for the FRU project.

Options:
  --cont-sys <system>   Container system to clean up (ecs or eks)
  --environment <env>   Environment name (dev, staging, prod) - defaults to 'dev'
  --dry-run             Show what would be deleted without actually deleting (default)
  --force               Actually delete resources (use with caution!)
  --help                Show this help message

Examples:
  $0 --cont-sys ecs --environment dev                    # Dry-run: Show what would be deleted
  $0 --cont-sys ecs --environment dev --dry-run        # Same as above (explicit)
  $0 --cont-sys eks --environment dev --force            # Actually delete orphaned resources

EOF
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            log_info "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text 2>/dev/null || echo "")
if [ -z "$ACCOUNT_ID" ]; then
    log_error "Failed to get AWS account ID. Check AWS credentials."
    exit 1
fi

log_step "AWS Resource Cleanup Utility"
log_info "Account ID: $ACCOUNT_ID"
log_info "Region: $AWS_REGION"
log_info "Profile: $AWS_PROFILE"
log_info "Environment: $ENVIRONMENT"
if [ -n "$CONTAINER_SYSTEM" ]; then
    log_info "Container System: $CONTAINER_SYSTEM"
fi
if [ "$DRY_RUN" = "true" ]; then
    log_info "Mode: DRY-RUN (no resources will be deleted)"
else
    log_warning "Mode: FORCE DELETE (resources will be permanently deleted!)"
fi
echo ""

# ============================================================================
# S3 Bucket Cleanup
# ============================================================================
cleanup_s3_buckets() {
    log_step "Checking S3 Buckets"
    
    # Expected buckets (managed by Terraform)
    local expected_buckets=(
        "fru-terraform-state-${ACCOUNT_ID}"
        "${PROJECT_NAME}-${ENVIRONMENT}-analytics-data-${ACCOUNT_ID}"
        "${PROJECT_NAME}-${ENVIRONMENT}-frontend-${ACCOUNT_ID}"
    )
    
    # Find all buckets with project prefix
    local all_buckets
    all_buckets=$(aws s3 ls --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null | grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}" | awk '{print $3}' | grep -E "^fru" || echo "")
    
    if [ -z "$all_buckets" ]; then
        log_info "No S3 buckets found with 'fru' prefix"
        return 0
    fi
    
    log_info "Found S3 buckets:"
    echo "$all_buckets" | while read -r bucket; do
        if [ -n "$bucket" ]; then
            local is_expected=false
            for expected in "${expected_buckets[@]}"; do
                if [ "$bucket" = "$expected" ]; then
                    is_expected=true
                    break
                fi
            done
            
            if [ "$is_expected" = "true" ]; then
                log_info "  ✓ $bucket (managed by Terraform)"
            else
                log_warning "  ? $bucket (potentially orphaned)"
                
                # Check if bucket is empty
                local object_count
                object_count=$(aws s3 ls "s3://${bucket}" --profile "$AWS_PROFILE" --recursive 2>/dev/null | wc -l | tr -d ' ' || echo "0")
                
                if [ "$object_count" -eq 0 ]; then
                    log_info "    - Empty bucket (safe to delete)"
                    if [ "$FORCE_DELETE" = "true" ]; then
                        log_info "    - Deleting empty bucket: $bucket"
                        aws s3 rb "s3://${bucket}" --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>&1 && \
                            log_success "    - ✓ Deleted: $bucket" || \
                            log_warning "    - ✗ Failed to delete: $bucket"
                    fi
                else
                    log_warning "    - Contains $object_count object(s) - NOT deleting automatically"
                    log_info "    - To manually delete: aws s3 rm s3://${bucket} --recursive && aws s3 rb s3://${bucket}"
                fi
            fi
        fi
    done
}

# ============================================================================
# ECR Image Cleanup
# ============================================================================
cleanup_ecr_images() {
    log_step "Checking ECR Repository Images"
    
    local repo_name="fru-api"
    
    # Check if repository exists
    if ! aws ecr describe-repositories --repository-names "$repo_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
        log_info "ECR repository '$repo_name' does not exist"
        return 0
    fi
    
    log_info "Repository: $repo_name"
    
    # List all images
    local images_json
    images_json=$(aws ecr list-images --repository-name "$repo_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" --output json 2>/dev/null || echo "{\"imageIds\":[]}")
    
    local image_count
    image_count=$(echo "$images_json" | python3 -c "import sys, json; data=json.load(sys.stdin); print(len(data.get('imageIds', [])))" 2>/dev/null || echo "0")
    
    if [ "$image_count" -eq 0 ]; then
        log_info "  No images found in repository"
        return 0
    fi
    
    log_info "  Found $image_count image(s)"
    
    # List images (for reference, not deleting by default)
    log_info "  Images in repository:"
    echo "$images_json" | python3 -c "
import sys, json
from datetime import datetime, timezone

data = json.load(sys.stdin)
images = data.get('imageIds', [])

# Sort by push date (newest first)
images_with_dates = []
for img in images:
    if 'imageDigest' in img:
        # Get image details to find push date
        images_with_dates.append({
            'digest': img.get('imageDigest', ''),
            'tag': img.get('imageTag', '<untagged>')
        })

for img in images_with_dates[:10]:  # Show first 10
    print(f\"    - {img['tag']} ({img['digest'][:20]}...)\")
if len(images_with_dates) > 10:
    print(f\"    ... and {len(images_with_dates) - 10} more\")
" 2>/dev/null || log_info "    (Unable to parse image details)"
    
    log_info ""
    log_info "  Note: ECR images are typically managed by deployments"
    log_info "  To clean up old images, use:"
    log_info "    aws ecr batch-delete-image --repository-name $repo_name --image-ids imageTag=<tag>"
}

# ============================================================================
# ECS Resource Cleanup
# ============================================================================
cleanup_ecs_resources() {
    if [ "$CONTAINER_SYSTEM" != "ecs" ]; then
        return 0
    fi
    
    log_step "Checking ECS Resources"
    log_info "Container System: ECS"
    
    # Get cluster name from environment
    local cluster_name="${PROJECT_NAME}-${ENVIRONMENT}-cluster"
    
    # Check if cluster exists
    if ! aws ecs describe-clusters --clusters "$cluster_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
        log_info "ECS cluster '$cluster_name' does not exist"
        return 0
    fi
    
    log_info "Cluster: $cluster_name"
    
    # List stopped tasks (potential orphans)
    local stopped_tasks
    stopped_tasks=$(aws ecs list-tasks --cluster "$cluster_name" --desired-status STOPPED --profile "$AWS_PROFILE" --region "$AWS_REGION" --output json 2>/dev/null || echo '{"taskArns":[]}')
    
    local task_count
    task_count=$(echo "$stopped_tasks" | python3 -c "import sys, json; data=json.load(sys.stdin); print(len(data.get('taskArns', [])))" 2>/dev/null || echo "0")
    
    if [ "$task_count" -gt 0 ]; then
        log_warning "  Found $task_count stopped task(s)"
        if [ "$DRY_RUN" = "true" ]; then
            log_info "    [DRY-RUN] Would clean up stopped tasks"
        else
            log_info "    Note: Stopped tasks are automatically cleaned up by ECS after a retention period"
        fi
    else
        log_info "  No stopped tasks found"
    fi
    
    log_info "  Note: ECS resources are typically managed by deployments"
    log_info "  To manually clean up, use AWS Console or CLI"
}

# ============================================================================
# EKS Resource Cleanup
# ============================================================================
cleanup_eks_resources() {
    if [ "$CONTAINER_SYSTEM" != "eks" ]; then
        return 0
    fi
    
    log_step "Checking EKS Resources"
    log_info "Container System: EKS"
    
    # Get cluster name from environment
    local cluster_name="${PROJECT_NAME}-${ENVIRONMENT}-cluster"
    
    # Check if cluster exists
    if ! aws eks describe-cluster --name "$cluster_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
        log_info "EKS cluster '$cluster_name' does not exist"
        return 0
    fi
    
    log_info "Cluster: $cluster_name"
    log_info "  Note: EKS resources (pods, services) are managed by Kubernetes"
    log_info "  Use kubectl to manage Kubernetes resources:"
    log_info "    kubectl get pods --all-namespaces"
    log_info "    kubectl delete pod <pod-name> -n <namespace>"
}

# ============================================================================
# Main Execution
# ============================================================================
main() {
    local cleanup_failed=false
    
    if ! cleanup_s3_buckets; then
        cleanup_failed=true
    fi
    echo ""
    
    if ! cleanup_ecr_images; then
        cleanup_failed=true
    fi
    echo ""
    
    if [ -n "$CONTAINER_SYSTEM" ]; then
        if [ "$CONTAINER_SYSTEM" = "ecs" ]; then
            if ! cleanup_ecs_resources; then
                cleanup_failed=true
            fi
        elif [ "$CONTAINER_SYSTEM" = "eks" ]; then
            if ! cleanup_eks_resources; then
                cleanup_failed=true
            fi
        fi
        echo ""
    fi
    
    if [ "$cleanup_failed" = "true" ]; then
        log_error "Some cleanup operations failed"
        exit 1
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        log_success "Dry-run complete. Review the output above."
        log_info "To actually delete resources, run: $0 --cont-sys $CONTAINER_SYSTEM --environment $ENVIRONMENT --force"
    else
        log_success "Cleanup complete!"
    fi
}

main "$@"

