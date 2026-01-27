#!/bin/bash
# Cleanup script for orphaned AWS resources (S3 buckets, ECR images, container resources)
# Usage: ./cleanup-orphaned-resources.sh [--cont-sys ecs|eks] [--environment dev|staging|prod] [--dry-run] [--force] [--ecr-retention-days N] [--keep-images N]
#
# This script helps identify and clean up orphaned AWS resources:
# - S3 buckets not managed by Terraform (empty and not in use)
# - ECR images older than X days or untagged (not in use by active services)
# - ECS resources (old task definitions not in use, stopped tasks) if --cont-sys ecs
# - EKS resources (old pods, unused services) if --cont-sys eks
# - Other resources that might be left over from deployments
#
# Safety: By default, runs in dry-run mode showing what would be deleted
#         Use --force to actually delete resources
#         Only deletes resources that are verified to be unused/orphaned

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"

DRY_RUN="${DRY_RUN:-false}"
FORCE_DELETE="false"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"
# ACCOUNT_ID removed - use AWS_ACCOUNT_ID directly
PROJECT_NAME="fru"
ENVIRONMENT="${ENVIRONMENT:-dev}"
CONTAINER_SYSTEM=""  # ecs or eks
ECR_RETENTION_DAYS=7  # Keep images newer than this
KEEP_RECENT_IMAGES=5   # Always keep N most recent images regardless of age

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
        --ecr-retention-days)
            ECR_RETENTION_DAYS="$2"
            if ! [[ "$ECR_RETENTION_DAYS" =~ ^[0-9]+$ ]] || [ "$ECR_RETENTION_DAYS" -lt 1 ]; then
                log_error "Invalid retention days: $ECR_RETENTION_DAYS (must be positive integer)"
                exit 1
            fi
            shift 2
            ;;
        --keep-images)
            KEEP_RECENT_IMAGES="$2"
            if ! [[ "$KEEP_RECENT_IMAGES" =~ ^[0-9]+$ ]] || [ "$KEEP_RECENT_IMAGES" -lt 0 ]; then
                log_error "Invalid keep images count: $KEEP_RECENT_IMAGES (must be non-negative integer)"
                exit 1
            fi
            shift 2
            ;;
        --help|-h)
            cat << EOF
Usage: $0 [--cont-sys ecs|eks] [--environment dev|staging|prod] [--dry-run] [--force] [--ecr-retention-days N] [--keep-images N]

Cleanup orphaned AWS resources for the FRU project.

Options:
  --cont-sys <system>      Container system to clean up (ecs or eks)
  --environment <env>      Environment name (dev, staging, prod) - defaults to 'dev'
  --dry-run                Show what would be deleted without actually deleting
  --force                  Actually delete resources (use with caution!)
                          Note: Without --force, script shows what would be deleted but doesn't delete
  --ecr-retention-days N   Keep ECR images newer than N days (default: 7)
  --keep-images N          Always keep N most recent images regardless of age (default: 5)
  --help                   Show this help message

Examples:
  $0 --cont-sys ecs --environment dev                    # Dry-run: Show what would be deleted
  $0 --cont-sys ecs --environment dev --dry-run        # Same as above (explicit)
  $0 --cont-sys eks --environment dev --force            # Actually delete orphaned resources
  $0 --ecr-retention-days 7 --keep-images 3             # Keep images < 7 days old, always keep 3 newest

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

# Get AWS account ID (using centralized resolution)
if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
    source "$REPO_ROOT/run_scripts/shared/load-image-identifiers.sh"
    load_image_identifiers "aws" || exit 1
fi
# Use AWS_ACCOUNT_ID directly (no need for separate ACCOUNT_ID variable)

log_step "AWS Resource Cleanup Utility"
log_info "Account ID: $AWS_ACCOUNT_ID"
log_info "Region: $AWS_REGION"
log_info "Profile: $AWS_PROFILE"
log_info "Environment: $ENVIRONMENT"
if [ -n "$CONTAINER_SYSTEM" ]; then
    log_info "Container System: $CONTAINER_SYSTEM"
fi
log_info "ECR Retention: $ECR_RETENTION_DAYS days (keeping $KEEP_RECENT_IMAGES most recent)"
if [ "$DRY_RUN" = "true" ]; then
    log_info "Mode: DRY-RUN (no resources will be deleted)"
else
    log_warning "Mode: FORCE DELETE (resources will be permanently deleted!)"
fi
echo ""

