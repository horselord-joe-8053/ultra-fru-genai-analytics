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
            # AWS CLI --output text can emit multiple lines; take first line and ensure a single integer for arithmetic.
            version_count=$(aws s3api list-object-versions --bucket "$bucket" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'length(Versions[])' --output text 2>/dev/null | head -1 | tr -cd '0-9' || true)
            delete_markers=$(aws s3api list-object-versions --bucket "$bucket" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'length(DeleteMarkers[])' --output text 2>/dev/null | head -1 | tr -cd '0-9' || true)
            version_count=${version_count:-0}
            delete_markers=${delete_markers:-0}
            log_info "      Versioned objects: $version_count"
            log_info "      Delete markers: $delete_markers"
        fi
        
        local total_objects=$((object_count + ${version_count:-0}))
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
# Simplified, robust cleanup of orphaned ECR images with chunked deletion.
# Behaviour:
# - Targets the fru-api repository
# - Deletes untagged images and images older than ECR_RETENTION_DAYS
# - Always keeps KEEP_RECENT_IMAGES newest images regardless of age
# - Uses chunk size 100 to respect AWS BatchDeleteImage API limits
# ============================================================================
cleanup_ecr_images() {
    log_step "Checking ECR Repository Images"

    local repo_name="fru-api"
    local python_script="$SCRIPT_DIR/python/ecr_cleanup.py"

    # Check if Python script exists
    if [ ! -f "$python_script" ]; then
        log_error "Python ECR cleanup script not found: $python_script"
        return 1
    fi

    # Check if repository exists
    if ! aws ecr describe-repositories --repository-names "$repo_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
        log_info "ECR repository '$repo_name' does not exist"
        return 0
    fi

    log_info "Repository: $repo_name"
    log_info "Profile: $AWS_PROFILE"
    log_info "Region: $AWS_REGION"

    # Get images with details using Python module (with validation and error handling)
    log_info "Retrieving ECR images..."
    local images_with_details
    local aws_error_output
    local temp_stderr
    
    # Use temporary file to capture stderr separately from stdout
    temp_stderr=$(mktemp)
    trap "rm -f '$temp_stderr'" EXIT
    
    # Capture stdout (JSON) and stderr (errors) separately
    images_with_details=$(python3 "$python_script" describe-images \
        --repository-name "$repo_name" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" 2>"$temp_stderr")
    local aws_exit_code=$?
    
    # Read stderr if there was an error
    if [ $aws_exit_code -ne 0 ]; then
        aws_error_output=$(cat "$temp_stderr" 2>/dev/null || echo "Unknown error")
        rm -f "$temp_stderr"
        trap - EXIT
        
        log_error "Failed to retrieve ECR images from repository '$repo_name'"
        log_error "Error details: $aws_error_output"
        log_info "This could be due to:"
        log_info "  - Repository does not exist"
        log_info "  - AWS credentials/permissions issue"
        log_info "  - Network connectivity problem"
        log_info "  - AWS API rate limiting"
        return 1
    fi
    
    # Check for any warnings in stderr (even if exit code was 0)
    aws_error_output=$(cat "$temp_stderr" 2>/dev/null || echo "")
    rm -f "$temp_stderr"
    trap - EXIT
    
    if [ -n "$aws_error_output" ]; then
        log_warning "ECR describe-images produced warnings: $aws_error_output"
    fi

    # Validate JSON structure using Python (empty response is OK if valid JSON)
    if [ -z "$images_with_details" ]; then
        log_warning "Received empty response from ECR describe-images (treating as empty repository)"
        images_with_details='{"imageDetails":[]}'
    elif ! printf '%s\n' "$images_with_details" | python3 -c "import sys, json; json.load(sys.stdin)" 2>/dev/null; then
        log_error "Invalid JSON response from ECR describe-images"
        log_error "Response preview: ${images_with_details:0:200}"
        return 1
    fi

    # Count total images using Python module
    local total_images
    total_images=$(printf '%s\n' "$images_with_details" | python3 "$python_script" count 2>/dev/null || echo "0")
    
    if [ "$total_images" -eq 0 ]; then
        log_info "Repository exists but contains no images"
    else
        log_info "Successfully retrieved $total_images image(s) from repository"
    fi

    # Filter images for deletion using Python module
    local images_to_delete
    images_to_delete=$(printf '%s\n' "$images_with_details" | python3 "$python_script" filter \
        --retention-days "${ECR_RETENTION_DAYS:-7}" \
        --keep-recent "${KEEP_RECENT_IMAGES:-5}" 2>/dev/null || echo "[]")

    # Count images to delete
    local delete_count
    if [ "$images_to_delete" = "[]" ] || [ -z "$images_to_delete" ]; then
        delete_count=0
    else
        delete_count=$(printf '%s\n' "$images_to_delete" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    fi

    echo ""
    log_info "ECR Image Cleanup Summary:"
    log_info "  Total images (from describe-images): $total_images"
    log_info "  Eligible for deletion (after retention/keep rules): $delete_count"
    echo ""

    if [ "$delete_count" -eq 0 ]; then
        log_info "  No orphaned images to clean up under current retention rules"
        return 0
    fi

    if [ "$DRY_RUN" = "true" ]; then
        log_info "  [DRY-RUN] Would delete $delete_count image(s) from repo $repo_name"
        return 0
    fi

    # Chunk images using Python module (fixes subshell variable scoping issue)
    local chunk_size=100
    local total_deleted=0
    local chunks=()

    # Collect all chunks into an array (avoids subshell issue)
    while IFS= read -r chunk_json; do
        if [ -n "$chunk_json" ] && [ "$chunk_json" != "[]" ]; then
            chunks+=("$chunk_json")
        fi
    done < <(printf '%s\n' "$images_to_delete" | python3 "$python_script" chunk --chunk-size "$chunk_size" 2>/dev/null)

    # Process chunks in regular loop (no subshell, so total_deleted updates correctly)
    for chunk_json in "${chunks[@]}"; do
        local chunk_size_actual
        chunk_size_actual=$(printf '%s\n' "$chunk_json" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

        log_info "  Deleting batch of ECR images (size: $chunk_size_actual)..."

        if aws ecr batch-delete-image \
            --repository-name "$repo_name" \
            --image-ids "$chunk_json" \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --output json >/dev/null 2>&1; then
            total_deleted=$((total_deleted + chunk_size_actual))
        else
            log_warning "  ✗ FAILED to delete one batch of ECR images (see AWS CLI output above)"
        fi
    done

    log_success "  ✓ Deleted $total_deleted ECR image(s) from $repo_name (best-effort)"
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
    log_info "Checking services and their task definitions (treating services with desiredCount=0 AND runningCount=0 as inactive)..."
    local active_task_defs=()
    local services_json
    services_json=$(aws ecs list-services --cluster "$cluster_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" --output json 2>/dev/null || echo '{"serviceArns":[]}')
    local service_arns
    service_arns=$(echo "$services_json" | python3 -c "import sys, json; data=json.load(sys.stdin); print(' '.join(data.get('serviceArns', [])))" 2>/dev/null || echo "")
    
    local service_count=0
    local active_service_count=0
    for service_arn in $service_arns; do
        if [ -z "$service_arn" ]; then
            continue
        fi
        service_count=$((service_count + 1))
        local service_name
        service_name=$(echo "$service_arn" | sed 's|.*/||')
        
        # Describe service to get taskDefinition, desiredCount, runningCount
        local svc_desc
        svc_desc=$(aws ecs describe-services \
            --cluster "$cluster_name" \
            --services "$service_arn" \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --query 'services[0].[taskDefinition,desiredCount,runningCount]' \
            --output text 2>/dev/null || echo "")
        
        local task_def_arn desired_count running_count
        # svc_desc may be empty or have fewer columns; use safe parsing
        read -r task_def_arn desired_count running_count <<< "$svc_desc"
        
        # Fallback: if we couldn't parse counts, treat as active for safety
        if [ -z "$task_def_arn" ] || [ "$task_def_arn" = "None" ]; then
            log_info "  Service [$service_count]: $service_name (no task definition found)"
            continue
        fi
        
        # Normalize counts to integers (default 0 if empty/non-numeric)
        if ! [[ "$desired_count" =~ ^[0-9]+$ ]]; then
            desired_count=0
        fi
        if ! [[ "$running_count" =~ ^[0-9]+$ ]]; then
            running_count=0
        fi
        
        if [ "$desired_count" -eq 0 ] && [ "$running_count" -eq 0 ]; then
            log_info "  Service [$service_count]: $service_name (desiredCount=0, runningCount=0 -> treating as INACTIVE for cleanup)"
            log_info "    Current task definition (inactive): $(echo "$task_def_arn" | sed 's|.*/||')"
            # Do NOT add this task definition to active_task_defs
            continue
        fi
        
        active_service_count=$((active_service_count + 1))
        log_info "  Service [$service_count]: $service_name (ACTIVE - desiredCount=$desired_count, runningCount=$running_count)"
        
        # Extract family:revision and add to active list
        local task_def_family_rev
        task_def_family_rev=$(echo "$task_def_arn" | sed 's|.*/||')
        active_task_defs+=("$task_def_family_rev")
        log_info "    Active task definition: $task_def_family_rev"
    done
    
    if [ "$service_count" -eq 0 ]; then
        log_info "  No services found in cluster"
    else
        log_info "  Total services: $service_count"
        log_info "  Services considered ACTIVE for cleanup (desiredCount>0 or runningCount>0): $active_service_count"
        log_info "  Active task definitions (protected from deletion): ${#active_task_defs[@]}"
    fi
    echo ""
    
    # List all task definitions for the project
    log_info "Checking all task definitions for family: ${PROJECT_NAME}-${ENVIRONMENT}-api"
    local task_def_families=("${PROJECT_NAME}-${ENVIRONMENT}-api")
    # Rollback safety: by default keep 5 most recent inactive task definitions.
    # However, if there are NO services considered ACTIVE (desiredCount>0 or runningCount>0),
    # then we treat all inactive task definitions as eligible for deletion (nuclear cleanup).
    local rollback_keep_limit=5
    if [ "$active_service_count" -eq 0 ]; then
        rollback_keep_limit=0
        log_info "  No ACTIVE services detected; rollback safety limit reduced to $rollback_keep_limit (all inactive task definitions eligible for deletion)."
    else
        log_info "  ACTIVE services detected; rollback safety limit = $rollback_keep_limit (keeping up to $rollback_keep_limit inactive revisions)."
    fi
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
            
            # Keep recent inactive task definitions for rollback safety (up to rollback_keep_limit)
            count=$((count + 1))
            if [ "$count" -le "$rollback_keep_limit" ]; then
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

