#!/bin/bash
# Standalone CLI tool: Delete AWS resources that can be quickly recreated
#
# This is a standalone utility script (not called by other scripts) for manually
# cleaning up AWS resources that don't have 30-day recovery windows and can be
# promptly recreated by Terraform/run.sh. Use this when you need to perform a
# "nuclear" teardown of all recreatable resources for a specific environment.
#
# Resources deleted:
# - ECS clusters, services, task definitions
# - ECR repositories (images can be rebuilt)
# - S3 buckets (except Terraform state bucket)
# - CloudFront distributions
# - ALB/ELB load balancers
# - VPC, subnets, security groups, NAT gateways, internet gateways, elastic IPs
# - Aurora clusters and instances (with warning - takes time)
#
# Resources preserved:
# - Secrets Manager secrets (30-day recovery window, prevent_destroy=true)
# - Terraform state bucket (needed for state management)
#
# Usage: ./delete-recreatable-resources.sh [dev|prod] [--dry-run] [--skip-confirmation]
#   --dry-run: Show what would be deleted without actually deleting
#   --skip-confirmation: Skip confirmation prompts
#
# Note: For automated teardown via run.sh --preempt, use teardown-resources-all.sh
#       which calls cleanup-orphaned-resources.sh (selective cleanup) instead.

set -e
# Note: We use set -e but handle errors gracefully in delete_resource function
# Some deletions may fail (resources already deleted, dependencies, etc.) and that's OK
# We use || true or if statements to prevent script exit on expected failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"
source "$REPO_ROOT/run_scripts/shared/load-image-identifiers.sh"

# Load environment variables
load_env_file

# Default values
ENVIRONMENT="${1:-dev}"
DRY_RUN=false
SKIP_CONFIRMATION=false

# Parse arguments
shift || true
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-confirmation)
            SKIP_CONFIRMATION=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate environment
if [[ ! "$ENVIRONMENT" =~ ^(dev|prod)$ ]]; then
    log_error "Invalid environment: $ENVIRONMENT"
    log_info "Usage: $0 [dev|prod] [--dry-run] [--skip-confirmation]"
    exit 1
fi

# Set AWS variables
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-fru}"

# Get AWS account ID (using centralized resolution)
if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
    load_image_identifiers "aws" || exit 1
fi
# Use AWS_ACCOUNT_ID directly (no need for separate ACCOUNT_ID variable)

log_step "Delete Recreatable AWS Resources"
log_info "Environment: $ENVIRONMENT"
log_info "Account ID: $AWS_ACCOUNT_ID"
log_info "Region: $AWS_REGION"
log_info "Profile: $AWS_PROFILE"
if [ "$DRY_RUN" = "true" ]; then
    log_info "Mode: DRY-RUN (no resources will be deleted)"
fi
echo ""

# ============================================================================
# Tracking variables for summary
# ============================================================================
SUCCESSFUL_DELETIONS=()
FAILED_DELETIONS=()
PENDING_DELETIONS=()
STEP_START_TIMES_ECS=0
STEP_START_TIMES_ECR=0
STEP_START_TIMES_S3=0
STEP_START_TIMES_CF=0
STEP_START_TIMES_ALB=0
STEP_START_TIMES_AURORA=0
STEP_START_TIMES_VPC=0
STEP_DURATIONS_ECS=0
STEP_DURATIONS_ECR=0
STEP_DURATIONS_S3=0
STEP_DURATIONS_CF=0
STEP_DURATIONS_ALB=0
STEP_DURATIONS_AURORA=0
STEP_DURATIONS_VPC=0
TOTAL_START_TIME=$(date +%s)

# Confirmation prompt
# When PREEMPT=true (run.sh --preempt), skip interactive confirmation to allow
# fully non-interactive teardown from the orchestrator.
if [ "$DRY_RUN" = "false" ] && [ "$SKIP_CONFIRMATION" = "false" ] && [ "${PREEMPT:-false}" != "true" ]; then
    log_warning "This will DELETE AWS resources that can be recreated:"
    log_warning "  - ECS clusters, services, task definitions"
    log_warning "  - ECR repositories"
    log_warning "  - S3 buckets (except Terraform state bucket)"
    log_warning "  - CloudFront distributions"
    log_warning "  - ALB/ELB load balancers"
    log_warning "  - VPC, subnets, security groups, NAT gateways, internet gateways, elastic IPs"
    log_warning "  - Aurora clusters and instances (takes 10-20+ minutes)"
    echo ""
    log_warning "Resources that will be PRESERVED:"
    log_info "  - Secrets Manager secrets (30-day recovery window)"
    log_info "  - Terraform state bucket"
    echo ""
    read -p "Do you want to proceed? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Cancelled by user"
        exit 0
    fi