# ============================================================================
# S3 Bucket Cleanup
# ============================================================================
# Identifies and deletes orphaned S3 buckets that are:
# - Not managed by Terraform (not in expected list)
# - Empty or can be emptied (with --force flag)
# - Not referenced by CloudFront distributions
#
# Bucket Classification:
# 1. Terraform-managed: Created and managed by Terraform (e.g., fru-dev-frontend-{ACCOUNT_ID})
#    - These are NEVER deleted by this script
# 2. Orphaned: Not in expected list, potentially safe to delete
#    - Empty buckets: Deleted immediately with --force
#    - Non-empty buckets: Emptied first, then deleted (with --force)
#    - CloudFront origins: Skipped (must remove CloudFront distribution first)
# ============================================================================
cleanup_s3_buckets() {
    log_step "Checking S3 Buckets"
    
    # Expected buckets (managed by Terraform)
    local expected_buckets=(
        "fru-terraform-state-${AWS_ACCOUNT_ID}"
        "${PROJECT_NAME}-${ENVIRONMENT}-analytics-data-${AWS_ACCOUNT_ID}"
        "${PROJECT_NAME}-${ENVIRONMENT}-frontend-${AWS_ACCOUNT_ID}"
    )
    
    log_info "Expected buckets (managed by Terraform - will NOT delete):"
    for expected in "${expected_buckets[@]}"; do
        log_info "  - $expected"
    done
    echo ""
    
    # Find all buckets with project prefix
    log_info "Searching for buckets with 'fru' prefix..."
    local all_buckets
    all_buckets=$(aws s3 ls --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null | grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}" | awk '{print $3}' | grep -E "^fru" || echo "")
    
    if [ -z "$all_buckets" ]; then
        log_info "No S3 buckets found with 'fru' prefix"
        return 0
    fi
    
    local buckets_found=0
    local buckets_expected=0
    local buckets_orphaned=0
    local buckets_deleted=0
    local buckets_skipped=0
    
    log_info "Found S3 buckets:"
    while IFS= read -r bucket; do
        if [ -z "$bucket" ]; then
            continue
        fi
        
        buckets_found=$((buckets_found + 1))
        
        local is_expected=false
        for expected in "${expected_buckets[@]}"; do
            if [ "$bucket" = "$expected" ]; then
                is_expected=true
                buckets_expected=$((buckets_expected + 1))
                log_info "  [$buckets_found] ✓ $bucket (managed by Terraform - skipping)"
                break
            fi
        done
        
        if [ "$is_expected" = "true" ]; then
            continue
        fi
        
        buckets_orphaned=$((buckets_orphaned + 1))
        log_warning "  [$buckets_found] ? $bucket (potentially orphaned)"
        log_info "    Checking bucket status..."
        
        # Check if bucket is empty (including versioned objects)
        local object_count=0
        local version_count=0
        local delete_markers=0
        
        # Count regular objects
        log_info "    - Counting regular objects..."
        object_count=$(aws s3 ls "s3://${bucket}" --profile "$AWS_PROFILE" --recursive 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        log_info "      Regular objects: $object_count"
        
        # Check for versioned objects (if versioning is enabled)
        local versioning_status
        versioning_status=$(aws s3api get-bucket-versioning --bucket "$bucket" --profile "$AWS_PROFILE" --region "$AWS_REGION" --output text 2>/dev/null || echo "Disabled")
        log_info "    - Versioning status: ${versioning_status:-Disabled}"
        
        if [ "$versioning_status" = "Enabled" ] || [ "$versioning_status" = "Suspended" ]; then
            log_info "    - Counting versioned objects..."
            version_count=$(aws s3api list-object-versions --bucket "$bucket" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'length(Versions[])' --output text 2>/dev/null || echo "0")
            delete_markers=$(aws s3api list-object-versions --bucket "$bucket" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'length(DeleteMarkers[])' --output text 2>/dev/null || echo "0")
            log_info "      Versioned objects: $version_count"
            log_info "      Delete markers: $delete_markers"
        fi
        
        local total_objects=$((object_count + version_count))
        log_info "    - Total objects: $total_objects"
        
        # List sample objects if bucket is not empty
        if [ "$object_count" -gt 0 ]; then
            log_info "    - Sample objects in bucket (first 5):"
            aws s3 ls "s3://${bucket}" --profile "$AWS_PROFILE" --recursive 2>/dev/null | head -5 | while read -r line; do
                log_info "        $line"
            done
            if [ "$object_count" -gt 5 ]; then
                log_info "        ... and $((object_count - 5)) more object(s)"
            fi
        fi
        
        # Check if bucket is referenced by CloudFront
        log_info "    - Checking CloudFront references..."
        local is_cloudfront_origin=false
        local cloudfront_dists
        cloudfront_dists=$(aws cloudfront list-distributions --profile "$AWS_PROFILE" --query "DistributionList.Items[?Origins.Items[?DomainName=='${bucket}.s3.${AWS_REGION}.amazonaws.com' || DomainName=='${bucket}.s3.amazonaws.com']].Id" --output text 2>/dev/null || echo "")
        if [ -n "$cloudfront_dists" ] && [ "$cloudfront_dists" != "None" ]; then
            is_cloudfront_origin=true
            log_warning "      Referenced by CloudFront distribution(s): $cloudfront_dists"
        else
            log_info "      Not referenced by CloudFront"
        fi
        
        # Decision logic with explicit reasons
        echo ""
        log_info "    ┌─ DELETION DECISION ──────────────────────────────────────"
        if [ "$is_cloudfront_origin" = "true" ]; then
            log_warning "    │ ✗ NOT DELETED - BLOCKED BY: CloudFront Reference"
            log_info "    │   Reason: Bucket is actively used by CloudFront distribution"
            log_info "    │   - CloudFront distribution(s): $cloudfront_dists"
            log_info "    │   - Action: Remove CloudFront distribution first, then retry"
            log_info "    └─────────────────────────────────────────────────────────"
            buckets_skipped=$((buckets_skipped + 1))
        else
            # Eligible for deletion (empty or with objects - will delete with --force)
            if [ "$total_objects" -eq 0 ]; then
                log_success "    │ ✓ ELIGIBLE FOR DELETION"
                log_info "    │   Reason: Bucket is empty and not in use"
                log_info "    │   - Object count: 0"
                log_info "    │   - CloudFront reference: None"
            else
                log_success "    │ ✓ ELIGIBLE FOR DELETION (with --force)"
                log_info "    │   Reason: Bucket is orphaned (not Terraform-managed, not in use)"
                log_info "    │   - Object count: $total_objects"
                log_info "    │   - CloudFront reference: None"
                log_warning "    │   - WARNING: Bucket contains data that will be deleted!"
            fi
            log_info "    └─────────────────────────────────────────────────────────"
            
            if [ "$FORCE_DELETE" = "true" ]; then
                log_warning "    >>> S3 BUCKET DELETION: $bucket <<<"
                log_info "    - Attempting to delete orphaned bucket: $bucket"
                
                # If bucket has objects, delete them first
                if [ "$total_objects" -gt 0 ]; then
                    log_warning "    - WARNING: Deleting $total_objects object(s) from bucket..."
                    # Delete regular objects
                    if [ "$object_count" -gt 0 ]; then
                        log_info "    - Deleting regular objects..."
                        aws s3 rm "s3://${bucket}" --profile "$AWS_PROFILE" --recursive 2>&1 || {
                            log_warning "    - Some objects may have failed to delete"
                        }
                    fi
                    
                    # Delete versioned objects and delete markers
                    if [ "$version_count" -gt 0 ] || [ "$delete_markers" -gt 0 ]; then
                        log_info "    - Deleting versioned objects and delete markers..."
                        aws s3api list-object-versions --bucket "$bucket" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null | \
                            python3 -c "
import sys, json
data = json.load(sys.stdin)
objects = data.get('Objects', []) + data.get('DeleteMarkers', [])
if objects:
    print(json.dumps({'Objects': objects, 'Quiet': True}))
" 2>/dev/null | \
                            aws s3api delete-objects --bucket "$bucket" --delete file:///dev/stdin --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>&1 || {
                            log_warning "    - Some versioned objects may have failed to delete"
                        }
                    fi
                fi
                
                # Disable versioning first if enabled
                if [ "$versioning_status" = "Enabled" ]; then
                    log_info "    - Suspending versioning..."
                    aws s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Suspended --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
                fi
                
                # Delete the bucket
                if aws s3 rb "s3://${bucket}" --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>&1; then
                    log_success "    - ✓ SUCCESS: Deleted bucket: $bucket"
                    buckets_deleted=$((buckets_deleted + 1))
                else
                    local delete_error=$?
                    log_warning "    - ✗ FAILED: Could not delete bucket: $bucket (exit code: $delete_error)"
                    log_info "    - Bucket may still contain objects or have dependencies"
                    buckets_skipped=$((buckets_skipped + 1))
                fi
            else
                if [ "$total_objects" -gt 0 ]; then
                    log_info "    - [DRY-RUN] Would delete bucket with $total_objects object(s): $bucket"
                    log_warning "    - [DRY-RUN] Use --force to actually delete (this will remove all objects!)"
                else
                    log_info "    - [DRY-RUN] Would delete: $bucket"
                fi
            fi
        fi
        echo ""
    done <<< "$all_buckets"
    
    # Summary
    echo ""
    log_info "════════ S3 Bucket Cleanup Summary ════════"
    log_info "  Total buckets found: $buckets_found"
    log_info "  Expected (Terraform-managed): $buckets_expected"
    log_info "  Potentially orphaned: $buckets_orphaned"
    if [ "$FORCE_DELETE" = "true" ]; then
        log_info "  Deleted: $buckets_deleted"
        log_info "  Skipped (not eligible): $buckets_skipped"
    else
        log_info "  Would delete (dry-run): $buckets_deleted"
        log_info "  Would skip: $buckets_skipped"
    fi
}

