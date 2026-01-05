#!/bin/bash
# Cleanup script for orphaned AWS resources (S3 buckets, ECR images)
# Usage: ./cleanup-orphaned-resources.sh [--dry-run] [--force]
#
# This script helps identify and clean up orphaned AWS resources:
# - S3 buckets not managed by Terraform
# - ECR images older than X days or untagged
# - Other resources that might be left over from deployments
#
# Safety: By default, runs in dry-run mode showing what would be deleted
#         Use --force to actually delete resources

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"
source "$SCRIPT_DIR/../common/load-env.sh"

DRY_RUN="${DRY_RUN:-true}"
FORCE_DELETE="false"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=""
PROJECT_NAME="fru"
ENVIRONMENT="dev"

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --force)
            FORCE_DELETE="true"
            DRY_RUN="false"
            ;;
        --dry-run)
            DRY_RUN="true"
            ;;
        --help|-h)
            cat << EOF
Usage: $0 [--dry-run] [--force]

Cleanup orphaned AWS resources for the FRU project.

Options:
  --dry-run    Show what would be deleted without actually deleting (default)
  --force      Actually delete resources (use with caution!)
  --help       Show this help message

Examples:
  $0                    # Dry-run: Show what would be deleted
  $0 --dry-run          # Same as above (explicit)
  $0 --force            # Actually delete orphaned resources

EOF
            exit 0
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
# Main Execution
# ============================================================================
main() {
    cleanup_s3_buckets
    echo ""
    cleanup_ecr_images
    
    echo ""
    if [ "$DRY_RUN" = "true" ]; then
        log_success "Dry-run complete. Review the output above."
        log_info "To actually delete resources, run: $0 --force"
    else
        log_success "Cleanup complete!"
    fi
}

main "$@"