fi

# ============================================================================
# Helper function to delete resources with error handling
# ============================================================================
delete_resource() {
    local resource_type="$1"
    local resource_id="$2"
    local delete_cmd="$3"
    local resource_key="${resource_type}:${resource_id}"
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would delete $resource_type: $resource_id"
        SUCCESSFUL_DELETIONS+=("$resource_key")
        return 0
    fi
    
    log_info "Deleting $resource_type: $resource_id"
    if eval "$delete_cmd" >/dev/null 2>&1; then
        log_success "  ✓ Deleted: $resource_id"
        SUCCESSFUL_DELETIONS+=("$resource_key")
        return 0
    else
        log_warning "  ⚠ Failed to delete: $resource_id (may not exist or already deleted)"
        FAILED_DELETIONS+=("$resource_key")
        return 1
    fi
}

# ============================================================================
# Helper function to track pending deletions (resources still deleting)
# ============================================================================
track_pending() {
    local resource_type="$1"
    local resource_id="$2"
    local reason="$3"
    local resource_key="${resource_type}:${resource_id}"
    PENDING_DELETIONS+=("$resource_key|$reason")
}

# ============================================================================
# Helper function to start timing a step
# ============================================================================
start_step_timer() {
    local step_name="$1"
    case "$step_name" in
        "ECS Resources")
            STEP_START_TIMES_ECS=$(date +%s)
            ;;
        "ECR Repositories")
            STEP_START_TIMES_ECR=$(date +%s)
            ;;
        "S3 Buckets")
            STEP_START_TIMES_S3=$(date +%s)
            ;;
        "CloudFront Distributions")
            STEP_START_TIMES_CF=$(date +%s)
            ;;
        "Load Balancers")
            STEP_START_TIMES_ALB=$(date +%s)
            ;;
        "Aurora Resources")
            STEP_START_TIMES_AURORA=$(date +%s)
            ;;
        "VPC Resources")
            STEP_START_TIMES_VPC=$(date +%s)
            ;;
    esac
}

# ============================================================================
# Helper function to end timing a step
# ============================================================================
end_step_timer() {
    local step_name="$1"
    local end_time=$(date +%s)
    local duration=0
    
    case "$step_name" in
        "ECS Resources")
            if [ $STEP_START_TIMES_ECS -gt 0 ]; then
                duration=$((end_time - STEP_START_TIMES_ECS))
                STEP_DURATIONS_ECS=$duration
            fi
            ;;
        "ECR Repositories")
            if [ $STEP_START_TIMES_ECR -gt 0 ]; then
                duration=$((end_time - STEP_START_TIMES_ECR))
                STEP_DURATIONS_ECR=$duration
            fi
            ;;
        "S3 Buckets")
            if [ $STEP_START_TIMES_S3 -gt 0 ]; then
                duration=$((end_time - STEP_START_TIMES_S3))
                STEP_DURATIONS_S3=$duration
            fi
            ;;
        "CloudFront Distributions")
            if [ $STEP_START_TIMES_CF -gt 0 ]; then
                duration=$((end_time - STEP_START_TIMES_CF))
                STEP_DURATIONS_CF=$duration
            fi
            ;;
        "Load Balancers")
            if [ $STEP_START_TIMES_ALB -gt 0 ]; then
                duration=$((end_time - STEP_START_TIMES_ALB))
                STEP_DURATIONS_ALB=$duration
            fi
            ;;
        "Aurora Resources")
            if [ $STEP_START_TIMES_AURORA -gt 0 ]; then
                duration=$((end_time - STEP_START_TIMES_AURORA))
                STEP_DURATIONS_AURORA=$duration
            fi
            ;;
        "VPC Resources")
            if [ $STEP_START_TIMES_VPC -gt 0 ]; then
                duration=$((end_time - STEP_START_TIMES_VPC))
                STEP_DURATIONS_VPC=$duration
            fi
            ;;
    esac
}

# ============================================================================
# Helper function to format duration
# ============================================================================
format_duration() {
    local seconds=$1
    if [ $seconds -lt 60 ]; then
        echo "${seconds}s"
    elif [ $seconds -lt 3600 ]; then
        local mins=$((seconds / 60))
        local secs=$((seconds % 60))
        echo "${mins}m ${secs}s"
    else
        local hours=$((seconds / 3600))
        local mins=$(((seconds % 3600) / 60))
        local secs=$((seconds % 60))
        echo "${hours}h ${mins}m ${secs}s"
    fi
}