# ============================================================================
# ECR Image Cleanup
# ============================================================================
# Handles cleanup of orphaned ECR images with special handling for:
# - Multi-architecture images (manifest lists)
# - Images referenced by Docker buildx manifest lists
# 
# Background on Manifest Lists:
# When Docker builds multi-arch images (e.g., for both AMD64 and ARM64), or when
# Docker Desktop on ARM64 Macs uses buildx under the hood, Docker creates a
# "manifest list" (also called a "fat manifest") that references multiple
# individual image manifests. When you try to delete an individual manifest
# that's part of a manifest list, ECR prevents deletion because the manifest
# list still references it.
#
# Solution:
# This script detects manifest list references in deletion failures, extracts
# the manifest list digest from the error message, deletes the manifest list
# first, then retries deleting the individual manifests.
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
    
    # Get images with details (including push date)
    local images_with_details
    images_with_details=$(aws ecr describe-images --repository-name "$repo_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" --output json 2>/dev/null || echo '{"imageDetails":[]}')
    
    local image_count
    image_count=$(echo "$images_with_details" | python3 -c "import sys, json; data=json.load(sys.stdin); print(len(data.get('imageDetails', [])))" 2>/dev/null || echo "0")
    
    if [ "$image_count" -eq 0 ]; then
        log_info "  No images found in repository"
        return 0
    fi
    
    log_info "  Found $image_count image(s) in repository"
    echo ""
    
    # Show summary of all images in repository (compact format, one per line)
    log_info "  All images in repository:"
    echo "$images_with_details" | python3 -c "