# ============================================================================
# Step 1: Delete ECS Resources
# ============================================================================
delete_ecs_resources() {
    start_step_timer "ECS Resources"
    log_step "Substep 1: Deleting ECS Resources"
    
    local cluster_name="${PROJECT_NAME}-${ENVIRONMENT}-cluster"
    
    # Check if cluster exists
    if ! aws ecs describe-clusters --clusters "$cluster_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
        log_info "ECS cluster not found: $cluster_name"
        return 0
    fi
    
    # Stop all services
    local services
    services=$(aws ecs list-services --cluster "$cluster_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'serviceArns[]' --output text 2>/dev/null || echo "")
    
    if [ -n "$services" ]; then
        for service in $services; do
            local service_name=$(basename "$service")
            log_info "Stopping and deleting ECS service: $service_name"
            if [ "$DRY_RUN" = "false" ]; then
                # First, scale down to 0
                if aws ecs update-service \
                    --cluster "$cluster_name" \
                    --service "$service_name" \
                    --desired-count 0 \
                    --profile "$AWS_PROFILE" \
                    --region "$AWS_REGION" >/dev/null 2>&1; then
                    log_info "  Scaled service to 0, waiting for tasks to stop..."
                    # Wait for service to fully stop (up to 2 minutes)
                    local wait_attempt=0
                    local max_wait=24  # 2 minutes
                    while [ $wait_attempt -lt $max_wait ]; do
                        local running_count
                        running_count=$(aws ecs describe-services \
                            --cluster "$cluster_name" \
                            --services "$service_name" \
                            --profile "$AWS_PROFILE" \
                            --region "$AWS_REGION" \
                            --query 'services[0].runningCount' \
                            --output text 2>/dev/null || echo "0")
                        if [ "$running_count" = "0" ] || [ "$running_count" = "None" ]; then
                            break
                        fi
                        sleep 5
                        wait_attempt=$((wait_attempt + 1))
                    done
                    
                    # Now delete the service
                    log_info "  Deleting service..."
                    if aws ecs delete-service \
                        --cluster "$cluster_name" \
                        --service "$service_name" \
                        --force \
                        --profile "$AWS_PROFILE" \
                        --region "$AWS_REGION" >/dev/null 2>&1; then
                        SUCCESSFUL_DELETIONS+=("ECS service:$service_name (deleted)")
                    else
                        FAILED_DELETIONS+=("ECS service:$service_name")
                    fi
                else
                    FAILED_DELETIONS+=("ECS service:$service_name")
                fi
            else
                SUCCESSFUL_DELETIONS+=("ECS service:$service_name (dry-run)")
            fi
        done
        
        # Wait a bit more for service deletion to propagate
        if [ "$DRY_RUN" = "false" ]; then
            log_info "Waiting for service deletion to propagate..."
            sleep 5
        fi
    fi
    
    # Stop all running tasks
    local tasks
    tasks=$(aws ecs list-tasks --cluster "$cluster_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'taskArns[]' --output text 2>/dev/null || echo "")
    
    if [ -n "$tasks" ]; then
        for task in $tasks; do
            local task_id=$(basename "$task")
            log_info "Stopping ECS task: $task_id"
            if [ "$DRY_RUN" = "false" ]; then
                if aws ecs stop-task --cluster "$cluster_name" --task "$task" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
                    SUCCESSFUL_DELETIONS+=("ECS task:$task_id (stopped)")
                else
                    FAILED_DELETIONS+=("ECS task:$task_id")
                fi
            else
                SUCCESSFUL_DELETIONS+=("ECS task:$task_id (dry-run)")
            fi
        done
    fi
    
    # Delete cluster (continue even if it fails - might already be deleted or have dependencies)
    if ! delete_resource "ECS cluster" "$cluster_name" \
        "aws ecs delete-cluster --cluster '$cluster_name' --profile '$AWS_PROFILE' --region '$AWS_REGION'"; then
        # Cluster deletion failed - might have active services/tasks, continue anyway
        log_warning "  Cluster deletion failed (may have active services/tasks or already deleted)"
        log_info "  Continuing with other resource deletions..."
    fi
    
    # Delete task definitions (family-based)
    local task_family="${PROJECT_NAME}-${ENVIRONMENT}-api"
    log_info "Deregistering ECS task definitions for family: $task_family"
    if [ "$DRY_RUN" = "false" ]; then
        local task_defs
        task_defs=$(aws ecs list-task-definitions --family-prefix "$task_family" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'taskDefinitionArns[]' --output text 2>/dev/null || echo "")
        for task_def in $task_defs; do
            local task_def_name=$(basename "$task_def")
            log_info "  Deregistering: $task_def_name"
            if aws ecs deregister-task-definition --task-definition "$task_def" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
                SUCCESSFUL_DELETIONS+=("ECS task definition:$task_def_name")
            else
                FAILED_DELETIONS+=("ECS task definition:$task_def_name")
            fi
        done
    else
        # In dry-run, just track as would-be success
        SUCCESSFUL_DELETIONS+=("ECS task definitions:$task_family (dry-run)")
    fi
    
    end_step_timer "ECS Resources"
    echo ""
}

# ============================================================================
# Step 2: Delete ECR Repositories
# ============================================================================
delete_ecr_resources() {
    start_step_timer "ECR Repositories"
    log_step "Substep 2: Deleting ECR Repositories"
    
    local repo_name="${PROJECT_NAME}-api"
    
    # Check if repository exists
    if ! aws ecr describe-repositories --repository-names "$repo_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
        log_info "ECR repository not found: $repo_name"
        echo ""
        return 0
    fi
    
    # Delete all images first
    log_info "Deleting all images in repository: $repo_name"
    if [ "$DRY_RUN" = "false" ]; then
        local image_ids
        image_ids=$(aws ecr list-images --repository-name "$repo_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'imageIds[]' --output json 2>/dev/null || echo "[]")
        if [ "$image_ids" != "[]" ] && [ -n "$image_ids" ]; then
            # The AWS ECR BatchDeleteImage API enforces a hard limit:
            #   InvalidParameterException: Invalid parameter at 'imageIds'
            #   failed to satisfy constraint: 'Member must have length less than or equal to 100'
            # To respect this, we delete images in chunks of at most 100 imageIds per call.
            local image_count
            image_count=$(echo "$image_ids" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
            if [ "$image_count" -gt 0 ]; then
                local deleted_count=0
                local start_index=0
                local chunk_size=100
                local chunk_json
                local chunk_len
                
                log_info "Found $image_count image(s) in ECR repo $repo_name; deleting in batches of up to $chunk_size to satisfy AWS limits."
                
                while [ "$start_index" -lt "$image_count" ]; do
                    # Build a JSON array slice imageIds[start_index:start_index+chunk_size]
                    chunk_json=$(printf '%s\n' "$image_ids" | python3 -c "
import sys, json
ids = json.load(sys.stdin)
start = $start_index
size = $chunk_size
chunk = ids[start:start+size]
print(json.dumps(chunk))
" 2>/dev/null || echo "[]")
                    
                    chunk_len=$(printf '%s\n' "$chunk_json" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
                    if [ "$chunk_len" -eq 0 ]; then
                        break
                    fi
                    
                    log_info "  Deleting batch starting at index $start_index (size: $chunk_len)..."
                    if aws ecr batch-delete-image \
                        --repository-name "$repo_name" \
                        --image-ids "$chunk_json" \
                        --profile "$AWS_PROFILE" \
                        --region "$AWS_REGION" >/dev/null 2>&1; then
                        deleted_count=$((deleted_count + chunk_len))
                    else
                        FAILED_DELETIONS+=("ECR images batch:$repo_name (start_index=$start_index,size=$chunk_len)")
                        log_warning "  ✗ FAILED to delete ECR image batch starting at index $start_index"
                    fi
                    
                    start_index=$((start_index + chunk_size))
                done
                
                if [ "$deleted_count" -gt 0 ]; then
                    SUCCESSFUL_DELETIONS+=("ECR images:$repo_name ($deleted_count/$image_count images deleted)")
                else
                    FAILED_DELETIONS+=("ECR images:$repo_name (no images deleted)")
                fi
            fi
        else
            log_info "No images found in ECR repository: $repo_name"
        fi
    else
        SUCCESSFUL_DELETIONS+=("ECR images:$repo_name (dry-run)")
    fi
    
    # Delete repository
    delete_resource "ECR repository" "$repo_name" \
        "aws ecr delete-repository --repository-name '$repo_name' --force --profile '$AWS_PROFILE' --region '$AWS_REGION'"
    
    end_step_timer "ECR Repositories"
    echo ""
}

# ============================================================================
# Step 3: Delete S3 Buckets (except Terraform state bucket)
# ============================================================================
delete_s3_resources() {
    start_step_timer "S3 Buckets"
    log_step "Substep 3: Deleting S3 Buckets"
    
    local buckets=(
        "${PROJECT_NAME}-${ENVIRONMENT}-analytics-data-${AWS_ACCOUNT_ID}"
        "${PROJECT_NAME}-${ENVIRONMENT}-frontend-${AWS_ACCOUNT_ID}"
    )
    
    # Note: Terraform state bucket is preserved
    local state_bucket="${PROJECT_NAME}-terraform-state-${AWS_ACCOUNT_ID}"
    log_info "Preserving Terraform state bucket: $state_bucket"
    
    for bucket in "${buckets[@]}"; do
        # Check if bucket exists
        if ! aws s3 ls --profile "$AWS_PROFILE" "s3://$bucket" >/dev/null 2>&1; then
            log_info "S3 bucket not found: $bucket"
            continue
        fi
        
        # Empty bucket first
        log_info "Emptying S3 bucket: $bucket"
        if [ "$DRY_RUN" = "false" ]; then
            aws s3 rm "s3://$bucket" --recursive --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
            
            # Delete versioned objects
            local versioned_json
            versioned_json=$(aws s3api list-object-versions --bucket "$bucket" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null || echo '{"Objects":[],"DeleteMarkers":[]}')
            
            local delete_payload
            delete_payload=$(echo "$versioned_json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    objects = data.get('Objects', []) + data.get('DeleteMarkers', [])
    if objects:
        print(json.dumps({'Objects': objects, 'Quiet': True}))
except Exception:
    pass
" 2>/dev/null || echo "")
            
            if [ -n "$delete_payload" ]; then
                echo "$delete_payload" | aws s3api delete-objects --bucket "$bucket" --delete file:///dev/stdin --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1 || true
            fi
        fi
        
        # Delete bucket
        delete_resource "S3 bucket" "$bucket" \
            "aws s3 rb s3://'$bucket' --force --profile '$AWS_PROFILE'"
    done
    
    end_step_timer "S3 Buckets"
    echo ""
}

# ============================================================================
# Step 4: Delete CloudFront Distributions
# ============================================================================
delete_cloudfront_resources() {
    start_step_timer "CloudFront Distributions"
    log_step "Substep 4: Deleting CloudFront Distributions"
    
    # List all CloudFront distributions
    local dist_ids
    dist_ids=$(aws cloudfront list-distributions --profile "$AWS_PROFILE" --query "DistributionList.Items[?contains(Comment, '${PROJECT_NAME}-${ENVIRONMENT}')].Id" --output text 2>/dev/null || echo "")
    
    if [ -z "$dist_ids" ]; then
        log_info "No CloudFront distributions found for project"
        echo ""
        return 0
    fi
    
    for dist_id in $dist_ids; do
        # Disable distribution first (required before deletion)
        log_info "Disabling CloudFront distribution: $dist_id"
        if [ "$DRY_RUN" = "false" ]; then
            local etag
            etag=$(aws cloudfront get-distribution-config --id "$dist_id" --profile "$AWS_PROFILE" --query 'ETag' --output text 2>/dev/null || echo "")
            if [ -n "$etag" ]; then
                local config
                config=$(aws cloudfront get-distribution-config --id "$dist_id" --profile "$AWS_PROFILE" --output json 2>/dev/null || echo "{}")
                if [ "$config" != "{}" ]; then
                    # Disable the distribution
                    echo "$config" | jq '.DistributionConfig.Enabled = false' | \
                        aws cloudfront update-distribution --id "$dist_id" --if-match "$etag" --distribution-config file:///dev/stdin --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
                    
                    # Wait for distribution to be disabled (can take 15+ minutes)
                    log_info "  Waiting for distribution to be disabled (this may take 15+ minutes)..."
                    local wait_attempt=0
                    local max_wait=180  # 30 minutes
                    while [ $wait_attempt -lt $max_wait ]; do
                        local status
                        status=$(aws cloudfront get-distribution --id "$dist_id" --profile "$AWS_PROFILE" --query 'Distribution.Status' --output text 2>/dev/null || echo "Deployed")
                        if [ "$status" = "Deployed" ]; then
                            break
                        fi
                        sleep 10
                        wait_attempt=$((wait_attempt + 1))
                        if [ $((wait_attempt % 6)) -eq 0 ]; then
                            log_info "  Still waiting... ($((wait_attempt * 10 / 60)) minutes elapsed)"
                        fi
                    done
                fi
            fi
        fi
        
        # Delete distribution
        if [ "$DRY_RUN" = "false" ]; then
            # Check if distribution is still deleting
            local dist_status
            dist_status=$(aws cloudfront get-distribution --id "$dist_id" --profile "$AWS_PROFILE" --query 'Distribution.Status' --output text 2>/dev/null || echo "deleted")
            if [ "$dist_status" = "Deployed" ] || [ "$dist_status" = "InProgress" ]; then
                track_pending "CloudFront distribution" "$dist_id" "Still deleting (status: $dist_status)"
                log_warning "  ⚠ CloudFront distribution $dist_id is still being deleted (status: $dist_status)"
                log_warning "     This may take 15+ minutes. Check status manually."
            else
                delete_resource "CloudFront distribution" "$dist_id" \
                    "aws cloudfront delete-distribution --id '$dist_id' --if-match \$(aws cloudfront get-distribution --id '$dist_id' --profile '$AWS_PROFILE' --query 'ETag' --output text) --profile '$AWS_PROFILE'"
            fi
        else
            delete_resource "CloudFront distribution" "$dist_id" \
                "aws cloudfront delete-distribution --id '$dist_id' --if-match \$(aws cloudfront get-distribution --id '$dist_id' --profile '$AWS_PROFILE' --query 'ETag' --output text) --profile '$AWS_PROFILE'"
        fi
    done
    
    end_step_timer "CloudFront Distributions"
    echo ""
}

# ============================================================================
# Step 5: Delete Load Balancers
# ============================================================================
delete_load_balancer_resources() {
    start_step_timer "Load Balancers"
    log_step "Substep 5: Deleting Load Balancers"
    
    local alb_name="${PROJECT_NAME}-${ENVIRONMENT}-alb"
    
    # Find ALB by name
    local alb_arn
    alb_arn=$(aws elbv2 describe-load-balancers --profile "$AWS_PROFILE" --region "$AWS_REGION" --query "LoadBalancers[?contains(LoadBalancerName, '$alb_name')].LoadBalancerArn" --output text 2>/dev/null || echo "")
    
    if [ -z "$alb_arn" ]; then
        log_info "ALB not found: $alb_name"
        echo ""
        return 0
    fi
    
    # Delete ALB
    delete_resource "ALB" "$alb_name" \
        "aws elbv2 delete-load-balancer --load-balancer-arn '$alb_arn' --profile '$AWS_PROFILE' --region '$AWS_REGION'"
    
    end_step_timer "Load Balancers"
    echo ""
}

# ============================================================================
# Step 6: Delete Aurora Resources
# ============================================================================
delete_aurora_resources() {
    start_step_timer "Aurora Resources"
    log_step "Substep 6: Deleting Aurora Resources"
    
    local cluster_name="${PROJECT_NAME}-${ENVIRONMENT}-aurora-cluster"
    
    # Check if cluster exists
    if ! aws rds describe-db-clusters --db-cluster-identifier "$cluster_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
        log_info "Aurora cluster not found: $cluster_name"
        echo ""
        return 0
    fi
    
    log_warning "Aurora deletion can take 10-20+ minutes (this is normal AWS behavior)"
    if [ "$DRY_RUN" = "false" ] && [ "$SKIP_CONFIRMATION" = "false" ]; then
        read -p "Continue with Aurora deletion? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "Skipping Aurora deletion"
            echo ""
            return 0
        fi
    fi
    
    # Delete cluster (instances will be deleted automatically)
    if [ "$DRY_RUN" = "false" ]; then
        log_info "Initiating Aurora cluster deletion: $cluster_name"
        if aws rds delete-db-cluster --db-cluster-identifier "$cluster_name" --skip-final-snapshot --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
            log_success "  ✓ Aurora cluster deletion initiated: $cluster_name"
            SUCCESSFUL_DELETIONS+=("Aurora cluster:$cluster_name (deletion initiated)")
            # Check if cluster is still deleting
            sleep 5
            local cluster_status
            cluster_status=$(aws rds describe-db-clusters --db-cluster-identifier "$cluster_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'DBClusters[0].Status' --output text 2>/dev/null || echo "deleted")
            if [ "$cluster_status" = "deleting" ] || [ "$cluster_status" != "deleted" ]; then
                track_pending "Aurora cluster" "$cluster_name" "Still deleting (status: $cluster_status, takes 10-20+ minutes)"
                log_warning "  ⚠ Aurora cluster is still deleting (status: $cluster_status)"
                log_warning "     This will take 10-20+ minutes. Check status manually."
            fi
        else
            log_warning "  ⚠ Failed to delete Aurora cluster: $cluster_name"
            FAILED_DELETIONS+=("Aurora cluster:$cluster_name")
        fi
    else
        log_info "[DRY-RUN] Would delete Aurora cluster: $cluster_name"
        SUCCESSFUL_DELETIONS+=("Aurora cluster:$cluster_name (dry-run)")
    fi
    
    end_step_timer "Aurora Resources"
    echo ""
}

# ============================================================================
# Step 7: Delete VPC Resources (in correct order)
# ============================================================================
delete_vpc_resources() {
    start_step_timer "VPC Resources"
    log_step "Substep 7: Deleting VPC Resources"
    
    local vpc_id
    vpc_id=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT_NAME}-${ENVIRONMENT}-vpc" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "")
    
    if [ -z "$vpc_id" ] || [ "$vpc_id" = "None" ]; then
        log_info "VPC not found for project"
        echo ""
        return 0
    fi
    
    log_info "Found VPC: $vpc_id"
    
    # Delete in correct order:
    # 1. NAT Gateways (and collect their Elastic IPs for later release)
    local nat_gateways
    nat_gateways=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'NatGateways[?State==`available`].NatGatewayId' --output text 2>/dev/null || echo "")
    
    local nat_eip_allocation_ids=""
    if [ -n "$nat_gateways" ]; then
        for nat_id in $nat_gateways; do
            log_info "Deleting NAT Gateway: $nat_id"
            
            # Get the Elastic IP allocation ID for this NAT gateway
            local eip_allocation
            eip_allocation=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$nat_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'NatGateways[0].NatGatewayAddresses[0].AllocationId' --output text 2>/dev/null || echo "")
            if [ -n "$eip_allocation" ] && [ "$eip_allocation" != "None" ]; then
                nat_eip_allocation_ids="$nat_eip_allocation_ids $eip_allocation"
            fi
            
            if [ "$DRY_RUN" = "false" ]; then
                aws ec2 delete-nat-gateway --nat-gateway-id "$nat_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1 || true
                log_info "  Waiting for NAT Gateway to be deleted (this releases the Elastic IP)..."
                # Wait for NAT gateway to be fully deleted (can take 1-2 minutes)
                local wait_attempt=0
                local max_wait=24  # 4 minutes max
                while [ $wait_attempt -lt $max_wait ]; do
                    local nat_status
                    nat_status=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$nat_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'NatGateways[0].State' --output text 2>/dev/null || echo "deleted")
                    if [ "$nat_status" = "deleted" ] || [ "$nat_status" = "None" ]; then
                        break
                    fi
                    sleep 10
                    wait_attempt=$((wait_attempt + 1))
                done
            else
                log_info "  [DRY-RUN] Would wait for NAT Gateway deletion (releases Elastic IP: $eip_allocation)"
            fi
        done
    fi
    
    # 2. Internet Gateways (detach first)
    local igws
    igws=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null || echo "")
    
    if [ -n "$igws" ]; then
        for igw_id in $igws; do
            log_info "Detaching and deleting Internet Gateway: $igw_id"
            if [ "$DRY_RUN" = "false" ]; then
                aws ec2 detach-internet-gateway --internet-gateway-id "$igw_id" --vpc-id "$vpc_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1 || true
                aws ec2 delete-internet-gateway --internet-gateway-id "$igw_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1 || true
            fi
        done
    fi
    
    # 3. Security Groups (except default)
    local security_groups
    security_groups=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || echo "")
    
    if [ -n "$security_groups" ]; then
        for sg_id in $security_groups; do
            delete_resource "Security Group" "$sg_id" \
                "aws ec2 delete-security-group --group-id '$sg_id' --profile '$AWS_PROFILE' --region '$AWS_REGION'" || true
        done
    fi
    
    # 4. Subnets
    local subnets
    subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'Subnets[].SubnetId' --output text 2>/dev/null || echo "")
    
    if [ -n "$subnets" ]; then
        for subnet_id in $subnets; do
            delete_resource "Subnet" "$subnet_id" \
                "aws ec2 delete-subnet --subnet-id '$subnet_id' --profile '$AWS_PROFILE' --region '$AWS_REGION'" || true
        done
    fi
    
    # 5. Elastic IPs (from NAT gateways and any other unassociated EIPs)
    # First, release EIPs that were associated with NAT gateways (now deleted)
    if [ -n "$nat_eip_allocation_ids" ]; then
        for eip_id in $nat_eip_allocation_ids; do
            eip_id=$(echo "$eip_id" | xargs)  # Trim whitespace
            if [ -n "$eip_id" ]; then
                delete_resource "Elastic IP (from NAT Gateway)" "$eip_id" \
                    "aws ec2 release-address --allocation-id '$eip_id' --profile '$AWS_PROFILE' --region '$AWS_REGION'"
            fi
        done
    fi
    
    # Also check for any other unassociated Elastic IPs
    local unassociated_eips
    unassociated_eips=$(aws ec2 describe-addresses --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'Addresses[?AssociationId==null].AllocationId' --output text 2>/dev/null || echo "")
    
    if [ -n "$unassociated_eips" ]; then
        for eip_id in $unassociated_eips; do
            delete_resource "Elastic IP (unassociated)" "$eip_id" \
                "aws ec2 release-address --allocation-id '$eip_id' --profile '$AWS_PROFILE' --region '$AWS_REGION'"
        done
    fi
    
    # 6. VPC (last)
    delete_resource "VPC" "$vpc_id" \
        "aws ec2 delete-vpc --vpc-id '$vpc_id' --profile '$AWS_PROFILE' --region '$AWS_REGION'" || true
    
    end_step_timer "VPC Resources"
    echo ""
}

# ============================================================================
# Summary Report Function
# ============================================================================
print_summary() {
    local total_end_time=$(date +%s)
    local total_duration=$((total_end_time - TOTAL_START_TIME))
    
    echo ""
    log_step "═══════════════════════════════════════════════════════════════"
    log_step "Deletion Summary Report"
    log_step "═══════════════════════════════════════════════════════════════"
    echo ""
    
    # Successes
    local success_count=${#SUCCESSFUL_DELETIONS[@]}
    if [ $success_count -gt 0 ]; then
        log_success "✓ Successful Deletions: $success_count"
        for resource in "${SUCCESSFUL_DELETIONS[@]}"; do
            log_info "  - $resource"
        done
        echo ""
    fi
    
    # Failures
    local failure_count=${#FAILED_DELETIONS[@]}
    if [ $failure_count -gt 0 ]; then
        log_warning "⚠ Failed Deletions: $failure_count"
        for resource in "${FAILED_DELETIONS[@]}"; do
            log_warning "  - $resource"
        done
        echo ""
    fi
    
    # Pending
    local pending_count=${#PENDING_DELETIONS[@]}
    if [ $pending_count -gt 0 ]; then
        log_info "⏳ Pending Deletions (still in progress): $pending_count"
        for pending in "${PENDING_DELETIONS[@]}"; do
            local resource_key="${pending%%|*}"
            local reason="${pending#*|}"
            log_info "  - $resource_key"
            log_info "    Reason: $reason"
        done
        echo ""
    fi
    
    # Step timings
    log_info "Step Timings:"
    if [ $STEP_DURATIONS_ECS -gt 0 ]; then
        log_info "  - ECS Resources: $(format_duration $STEP_DURATIONS_ECS)"
    fi
    if [ $STEP_DURATIONS_ECR -gt 0 ]; then
        log_info "  - ECR Repositories: $(format_duration $STEP_DURATIONS_ECR)"
    fi
    if [ $STEP_DURATIONS_S3 -gt 0 ]; then
        log_info "  - S3 Buckets: $(format_duration $STEP_DURATIONS_S3)"
    fi
    if [ $STEP_DURATIONS_CF -gt 0 ]; then
        log_info "  - CloudFront Distributions: $(format_duration $STEP_DURATIONS_CF)"
    fi
    if [ $STEP_DURATIONS_ALB -gt 0 ]; then
        log_info "  - Load Balancers: $(format_duration $STEP_DURATIONS_ALB)"
    fi
    if [ $STEP_DURATIONS_AURORA -gt 0 ]; then
        log_info "  - Aurora Resources: $(format_duration $STEP_DURATIONS_AURORA)"
    fi
    if [ $STEP_DURATIONS_VPC -gt 0 ]; then
        log_info "  - VPC Resources: $(format_duration $STEP_DURATIONS_VPC)"
    fi
    echo ""
    
    # Total time
    local total_formatted=$(format_duration $total_duration)
    log_info "Total Execution Time: $total_formatted"
    echo ""
    
    # Resources preserved
    log_info "Resources Preserved:"
    log_info "  - Secrets Manager secrets (5 secrets)"
    log_info "  - Terraform state bucket (fru-terraform-state-${AWS_ACCOUNT_ID})"
    echo ""
    
    # Next steps
    if [ $pending_count -gt 0 ]; then
        log_warning "⚠ Some resources are still deleting (Aurora, CloudFront may take 10-20+ minutes)"
        log_info "   Wait for deletions to complete before running 'run.sh deploy --container-type ecs dev'"
        log_info "   Or run immediately and let Terraform refresh handle state sync"
    else
        log_info "You can now run 'run.sh deploy --container-type ecs dev' to recreate all resources."
    fi
    echo ""
}

# ============================================================================
# Main execution
# ============================================================================
main() {
    log_step "Starting deletion of recreatable AWS resources"
    echo ""
    
    delete_ecs_resources
    delete_ecr_resources
    delete_s3_resources
    delete_cloudfront_resources
    delete_load_balancer_resources
    delete_aurora_resources
    delete_vpc_resources
    
    # Print comprehensive summary
    print_summary
}

main "$@"