import sys, json
from datetime import datetime

data = json.load(sys.stdin)
images = data.get('imageDetails', [])
# Sort by push date (newest first)
images_sorted = sorted(images, key=lambda x: x.get('imagePushedAt', ''), reverse=True)

for idx, img in enumerate(images_sorted, 1):
    tags = img.get('imageTags', [])
    digest = img.get('imageDigest', 'N/A')
    pushed_at = img.get('imagePushedAt', '')
    size_bytes = img.get('imageSizeInBytes', 0)
    
    # Format pushed date (short format)
    pushed_str = 'N/A'
    if pushed_at:
        try:
            dt = datetime.fromisoformat(pushed_at.replace('Z', '+00:00'))
            pushed_str = dt.strftime('%Y-%m-%d %H:%M')
        except:
            pushed_str = pushed_at[:16] if len(pushed_at) >= 16 else pushed_at
    
    # Format size
    size_str = 'N/A'
    if size_bytes and size_bytes > 0:
        if size_bytes < 1024:
            size_str = f'{size_bytes}B'
        elif size_bytes < 1024 * 1024:
            size_str = f'{size_bytes / 1024:.1f}KB'
        elif size_bytes < 1024 * 1024 * 1024:
            size_str = f'{size_bytes / (1024 * 1024):.1f}MB'
        else:
            size_str = f'{size_bytes / (1024 * 1024 * 1024):.2f}GB'
    
    # Show tag(s) or untagged, wrapped in < >
    tag_str = ', '.join(tags) if tags else 'untagged'
    if len(tag_str) > 50:
        tag_str = tag_str[:47] + '...'
    
    # Format: (index) <tag> | pushed_date | size | full digest
    print(f\"    ({idx}) <{tag_str}> | {pushed_str} | {size_str} | {digest}\")
" 2>/dev/null || log_info "    (Unable to parse image details)"
    echo ""
    
    # Get images currently in use by ECS services (if ECS is configured)
    local images_in_use_json="[]"
    if [ "$CONTAINER_SYSTEM" = "ecs" ]; then
        local cluster_name="${PROJECT_NAME}-${ENVIRONMENT}-cluster"
        if aws ecs describe-clusters --clusters "$cluster_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
            local services_json
            services_json=$(aws ecs list-services --cluster "$cluster_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" --output json 2>/dev/null || echo '{"serviceArns":[]}')
            local service_arns
            service_arns=$(echo "$services_json" | python3 -c "import sys, json; data=json.load(sys.stdin); print(' '.join(data.get('serviceArns', [])))" 2>/dev/null || echo "")
            
            local in_use_list=()
            for service_arn in $service_arns; do
                local task_def_arn
                task_def_arn=$(aws ecs describe-services --cluster "$cluster_name" --services "$service_arn" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'services[0].taskDefinition' --output text 2>/dev/null || echo "")
                if [ -n "$task_def_arn" ] && [ "$task_def_arn" != "None" ]; then
                    local task_def_json
                    task_def_json=$(aws ecs describe-task-definition --task-definition "$task_def_arn" --profile "$AWS_PROFILE" --region "$AWS_REGION" --output json 2>/dev/null || echo "{}")
                    local image_uri
                    image_uri=$(echo "$task_def_json" | python3 -c "import sys, json; td=json.load(sys.stdin); print(td.get('taskDefinition', {}).get('containerDefinitions', [{}])[0].get('image', ''))" 2>/dev/null || echo "")
                    if [[ "$image_uri" == *"$repo_name"* ]]; then
                        # Extract image digest or tag from URI
                        local image_id
                        image_id=$(echo "$image_uri" | sed -n 's/.*\(sha256:[a-f0-9]\+\|:[^@]*\).*/\1/p' || echo "")
                        if [ -n "$image_id" ]; then
                            in_use_list+=("$image_id")
                        fi
                    fi
                fi
            done
            # Convert bash array to JSON array
            if [ ${#in_use_list[@]} -gt 0 ]; then
                images_in_use_json=$(printf '%s\n' "${in_use_list[@]}" | python3 -c "import sys, json; print(json.dumps([line.strip() for line in sys.stdin if line.strip()]))" 2>/dev/null || echo "[]")
            fi
        fi
    fi
    
    # Identify images to delete: untagged or older than retention period
    local images_to_delete
    images_to_delete=$(echo "$images_with_details" | python3 -c "
import sys, json
from datetime import datetime, timezone, timedelta

data = json.load(sys.stdin)
images = data.get('imageDetails', [])
retention_days = $ECR_RETENTION_DAYS
keep_recent = $KEEP_RECENT_IMAGES
images_in_use = $images_in_use_json

# Sort by push date (newest first)
images_sorted = sorted(images, key=lambda x: x.get('imagePushedAt', ''), reverse=True)

images_to_delete = []
images_to_keep = []

cutoff_date = datetime.now(timezone.utc) - timedelta(days=retention_days)

for idx, img in enumerate(images_sorted):
    image_digest = img.get('imageDigest', '')
    image_tags = img.get('imageTags', [])
    pushed_at_str = img.get('imagePushedAt', '')
    
    # Check if in use
    is_in_use = False
    for used_id in images_in_use:
        if used_id in image_digest or any(used_id in tag for tag in image_tags):
            is_in_use = True
            break
    
    if is_in_use:
        images_to_keep.append(img)
        continue
    
    # Keep most recent N images regardless of age
    if idx < keep_recent:
        images_to_keep.append(img)
        continue
    
    # Check if untagged
    is_untagged = len(image_tags) == 0
    
    # Check if older than retention period
    is_old = False
    if pushed_at_str:
        try:
            pushed_at = datetime.fromisoformat(pushed_at_str.replace('Z', '+00:00'))
            is_old = pushed_at < cutoff_date
        except:
            pass
    
    if is_untagged or is_old:
        images_to_delete.append(img)
    else:
        images_to_keep.append(img)

# Output images to delete as JSON
print(json.dumps(images_to_delete))
" 2>/dev/null || echo "[]")
    
    local delete_count
    delete_count=$(echo "$images_to_delete" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    
    echo ""
    log_info "ECR Image Cleanup Summary:"
    log_info "  Total images in repository: $image_count"
    log_info "  Eligible for deletion: $delete_count"
    echo ""
    
    if [ "$delete_count" -eq 0 ]; then
        log_info "  No orphaned images to clean up"
        log_info "  (All images are either in use, recent, or within retention period)"
    else
        log_warning "  Found $delete_count orphaned image(s) to delete"
        
        # Show image details (both dry-run and actual deletion) - compact format
        log_info "  Images to delete:"
        echo "$images_to_delete" | python3 -c "
import sys, json
from datetime import datetime

images = json.load(sys.stdin)
for idx, img in enumerate(images, 1):
    tags = img.get('imageTags', [])
    digest = img.get('imageDigest', 'N/A')
    pushed_at = img.get('imagePushedAt', '')
    size_bytes = img.get('imageSizeInBytes', 0)
    
    # Format pushed date (short format)
    pushed_str = 'N/A'
    if pushed_at:
        try:
            dt = datetime.fromisoformat(pushed_at.replace('Z', '+00:00'))
            pushed_str = dt.strftime('%Y-%m-%d %H:%M')
        except:
            pushed_str = pushed_at[:16] if len(pushed_at) >= 16 else pushed_at
    
    # Format size
    size_str = 'N/A'
    if size_bytes and size_bytes > 0:
        if size_bytes < 1024:
            size_str = f'{size_bytes}B'
        elif size_bytes < 1024 * 1024:
            size_str = f'{size_bytes / 1024:.1f}KB'
        elif size_bytes < 1024 * 1024 * 1024:
            size_str = f'{size_bytes / (1024 * 1024):.1f}MB'
        else:
            size_str = f'{size_bytes / (1024 * 1024 * 1024):.2f}GB'
    
    # Show tag(s) or untagged, wrapped in < >
    tag_str = ', '.join(tags) if tags else 'untagged'
    
    # Format: (index) <tag> | pushed_date | size | full digest
    print(f\"    ({idx}) <{tag_str}> | {pushed_str} | {size_str} | {digest}\")
" 2>/dev/null || log_info "    (Unable to parse image details)"
        
        if [ "$DRY_RUN" = "true" ]; then
            log_info ""
            log_info "  [DRY-RUN] Above images would be deleted (use --force to actually delete)"
        else
            # Delete images
            # Note: We handle manifest lists (multi-arch images) automatically by detecting
            # failures and retrying after deleting manifest lists. See comment block above
            # cleanup_ecr_images() for details on why manifest lists exist.
            
            echo ""
            log_info "  Proceeding with deletion..."
            
            # Build list of image IDs to delete
            local delete_image_ids
            delete_image_ids=$(echo "$images_to_delete" | python3 -c "
import sys, json
images = json.load(sys.stdin)
image_ids = []
for img in images:
    img_id = {}
    if 'imageDigest' in img:
        img_id['imageDigest'] = img['imageDigest']
    if 'imageTags' in img and img['imageTags']:
        img_id['imageTag'] = img['imageTags'][0]
    if img_id:
        image_ids.append(img_id)
print(json.dumps(image_ids))
" 2>/dev/null || echo "[]")
            
            if [ "$delete_image_ids" != "[]" ] && [ -n "$delete_image_ids" ]; then
                
                # First attempt: Try to delete images directly
                local delete_result
                delete_result=$(aws ecr batch-delete-image \
                    --repository-name "$repo_name" \
                    --image-ids "$delete_image_ids" \
                    --profile "$AWS_PROFILE" \
                    --region "$AWS_REGION" \
                    --output json 2>&1)
                
                local delete_exit_code=$?
                local deleted_success=0
                local failure_count=0
                
                if [ $delete_exit_code -eq 0 ]; then
                    deleted_success=$(echo "$delete_result" | python3 -c "import sys, json; data=json.load(sys.stdin); print(len(data.get('imageIds', [])))" 2>/dev/null || echo "0")
                    failure_count=$(echo "$delete_result" | python3 -c "import sys, json; data=json.load(sys.stdin); print(len(data.get('failures', [])))" 2>/dev/null || echo "0")
                fi
                
                # If we have failures due to manifest lists, extract manifest list digests from error messages
                if [ "$failure_count" -gt 0 ]; then
                    # Extract manifest list digests directly from error messages
                    # Error format: "Requested image referenced by manifest list: [sha256:...]"
                    local manifest_list_digests
                    manifest_list_digests=$(echo "$delete_result" | python3 -c "
import sys, json
import re
data = json.load(sys.stdin)
failures = data.get('failures', [])
manifest_digests = []
for f in failures:
    reason = f.get('failureReason', '')
    code = f.get('failureCode', '')
    # Extract manifest list digest from error message
    # Format: 'Requested image referenced by manifest list: [sha256:...]'
    if 'ImageReferencedByManifestList' in code or 'manifest list' in reason.lower():
        # Look for sha256: followed by 64 hex characters
        match = re.search(r'sha256:[a-f0-9]{64}', reason)
        if match:
            manifest_digests.append(match.group(0))
# Remove duplicates
manifest_digests = list(set(manifest_digests))
print(json.dumps(manifest_digests))
" 2>/dev/null || echo "[]")
                    
                    # Delete manifest lists first, then retry
                    if [ "$manifest_list_digests" != "[]" ] && [ -n "$manifest_list_digests" ]; then
                        log_info "  Found images referenced by manifest lists (multi-arch images)"
                        log_info "  Deleting manifest lists first, then retrying..."
                        
                        # Build image IDs for manifest lists (by digest only)
                        local manifest_list_ids
                        manifest_list_ids=$(echo "$manifest_list_digests" | python3 -c "
import sys, json
digests = json.load(sys.stdin)
ids = [{'imageDigest': d} for d in digests]
print(json.dumps(ids))
" 2>/dev/null || echo "[]")
                        
                        if [ "$manifest_list_ids" != "[]" ]; then
                            # Delete manifest lists
                            aws ecr batch-delete-image \
                                --repository-name "$repo_name" \
                                --image-ids "$manifest_list_ids" \
                                --profile "$AWS_PROFILE" \
                                --region "$AWS_REGION" \
                                --output json >/dev/null 2>&1 || true
                            
                            # Wait a moment for ECR to process the deletion
                            sleep 2
                            
                            # Retry deleting the original images
                            log_info "  Retrying deletion of individual images..."
                            delete_result=$(aws ecr batch-delete-image \
                                --repository-name "$repo_name" \
                                --image-ids "$delete_image_ids" \
                                --profile "$AWS_PROFILE" \
                                --region "$AWS_REGION" \
                                --output json 2>&1)
                            delete_exit_code=$?
                            
                            if [ $delete_exit_code -eq 0 ]; then
                                deleted_success=$(echo "$delete_result" | python3 -c "import sys, json; data=json.load(sys.stdin); print(len(data.get('imageIds', [])))" 2>/dev/null || echo "0")
                                failure_count=$(echo "$delete_result" | python3 -c "import sys, json; data=json.load(sys.stdin); print(len(data.get('failures', [])))" 2>/dev/null || echo "0")
                            fi
                        fi
                    fi
                fi
                
                # Report results with details
                if [ $delete_exit_code -eq 0 ]; then
                    if [ "$deleted_success" -gt 0 ]; then
                        log_success "  ✓ SUCCESS: Deleted $deleted_success image(s)"
                        
                        # Show details of successfully deleted images
                        if [ "$deleted_success" -le 20 ]; then
                            log_info "  Successfully deleted images:"
                            echo "$delete_result" | python3 -c "
import sys, json
from datetime import datetime

data = json.load(sys.stdin)
deleted = data.get('imageIds', [])
for idx, img_id in enumerate(deleted, 1):
    tag = img_id.get('imageTag', '<untagged>')
    digest = img_id.get('imageDigest', 'N/A')
    digest_short = digest[:16] + '...' if len(digest) > 16 else digest
    print(f\"    [{idx}] Tag: {tag}, Digest: {digest_short}\")
" 2>/dev/null || true
                        fi
                        
                        if [ "$failure_count" -gt 0 ]; then
                            log_warning ""
                            log_warning "  ⚠ Note: $failure_count image(s) could not be deleted (may still be in use or have dependencies)"
                            log_info "  Failed images (first 10):"
                            echo "$delete_result" | python3 -c "
import sys, json
data = json.load(sys.stdin)
failures = data.get('failures', [])[:10]
for idx, f in enumerate(failures, 1):
    reason = f.get('failureReason', 'N/A')
    detail = f.get('failureCode', 'N/A')
    img_id = f.get('imageId', {})
    tag = img_id.get('imageTag', '<untagged>')
    digest = img_id.get('imageDigest', 'N/A')
    digest_short = digest[:16] + '...' if len(digest) > 16 and digest != 'N/A' else digest
    print(f\"    [{idx}] Tag: {tag}\")
    print(f\"        Digest: {digest_short}\")
    print(f\"        Reason: {reason}\")
    print(f\"        Code: {detail}\")
    if idx < len(failures):
        print(\"\")
" 2>/dev/null || log_info "    (Unable to parse failure details)"
                        fi
                    else
                        # No images deleted even though some were eligible - show failure reasons
                        log_warning "  ✗ No images were deleted (0 successes, $failure_count failures)"
                        if [ "$failure_count" -gt 0 ]; then
                            log_info ""
                            log_info "  Failed images (first 10):"
                            echo "$delete_result" | python3 -c "
import sys, json
data = json.load(sys.stdin)
failures = data.get('failures', [])[:10]
for idx, f in enumerate(failures, 1):
    reason = f.get('failureReason', 'N/A')
    detail = f.get('failureCode', 'N/A')
    img_id = f.get('imageId', {})
    tag = img_id.get('imageTag', '<untagged>')
    digest = img_id.get('imageDigest', 'N/A')
    digest_short = digest[:16] + '...' if len(digest) > 16 and digest != 'N/A' else digest
    print(f\"    [{idx}] Tag: {tag}\")
    print(f\"        Digest: {digest_short}\")
    print(f\"        Reason: {reason}\")
    print(f\"        Code: {detail}\")
    if idx < len(failures):
        print(\"\")
" 2>/dev/null || log_info "    (Unable to parse failure details)"
                            
                            # Check if remaining failures are due to manifest lists
                            # This can happen if the manifest list itself is not orphaned (still has tags)
                            # or if the manifest list was not found in our deletion candidates
                            local manifest_list_errors
                            manifest_list_errors=$(echo "$delete_result" | python3 -c "
import sys, json
data = json.load(sys.stdin)
failures = data.get('failures', [])
ml_count = sum(1 for f in failures if 'ImageReferencedByManifestList' in f.get('failureCode', '') or 'manifest list' in f.get('failureReason', '').lower())
print(ml_count)
" 2>/dev/null || echo "0")
                            
                            if [ "$manifest_list_errors" -gt 0 ]; then
                                log_info ""
                                log_info "  Note: $manifest_list_errors image(s) are still referenced by manifest lists"
                                log_info "  This can happen if:"
                                log_info "    - The manifest list itself is not orphaned (still has tags)"
                                log_info "    - The manifest list was not found in the deletion candidates"
                                log_info "  To delete these images, use AWS Console to delete the entire image"
                                log_info "  (manifest list + all manifests) or ensure the manifest list is also orphaned"
                            fi
                        else
                            log_info "  Raw delete_result payload:"
                            log_info "  $delete_result"
                        fi
                    fi
                else
                    log_warning "  ✗ FAILED: Could not delete images"
                    log_info "  Error details: $delete_result"
                fi
            else
                log_warning "  ✗ Could not generate image IDs for deletion"
            fi
        fi
    fi
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
    echo ""
    
    # Get active task definitions (in use by services)
    log_info "Checking active services and their task definitions..."
    local active_task_defs=()
    local services_json
    services_json=$(aws ecs list-services --cluster "$cluster_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" --output json 2>/dev/null || echo '{"serviceArns":[]}')
    local service_arns
    service_arns=$(echo "$services_json" | python3 -c "import sys, json; data=json.load(sys.stdin); print(' '.join(data.get('serviceArns', [])))" 2>/dev/null || echo "")
    
    local service_count=0
    for service_arn in $service_arns; do
        if [ -z "$service_arn" ]; then
            continue
        fi
        service_count=$((service_count + 1))
        local service_name
        service_name=$(echo "$service_arn" | sed 's|.*/||')
        log_info "  Service [$service_count]: $service_name"
        
        local task_def_arn
        task_def_arn=$(aws ecs describe-services --cluster "$cluster_name" --services "$service_arn" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'services[0].taskDefinition' --output text 2>/dev/null || echo "")
        if [ -n "$task_def_arn" ] && [ "$task_def_arn" != "None" ]; then
            # Extract family:revision
            local task_def_family_rev
            task_def_family_rev=$(echo "$task_def_arn" | sed 's|.*/||')
            active_task_defs+=("$task_def_family_rev")
            log_info "    Active task definition: $task_def_family_rev"
        fi
    done
    
    if [ "$service_count" -eq 0 ]; then
        log_info "  No services found in cluster"
    else
        log_info "  Total active services: $service_count"
        log_info "  Active task definitions: ${#active_task_defs[@]}"
    fi
    echo ""
    
    # List all task definitions for the project
    log_info "Checking all task definitions for family: ${PROJECT_NAME}-${ENVIRONMENT}-api"
    local task_def_families=("${PROJECT_NAME}-${ENVIRONMENT}-api")
    local old_task_defs=()
    local total_task_defs=0
    local active_task_defs_found=0
    local kept_for_rollback=0
    
    for family in "${task_def_families[@]}"; do
        log_info "  Searching for task definitions with family prefix: $family"
        local family_task_defs
        family_task_defs=$(aws ecs list-task-definitions --family-prefix "$family" --profile "$AWS_PROFILE" --region "$AWS_REGION" --sort DESC --output json 2>/dev/null || echo '{"taskDefinitionArns":[]}')
        
        local task_def_arns
        task_def_arns=$(echo "$family_task_defs" | python3 -c "import sys, json; data=json.load(sys.stdin); print(' '.join(data.get('taskDefinitionArns', [])))" 2>/dev/null || echo "")
        
        if [ -z "$task_def_arns" ]; then
            log_info "  No task definitions found for family: $family"
            continue
        fi
        
        local count=0
        for task_def_arn in $task_def_arns; do
            if [ -z "$task_def_arn" ]; then
                continue
            fi
            total_task_defs=$((total_task_defs + 1))
            local task_def_id
            task_def_id=$(echo "$task_def_arn" | sed 's|.*/||')
            
            # Skip if this is an active task definition
            local is_active=false
            for active in "${active_task_defs[@]}"; do
                if [ "$task_def_id" = "$active" ]; then
                    is_active=true
                    active_task_defs_found=$((active_task_defs_found + 1))
                    log_info "    [$total_task_defs] ✓ $task_def_id (ACTIVE - in use by service, keeping)"
                    break
                fi
            done
            
            if [ "$is_active" = "true" ]; then
                continue
            fi
            
            # Keep the 5 most recent inactive task definitions (for rollback safety)
            count=$((count + 1))
            if [ "$count" -le 5 ]; then
                kept_for_rollback=$((kept_for_rollback + 1))
                log_info "    [$total_task_defs] ⊙ $task_def_id (KEEPING - recent inactive, for rollback safety)"
            else
                old_task_defs+=("$task_def_arn")
                log_warning "    [$total_task_defs] ✗ $task_def_id (ELIGIBLE FOR DELETION - old and inactive)"
            fi
        done
    done
    echo ""
    
    # Summary and deletion
    log_info "ECS Task Definition Cleanup Summary:"
    log_info "  Total task definitions found: $total_task_defs"
    log_info "  Active (in use by services): $active_task_defs_found"
    log_info "  Kept for rollback safety: $kept_for_rollback"
    log_info "  Eligible for deletion: ${#old_task_defs[@]}"
    
    if [ ${#old_task_defs[@]} -gt 0 ]; then
        log_warning "  Found ${#old_task_defs[@]} old task definition(s) not in use"
        if [ "$DRY_RUN" = "true" ]; then
            log_info "  [DRY-RUN] Would deregister old task definitions:"
            for task_def in "${old_task_defs[@]}"; do
                log_info "    - $task_def"
            done
        else
            log_info "  Deregistering old task definitions..."
            local deleted_count=0
            local failed_count=0
            for task_def in "${old_task_defs[@]}"; do
                if aws ecs deregister-task-definition --task-definition "$task_def" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
                    log_success "    - ✓ SUCCESS: Deregistered: $task_def"
                    deleted_count=$((deleted_count + 1))
                else
                    log_warning "    - ✗ FAILED: Could not deregister: $task_def"
                    failed_count=$((failed_count + 1))
                fi
            done
            log_info "  Deletion results: $deleted_count succeeded, $failed_count failed"
        fi
    else
        echo ""
        log_info "  ┌─ DELETION DECISION ──────────────────────────────────────"
        log_info "  │ ✗ NO TASK DEFINITIONS DELETED"
        if [ "$total_task_defs" -eq 0 ]; then
            log_info "  │   Reason: No task definitions found for family '${PROJECT_NAME}-${ENVIRONMENT}-api'"
            log_info "  │   - Check if the family name is correct"
            log_info "  │   - Check if task definitions exist in this cluster"
        elif [ "$total_task_defs" -le 5 ]; then
            log_info "  │   Reason: All task definitions are protected"
            log_info "  │   - Active (in use): $active_task_defs_found"
            log_info "  │   - Kept for rollback: $kept_for_rollback"
            log_info "  │   - Safety: Script keeps 5 most recent inactive task definitions"
            log_info "  │   - Action: Wait for more task definitions to accumulate, or manually deregister"
        else
            log_info "  │   Reason: All task definitions are either active or kept for safety"
        fi
        log_info "  └─────────────────────────────────────────────────────────"
    fi
    echo ""
    
    # Note: Stopped tasks are automatically cleaned up by ECS after retention period
    log_info "Note: Stopped tasks are automatically cleaned up by ECS after retention period"
    log_info "  (Not manually deleting stopped tasks as they may be needed for debugging)"
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
    
    echo ""
    log_step "Final Summary"
    echo ""
    log_info "════════════════════════════════════════════════════════════════"
    log_info "CLEANUP RESULTS"
    log_info "════════════════════════════════════════════════════════════════"
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info ""
        log_warning "DRY-RUN MODE - No resources were actually deleted"
        log_info ""
        log_info "Resources that WOULD be deleted:"
        log_info "  - Review the detailed output above for each resource type"
        log_info ""
        log_info "To actually delete resources, run:"
        log_info "  $0 --cont-sys $CONTAINER_SYSTEM --environment $ENVIRONMENT --force"
    else
        log_info ""
        log_success "Cleanup operation completed!"
        log_info ""
        log_info "Resources processed:"
        log_info "  - S3 Buckets: Check 'S3 Bucket Cleanup Summary' above"
        log_info "  - ECR Images: Check 'ECR Image Cleanup Summary' above"
        if [ -n "$CONTAINER_SYSTEM" ]; then
            log_info "  - ECS Resources: Check 'ECS Task Definition Cleanup Summary' above"
        fi
        log_info ""
        log_info "Why resources weren't deleted:"
        log_info "  - Review the 'DELETION DECISION' boxes above for each resource"
        log_info "  - Each box shows the specific reason (e.g., 'Non-Empty Bucket', 'In Use', etc.)"
        log_info ""
        log_info "Next steps:"
        log_info "  - For S3 buckets with objects: Empty them first, then re-run"
        log_info "  - For resources in use: Remove dependencies first, then re-run"
        log_info "  - For ECS task definitions: Wait for more to accumulate, or manually deregister"
    fi
    log_info "════════════════════════════════════════════════════════════════"
}

main "$@"

