#!/bin/bash
# Complete infrastructure destruction - leaves blank slate for fresh Terraform apply
#
# SYNOPSIS:
#   ./teardown-resources.sh [ENVIRONMENT] [OPTIONS]
#
# DESCRIPTION:
#   This script completely destroys AWS infrastructure for a specified environment,
#   handling dependencies and resource deletion in the correct order to prevent
#   timeouts and ensure clean teardown. It also optionally cleans up local Docker
#   images that were built for ECR push.
#
# ARGUMENTS:
#   ENVIRONMENT          Environment name (dev, staging, prod) - defaults to 'dev'
#
# OPTIONS:
#   --force              Skip confirmation prompts and actually destroy resources
#                       (default: requires confirmation before destroying)
#
#   --skip-confirmation  Alias for --force
#
#   --dry-run            Show what would be destroyed without actually destroying
#                       (default: false, performs actual destruction)
#
#   --clean-local-only   Only clean up local Docker images (skip all AWS teardown steps)
#                       Useful for freeing disk space without affecting AWS infrastructure
#                       (default: false, performs full AWS teardown)
#
#   --help, -h           Display this help message and exit
#
# EXECUTION STEPS (in order):
#   1. Stop ECS/EKS Services
#      - Scales all services to desired count 0
#      - Stops all running tasks (including one-off tasks via run-task)
#      - Waits for all tasks to fully stop (up to 5 minutes)
#
#   2. Empty S3 Buckets
#      - Empties analytics data and frontend buckets
#      - Handles both regular and versioned objects
#      - Speeds up Terraform destroy (Terraform cannot delete non-empty buckets)
#
#   2.5.1. Wait for VPC Endpoints
#      - Waits for VPC endpoints to fully delete (up to 5 minutes)
#      - Waits for network interfaces (ENIs) in private subnets to clean up (up to 3 minutes)
#      - Prevents subnet deletion timeouts from lingering ENIs
#
#   2.5.2. Wait for Aurora Cluster
#      - Waits for Aurora cluster and instances to fully delete (up to 25 minutes)
#      - Aurora deletion can take 10-20+ minutes (normal AWS behavior)
#      - Prevents Terraform timeout on subnet deletion (subnets blocked by DB subnet group)
#
#   3. Destroy Terraform Infrastructure
#      - Destroys application layer (ECS/EKS, ALB, Frontend)
#      - Destroys infrastructure layer (VPC, Aurora, IAM, Secrets Manager)
#      - Handles dependency ordering within each layer
#
#   4. Clean Up Local Docker Images
#      - Removes images matching pattern: fru-api:*
#      - Removes images matching ECR URI pattern: *.dkr.ecr.*.amazonaws.com/fru-api:*
#      - Images built locally and pushed to ECR (no longer needed locally)
#      - Non-critical step (skipped if Docker is not running)
#
#   5. Clean Up Orphaned AWS Resources
#      - Cleans up orphaned S3 buckets (not managed by Terraform)
#      - Cleans up unused ECR images (old versions not in use)
#      - Cleans up old ECS task definitions (beyond safety threshold)
#      - Uses cleanup-orphaned-resources.sh helper script
#
# SPECIAL MODES:
#   --clean-local-only: Skips all AWS teardown steps (Steps 1-3, 5) and only
#                       executes Step 4 (local Docker image cleanup). Useful when
#                       you want to free up disk space without affecting AWS resources.
#
# EXAMPLES:
#   # Preview what would be destroyed (dry-run)
#   ./teardown-resources.sh dev --dry-run
#
#   # Destroy with confirmation prompt (default behavior)
#   ./teardown-resources.sh dev
#
#   # Destroy without confirmation (skip prompts)
#   ./teardown-resources.sh dev --force
#
#   # Only clean local Docker images (skip AWS teardown)
#   ./teardown-resources.sh dev --force --clean-local-only
#
#   # Destroy production environment (use with caution!)
#   ./teardown-resources.sh prod --force
#
# EXIT STATUS:
#   0  Success - All resources destroyed (or dry-run completed successfully)
#   1  Failure - Error during teardown or invalid arguments
#
# WARNING:
#   This script will DESTROY ALL infrastructure for the specified environment!
#   - All AWS resources (VPC, Aurora, ECS/EKS, ALB, S3, etc.) will be permanently deleted
#   - This action cannot be undone
#   - Use --dry-run to preview changes before actual destruction
#   - Use --clean-local-only to skip AWS destruction and only clean local images

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"

DRY_RUN="false"
FORCE_DELETE="false"
SKIP_CONFIRMATION="false"
CLEAN_LOCAL_ONLY="false"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${1:-dev}"
PROJECT_NAME="fru"
ECR_REPO_NAME="fru-api"

# Parse arguments (skip first arg which is environment)
shift 1 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE_DELETE="true"
            SKIP_CONFIRMATION="true"
            shift
            ;;
        --skip-confirmation)
            SKIP_CONFIRMATION="true"
            shift
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --clean-local-only)
            CLEAN_LOCAL_ONLY="true"
            shift
            ;;
        --help|-h)
            cat << EOF
Usage: $0 [dev|prod] [--force] [--skip-confirmation] [--dry-run] [--clean-local-only]

Complete infrastructure destruction - leaves blank slate for fresh Terraform apply.

This script destroys AWS infrastructure in the correct dependency order:
1. Stops ECS/EKS services and all running tasks
2. Empties S3 buckets (before Terraform destroy)
3. Waits for VPC endpoints and network interfaces to delete
4. Waits for Aurora cluster to fully delete (can take 10-20+ minutes)
5. Destroys Terraform infrastructure (VPC, Aurora, ECS/EKS, ALB, etc.)
6. Cleans up local Docker images (built locally and pushed to ECR)
7. Cleans up orphaned AWS resources (S3, ECR, ECS task definitions)

WARNING: This will DESTROY ALL infrastructure for the specified environment!

Options:
  <environment>         Environment name (dev, prod) - defaults to 'dev'
  --dry-run             Show what would be destroyed without actually destroying (default: false)
  --force               Skip confirmation prompts and actually destroy (default: requires confirmation)
  --skip-confirmation   Alias for --force
  --clean-local-only    Only clean up local Docker images (skip all AWS teardown steps)
  --help                Show this help message

Examples:
  $0 dev --dry-run                    # Preview what would be destroyed
  $0 dev                              # Destroy with confirmation prompt
  $0 dev --force                      # Destroy without confirmation
  $0 dev --force --clean-local-only   # Only clean local Docker images (skip AWS teardown)

Notes:
  - By default, this script requires confirmation before destroying and cleans AWS resources.
  - Use --force to skip confirmation prompts.
  - Use --clean-local-only to skip AWS teardown and only clean local Docker images.
  - Aurora deletion can take 10-20+ minutes (this is normal AWS behavior).
  - The script waits for dependencies (VPC endpoints, Aurora) before proceeding to prevent timeouts.

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

# Validate environment
if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|prod)$ ]]; then
    log_error "Invalid environment: $ENVIRONMENT"
    log_info "Must be: dev, staging, or prod"
    exit 1
fi

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text 2>/dev/null || echo "")
if [ -z "$ACCOUNT_ID" ]; then
    log_error "Failed to get AWS account ID. Check AWS credentials."
    exit 1
fi

log_step "Infrastructure Destruction"
log_warning "════════════════════════════════════════════════════════════════"
log_warning "WARNING: This will DESTROY ALL infrastructure for $ENVIRONMENT"
log_warning "════════════════════════════════════════════════════════════════"
log_info "Account ID: $ACCOUNT_ID"
log_info "Region: $AWS_REGION"
log_info "Profile: $AWS_PROFILE"
log_info "Environment: $ENVIRONMENT"
if [ "$DRY_RUN" = "true" ]; then
    log_info "Mode: DRY-RUN (no resources will be destroyed)"
else
    log_warning "Mode: DESTRUCTION (resources will be permanently destroyed!)"
fi
echo ""

# Confirmation (unless --force or --dry-run)
if [ "$DRY_RUN" = "false" ] && [ "$SKIP_CONFIRMATION" = "false" ]; then
    log_warning "This action cannot be undone!"
    log_warning "All infrastructure for environment '$ENVIRONMENT' will be destroyed."
    echo ""
    read -p "Type 'yes' to confirm destruction: " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Destruction cancelled by user"
        exit 0
    fi
    echo ""
fi

# ============================================================================
# Step 1: Stop ECS/EKS Services and Tasks
# ============================================================================
# This step stops all ECS/EKS services and tasks before Terraform destroy because:
# - Running tasks prevent cluster deletion
# - Service tasks must be stopped (desired count set to 0)
# - One-off tasks (e.g., Spark jobs via run-task) must be explicitly stopped
# - Security groups cannot be deleted while still referenced by running tasks
#
# Process:
# 1.1. Scale down all ECS services to desired count 0
# 1.2. Stop all running tasks (including one-off tasks, retry up to 30 times)
# 1.3. Wait for all tasks to fully stop (up to 5 minutes for RUNNING/STOPPING tasks)
stop_services() {
    log_step "Substep 1: Stopping ECS/EKS Services and Tasks"
    
    # Try to detect container system
    local cluster_name="${PROJECT_NAME}-${ENVIRONMENT}-cluster"
    local cont_sys=""
    
    # Check for ECS cluster
    if aws ecs describe-clusters --clusters "$cluster_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
        cont_sys="ecs"
        log_info "Detected ECS cluster: $cluster_name"
        
        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY-RUN] Would stop ECS services and tasks in cluster: $cluster_name"
        else
            # Step 1: Scale down all services to 0
            log_info "  Step 1.1: Scaling down ECS services to 0..."
            local services_json
            services_json=$(aws ecs list-services --cluster "$cluster_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" --output json 2>/dev/null || echo '{"serviceArns":[]}')
            local service_arns
            service_arns=$(echo "$services_json" | python3 -c "import sys, json; data=json.load(sys.stdin); print(' '.join(data.get('serviceArns', [])))" 2>/dev/null || echo "")
            
            for service_arn in $service_arns; do
                if [ -z "$service_arn" ]; then
                    continue
                fi
                local service_name
                service_name=$(echo "$service_arn" | sed 's|.*/||')
                log_info "    Scaling down service: $service_name"
                aws ecs update-service \
                    --cluster "$cluster_name" \
                    --service "$service_name" \
                    --desired-count 0 \
                    --profile "$AWS_PROFILE" \
                    --region "$AWS_REGION" >/dev/null 2>&1 || {
                    log_warning "      Failed to scale down service: $service_name (may already be stopped)"
                }
            done
            
            # Step 2: Stop all running tasks (including one-off tasks not part of services)
            log_info "  Step 1.2: Stopping all running tasks..."
            local max_attempts=30
            local attempt=0
            local running_tasks=""
            
            while [ $attempt -lt $max_attempts ]; do
                # List all running tasks in the cluster
                running_tasks=$(aws ecs list-tasks \
                    --cluster "$cluster_name" \
                    --desired-status RUNNING \
                    --profile "$AWS_PROFILE" \
                    --region "$AWS_REGION" \
                    --query 'taskArns[]' \
                    --output text 2>/dev/null || echo "")
                
                if [ -z "$running_tasks" ] || [ "$running_tasks" = "None" ]; then
                    log_info "    No running tasks found"
                    break
                fi
                
                # Stop each running task
                for task_arn in $running_tasks; do
                    if [ -z "$task_arn" ] || [ "$task_arn" = "None" ]; then
                        continue
                    fi
                    log_info "    Stopping task: $(echo "$task_arn" | sed 's|.*/||')"
                    aws ecs stop-task \
                        --cluster "$cluster_name" \
                        --task "$task_arn" \
                        --reason "Teardown: Stopping task before cluster destruction" \
                        --profile "$AWS_PROFILE" \
                        --region "$AWS_REGION" >/dev/null 2>&1 || {
                        log_warning "      Failed to stop task (may already be stopping)"
                    }
                done
                
                # Wait a bit and check again
                attempt=$((attempt + 1))
                if [ $attempt -lt $max_attempts ]; then
                    log_info "    Waiting for tasks to stop... (attempt $attempt/$max_attempts)"
                    sleep 5
                fi
            done
            
            # Step 3: Wait for all tasks to fully stop (including services scaling down)
            log_info "  Step 1.3: Waiting for all tasks to fully stop..."
            local wait_attempts=60  # Wait up to 5 minutes (60 * 5 seconds)
            local wait_attempt=0
            
            while [ $wait_attempt -lt $wait_attempts ]; do
                # Check for any running or stopping tasks
                local active_tasks
                active_tasks=$(aws ecs list-tasks \
                    --cluster "$cluster_name" \
                    --desired-status RUNNING \
                    --profile "$AWS_PROFILE" \
                    --region "$AWS_REGION" \
                    --query 'length(taskArns[])' \
                    --output text 2>/dev/null || echo "0")
                
                local stopping_tasks
                stopping_tasks=$(aws ecs list-tasks \
                    --cluster "$cluster_name" \
                    --desired-status STOPPING \
                    --profile "$AWS_PROFILE" \
                    --region "$AWS_REGION" \
                    --query 'length(taskArns[])' \
                    --output text 2>/dev/null || echo "0")
                
                local total_active=$((active_tasks + stopping_tasks))
                
                if [ "${total_active:-0}" -eq 0 ]; then
                    log_success "    All tasks have stopped"
                    break
                fi
                
                wait_attempt=$((wait_attempt + 1))
                if [ $((wait_attempt % 6)) -eq 0 ]; then
                    log_info "    Still waiting... ($total_active tasks: $active_tasks running, $stopping_tasks stopping)"
                fi
                sleep 5
            done
            
            if [ $wait_attempt -ge $wait_attempts ]; then
                log_warning "    Timeout waiting for all tasks to stop (some tasks may still be stopping)"
                log_warning "    Terraform destroy may still proceed, but may timeout if tasks are blocking"
            fi
        fi
    # Check for EKS cluster
    elif aws eks describe-cluster --name "$cluster_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
        cont_sys="eks"
        log_info "Detected EKS cluster: $cluster_name"
        log_info "  Note: EKS deployments should be scaled down manually with kubectl"
        log_info "  Or they will be cleaned up when Terraform destroys the cluster"
    else
        log_info "No container clusters found (ECS/EKS)"
    fi
    
    echo ""
}

# ============================================================================
# Step 2: Empty S3 Buckets
# ============================================================================
# This step empties S3 buckets before Terraform destroy because:
# - Terraform cannot delete non-empty S3 buckets
# - Emptying buckets first speeds up Terraform destroy
# - Handles both regular objects and versioned objects (delete markers)
#
# Buckets emptied:
# - Analytics data bucket (Delta tables, raw data)
# - Frontend bucket (static website files)
# - Note: Terraform state bucket is NOT emptied (preserved for state management)
empty_s3_buckets() {
    log_step "Substep 2: Emptying S3 Buckets"
    
    # Expected buckets (managed by Terraform - will be destroyed by Terraform, but empty first)
    local buckets_to_empty=(
        "${PROJECT_NAME}-${ENVIRONMENT}-analytics-data-${ACCOUNT_ID}"
        "${PROJECT_NAME}-${ENVIRONMENT}-frontend-${ACCOUNT_ID}"
    )
    
    # Note: We don't empty the Terraform state bucket - it will be handled separately
    
    for bucket in "${buckets_to_empty[@]}"; do
        if aws s3 ls --profile "$AWS_PROFILE" "s3://$bucket" >/dev/null 2>&1; then
            local object_count
            object_count=$(aws s3 ls "s3://$bucket" --profile "$AWS_PROFILE" --recursive 2>/dev/null | wc -l | tr -d ' ' || echo "0")
            
            if [ "$object_count" -gt 0 ]; then
                if [ "$DRY_RUN" = "true" ]; then
                    log_info "  [DRY-RUN] Would empty bucket: $bucket ($object_count objects)"
                else
                    log_info "  Emptying bucket: $bucket ($object_count objects)..."
                    # Delete all objects and versions
                    aws s3 rm "s3://$bucket" --profile "$AWS_PROFILE" --recursive 2>&1 || {
                        log_warning "    Some objects may have failed to delete"
                    }
                    # Delete versioned objects
                    aws s3api list-object-versions --bucket "$bucket" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null | \
                        python3 -c "
import sys, json
data = json.load(sys.stdin)
objects = data.get('Objects', []) + data.get('DeleteMarkers', [])
if objects:
    print(json.dumps({'Objects': objects, 'Quiet': True}))
" 2>/dev/null | \
                        aws s3api delete-objects --bucket "$bucket" --delete file:///dev/stdin --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>&1 || true
                    log_success "    ✓ Emptied: $bucket"
                fi
            else
                log_info "  Bucket already empty: $bucket"
            fi
        else
            log_info "  Bucket does not exist: $bucket"
        fi
    done
    echo ""
}

# ============================================================================
# Step 2.5.1: Wait for VPC Endpoints and Network Interfaces to Delete
# ============================================================================
# This step handles VPC endpoint deletion BEFORE Terraform destroy because:
# - Interface VPC endpoints (e.g., Bedrock endpoint) create network interfaces (ENIs) in private subnets
# - Network interfaces must be fully deleted before subnets can be deleted
# - ENIs can take 1-3 minutes to fully delete after endpoint deletion completes
# - Terraform destroy will timeout on subnet deletion if ENIs still exist
#
# This step:
# - Checks for VPC endpoints in the VPC (waits up to 5 minutes for deletion)
# - Checks for network interfaces in private subnets (waits up to 3 minutes for cleanup)
# - Prevents subnet deletion timeouts by ensuring ENIs are cleaned up first
wait_for_vpc_endpoints_deletion() {
    log_step "Substep 2.5.1: Checking VPC Endpoints and Network Interfaces"
    
    local vpc_id
    vpc_id=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=${PROJECT_NAME}-${ENVIRONMENT}-vpc" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query 'Vpcs[0].VpcId' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$vpc_id" ] || [ "$vpc_id" = "None" ]; then
        log_info "No VPC found (may have been deleted already)"
        echo ""
        return 0
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would check VPC endpoints and network interfaces in VPC: $vpc_id"
        echo ""
        return 0
    fi
    
    log_info "Checking VPC: $vpc_id"
    
    # Check for VPC endpoints
    local vpc_endpoints_json
    vpc_endpoints_json=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --output json 2>/dev/null || echo '{"VpcEndpoints":[]}')
    
    local vpc_endpoint_ids
    vpc_endpoint_ids=$(echo "$vpc_endpoints_json" | python3 -c "import sys, json; data=json.load(sys.stdin); print(' '.join([ep['VpcEndpointId'] for ep in data.get('VpcEndpoints', [])]))" 2>/dev/null || echo "")
    
    if [ -n "$vpc_endpoint_ids" ]; then
        log_info "Found VPC endpoints: $vpc_endpoint_ids"
        log_info "Waiting for VPC endpoints to fully delete (this may take a few minutes)..."
        
        local max_wait_minutes=5  # VPC endpoints usually delete in 1-3 minutes
        local wait_attempt=0
        local wait_attempts=$((max_wait_minutes * 6))  # 5 minutes = 30 * 10 seconds
        
        while [ $wait_attempt -lt $wait_attempts ]; do
            local remaining_endpoints
            remaining_endpoints=$(aws ec2 describe-vpc-endpoints \
                --filters "Name=vpc-id,Values=$vpc_id" \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --query 'length(VpcEndpoints[])' \
                --output text 2>/dev/null || echo "0")
            
            if [ "${remaining_endpoints:-0}" -eq 0 ]; then
                log_success "All VPC endpoints have been deleted"
                break
            fi
            
            wait_attempt=$((wait_attempt + 1))
            if [ $((wait_attempt % 6)) -eq 0 ]; then
                local elapsed_minutes=$((wait_attempt / 6))
                log_info "  Still waiting for VPC endpoints... (${elapsed_minutes}/${max_wait_minutes} minutes elapsed)"
                log_info "  Remaining endpoints: $remaining_endpoints"
            fi
            sleep 10
        done
    else
        log_info "No VPC endpoints found"
    fi
    
    # Check for network interfaces in private subnets that might block deletion
    # These could be from VPC endpoints, Lambda functions, ECS tasks, etc.
    log_info "Checking for network interfaces in private subnets..."
    
    local private_subnet_ids
    private_subnet_ids=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Type,Values=private" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query 'Subnets[*].SubnetId' \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$private_subnet_ids" ]; then
        local max_wait_minutes=3  # Network interfaces usually clean up quickly after endpoint deletion
        local wait_attempt=0
        local wait_attempts=$((max_wait_minutes * 6))  # 3 minutes = 18 * 10 seconds
        
        while [ $wait_attempt -lt $wait_attempts ]; do
            local eni_count=0
            for subnet_id in $private_subnet_ids; do
                local subnet_enis
                subnet_enis=$(aws ec2 describe-network-interfaces \
                    --filters "Name=subnet-id,Values=$subnet_id" \
                    --profile "$AWS_PROFILE" \
                    --region "$AWS_REGION" \
                    --query 'length(NetworkInterfaces[])' \
                    --output text 2>/dev/null || echo "0")
                eni_count=$((eni_count + subnet_enis))
            done
            
            if [ "${eni_count:-0}" -eq 0 ]; then
                log_success "All network interfaces have been cleaned up"
                break
            fi
            
            wait_attempt=$((wait_attempt + 1))
            if [ $((wait_attempt % 6)) -eq 0 ]; then
                local elapsed_minutes=$((wait_attempt / 6))
                log_info "  Still waiting for network interfaces to clean up... (${elapsed_minutes}/${max_wait_minutes} minutes elapsed)"
                log_info "  Remaining network interfaces: $eni_count"
            fi
            sleep 10
        done
        
        if [ $wait_attempt -ge $wait_attempts ] && [ "${eni_count:-0}" -gt 0 ]; then
            log_warning "Some network interfaces still exist (${eni_count} found)"
            log_warning "These may be from other services (Lambda, ECS, etc.) and might block subnet deletion"
            log_info "Terraform destroy will proceed, but may timeout if these block subnet deletion"
        fi
    fi
    
    echo ""
    return 0
}

# ============================================================================
# Step 2.5.2: Wait for Aurora to Delete (if it exists)
# ============================================================================
# This step handles Aurora deletion BEFORE Terraform destroy because:
# - Aurora instances take 10-20+ minutes to delete (normal AWS behavior)
# - DB subnet groups block private subnet deletion until Aurora is fully deleted
# - Terraform destroy will timeout on subnet deletion if Aurora is still deleting
# - This step waits up to 25 minutes for Aurora cluster and instances to fully delete
wait_for_aurora_deletion() {
    log_step "Substep 2.5.2: Checking Aurora Cluster Status"
    
    local cluster_name="${PROJECT_NAME}-${ENVIRONMENT}-aurora-cluster"
    
    # Check if Aurora cluster exists
    if ! aws rds describe-db-clusters \
        --db-cluster-identifier "$cluster_name" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" >/dev/null 2>&1; then
        log_info "No Aurora cluster found (may have been deleted already)"
        echo ""
        return 0
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would wait for Aurora cluster deletion: $cluster_name"
        echo ""
        return 0
    fi
    
    log_info "Aurora cluster found: $cluster_name"
    log_warning "Aurora deletion can take 10-20+ minutes (this is normal AWS behavior)"
    log_info "Waiting for Aurora cluster and instances to fully delete..."
    log_info "This prevents Terraform destroy from timing out on subnet deletion"
    echo ""
    
    local max_wait_minutes=25  # Wait up to 25 minutes (150 attempts * 10 seconds)
    local wait_attempt=0
    local wait_attempts=$((max_wait_minutes * 6))  # 25 minutes = 150 * 10 seconds
    
    while [ $wait_attempt -lt $wait_attempts ]; do
        # Check cluster status
        local cluster_status
        cluster_status=$(aws rds describe-db-clusters \
            --db-cluster-identifier "$cluster_name" \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --query 'DBClusters[0].Status' \
            --output text 2>/dev/null || echo "not-found")
        
        if [ "$cluster_status" = "not-found" ] || [ "$cluster_status" = "None" ] || [ -z "$cluster_status" ]; then
            log_success "Aurora cluster has been deleted"
            echo ""
            return 0
        fi
        
        # Check for any cluster instances still deleting
        local instances_json
        instances_json=$(aws rds describe-db-clusters \
            --db-cluster-identifier "$cluster_name" \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --query 'DBClusters[0].DBClusterMembers' \
            --output json 2>/dev/null || echo "[]")
        
        if [ "$instances_json" != "[]" ] && [ -n "$instances_json" ]; then
            # Get instance statuses
            local instance_ids
            instance_ids=$(echo "$instances_json" | python3 -c "import sys, json; members=json.load(sys.stdin); print(' '.join([m['DBInstanceIdentifier'] for m in members]))" 2>/dev/null || echo "")
            
            if [ -n "$instance_ids" ]; then
                local still_deleting=false
                for instance_id in $instance_ids; do
                    local instance_status
                    instance_status=$(aws rds describe-db-instances \
                        --db-instance-identifier "$instance_id" \
                        --profile "$AWS_PROFILE" \
                        --region "$AWS_REGION" \
                        --query 'DBInstances[0].DBInstanceStatus' \
                        --output text 2>/dev/null || echo "not-found")
                    
                    if [ "$instance_status" != "not-found" ] && [ "$instance_status" != "None" ] && [ -n "$instance_status" ]; then
                        still_deleting=true
                    fi
                done
                
                if [ "$still_deleting" = "true" ]; then
                    wait_attempt=$((wait_attempt + 1))
                    if [ $((wait_attempt % 6)) -eq 0 ]; then
                        local elapsed_minutes=$((wait_attempt / 6))
                        log_info "  Still waiting for Aurora deletion... (${elapsed_minutes}/${max_wait_minutes} minutes elapsed)"
                        log_info "  Cluster status: $cluster_status"
                    fi
                    sleep 10
                    continue
                fi
            fi
        fi
        
        # If we get here, cluster exists but instances are gone (or cluster is deleting)
        wait_attempt=$((wait_attempt + 1))
        if [ $((wait_attempt % 6)) -eq 0 ]; then
            local elapsed_minutes=$((wait_attempt / 6))
            log_info "  Still waiting for Aurora cluster deletion... (${elapsed_minutes}/${max_wait_minutes} minutes elapsed)"
            log_info "  Cluster status: $cluster_status"
        fi
        sleep 10
    done
    
    if [ $wait_attempt -ge $wait_attempts ]; then
        log_warning "Timeout waiting for Aurora cluster deletion (${max_wait_minutes} minutes)"
        log_warning "Aurora may still be deleting. Terraform destroy may timeout on subnet deletion."
        log_warning "You may need to wait manually or delete Aurora cluster via AWS Console."
        echo ""
        return 1
    fi
    
    echo ""
}

# ============================================================================
# Step 3: Terraform Destroy
# ============================================================================
# This step destroys all Terraform-managed infrastructure using Terragrunt.
#
# Infrastructure destroyed:
# - Application layer (ECS/EKS, ALB, Frontend) - destroyed first
# - Infrastructure layer (VPC, Aurora, IAM, Secrets Manager) - destroyed second
#
# Dependencies handled:
# - Steps 1-2 ensure services/tasks are stopped and S3 buckets are empty
# - Steps 2.5.1-2.5.2 ensure VPC endpoints and Aurora are deleted first
# - Terraform handles dependency ordering within each layer
terraform_destroy() {
    log_step "Substep 3: Destroying Terraform Infrastructure"
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would run: terraform/teardown.sh $ENVIRONMENT all"
        log_info "[DRY-RUN] This would destroy all Terraform-managed infrastructure"
    else
        log_info "Calling Terraform teardown..."
        local terraform_teardown_script="$REPO_ROOT/run_scripts/main_application_scripts/aws/terraform/teardown.sh"
        if [ -f "$terraform_teardown_script" ]; then
            if "$terraform_teardown_script" "$ENVIRONMENT" "all"; then
                log_success "Terraform infrastructure destroyed"
            else
                log_warning "Terraform teardown had issues (may have been partially destroyed)"
            fi
        else
            log_warning "Terraform teardown script not found at: $terraform_teardown_script"
            log_info "Skipping Terraform teardown (infrastructure may need manual cleanup)"
        fi
    fi
    echo ""
}

# ============================================================================
# Step 4: Clean Up Local Docker Images
# ============================================================================
# This step cleans up Docker images that were built locally and pushed to ECR.
# These images accumulate in local Docker cache after each build/push operation.
#
# Images cleaned:
# - Images matching pattern: fru-api:* (e.g., fru-api:fru-dev-20260109-abc123)
# - Images matching ECR URI pattern: *.dkr.ecr.*.amazonaws.com/fru-api:*
#
# Note: This step is non-critical - it only cleans local images and doesn't
# affect AWS resources. If Docker is not running, this step is skipped.
cleanup_local_images() {
    log_step "Substep 4: Cleaning Up Local Docker Images"
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would clean up local Docker images:"
        log_info "[DRY-RUN]   - Remove images matching pattern: ${ECR_REPO_NAME}:*"
        log_info "[DRY-RUN]   - Remove images matching ECR repository URI pattern"
        echo ""
        return 0
    fi
    
    # Ensure Docker is running
    if ! docker info >/dev/null 2>&1; then
        log_warning "Docker daemon is not running (skipping local image cleanup)"
        echo ""
        return 0
    fi
    
    log_info "Cleaning up local Docker images built for ECR push..."
    log_info "This removes images that were built locally and pushed to ECR"
    echo ""
    
    local images_found=false
    local images_removed=0
    
    # Find images matching the ECR repository name pattern (fru-api:*)
    log_info "Searching for images matching pattern: ${ECR_REPO_NAME}:*"
    local image_list
    image_list=$(docker images "${ECR_REPO_NAME}" --format "{{.ID}} {{.Repository}}:{{.Tag}}" 2>/dev/null || echo "")
    
    if [ -n "$image_list" ]; then
        images_found=true
        # Process each line (image_id image_tag) - use process substitution to avoid subshell
        while IFS=' ' read -r image_id image_tag; do
            if [ -z "$image_id" ] || [ "$image_id" = "None" ] || [ -z "$image_tag" ]; then
                continue
            fi
            
            log_info "  Removing image: $image_tag ($image_id)"
            
            if docker rmi -f "$image_id" >/dev/null 2>&1; then
                images_removed=$((images_removed + 1))
                log_success "    ✓ Image removed: $image_tag"
            else
                log_warning "    ✗ Failed to remove image: $image_tag (may be in use)"
            fi
        done <<< "$image_list"
    fi
    
    # Also check for images with ECR repository URI pattern (account.dkr.ecr.region.amazonaws.com/fru-api:*)
    # These are images that were tagged with the full ECR URI before push
    log_info "Searching for images matching ECR URI pattern (*.dkr.ecr.*.amazonaws.com/${ECR_REPO_NAME}:*)..."
    local all_images
    all_images=$(docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" 2>/dev/null || echo "")
    
    if [ -n "$all_images" ]; then
        local ecr_images
        ecr_images=$(echo "$all_images" | grep -E "\.dkr\.ecr\..*\.amazonaws\.com/${ECR_REPO_NAME}:" || echo "")
        
        if [ -n "$ecr_images" ]; then
            images_found=true
            while IFS=' ' read -r image_tag image_id; do
                if [ -z "$image_id" ] || [ "$image_id" = "None" ] || [ -z "$image_tag" ]; then
                    continue
                fi
                
                log_info "  Removing ECR-tagged image: $image_tag ($image_id)"
                
                if docker rmi -f "$image_id" >/dev/null 2>&1; then
                    images_removed=$((images_removed + 1))
                    log_success "    ✓ Image removed: $image_tag"
                else
                    log_warning "    ✗ Failed to remove image: $image_tag (may be in use)"
                fi
            done <<< "$ecr_images"
        fi
    fi
    
    if [ "$images_found" = false ]; then
        log_info "No local Docker images found matching ECR repository pattern"
        log_info "Images may have been cleaned up already or never built locally"
    else
        if [ "$images_removed" -gt 0 ]; then
            log_success "Local Docker images cleaned up ($images_removed image(s) removed)"
        else
            log_warning "No images were removed (images may be in use or already removed)"
        fi
    fi
    
    echo ""
}

# ============================================================================
# Step 5: Clean Up Orphaned AWS Resources
# ============================================================================
# This step cleans up orphaned AWS resources that Terraform might have missed
# or that were created outside of Terraform (e.g., manually or by other scripts).
#
# Resources cleaned (via cleanup-orphaned-resources.sh):
# - Orphaned S3 buckets (not managed by Terraform, empty or with old data)
# - Unused ECR images (old image versions not in use)
# - Old ECS task definitions (not in use, beyond safety threshold)
#
# This step uses the cleanup-orphaned-resources.sh helper script which provides
# safe cleanup with retention policies and protection for in-use resources.
cleanup_orphaned() {
    log_step "Substep 5: Cleaning Up Orphaned AWS Resources"
    
    # Detect container system for cleanup
    local cluster_name="${PROJECT_NAME}-${ENVIRONMENT}-cluster"
    local cont_sys=""
    
    if aws ecs describe-clusters --clusters "$cluster_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
        cont_sys="ecs"
    elif aws eks describe-cluster --name "$cluster_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
        cont_sys="eks"
    fi
    
    local cleanup_cmd="$SCRIPT_DIR/helpers/cleanup-orphaned-resources.sh --environment $ENVIRONMENT"
    if [ -n "$cont_sys" ]; then
        cleanup_cmd="$cleanup_cmd --cont-sys $cont_sys"
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        cleanup_cmd="$cleanup_cmd --dry-run"
    else
        cleanup_cmd="$cleanup_cmd --force"
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would run: $cleanup_cmd"
    else
        log_info "Running cleanup to catch any resources Terraform missed..."
        if $cleanup_cmd; then
            log_success "Orphaned resources cleaned up"
        else
            log_warning "Cleanup had issues (may have been partially cleaned)"
        fi
    fi
    echo ""
}

# ============================================================================
# Main Execution
# ============================================================================
main() {
    local failed=false
    
    # If --clean-local-only flag is set, skip all AWS steps and only clean local images
    # This mode is useful when you want to free up disk space by removing local Docker
    # images without affecting AWS infrastructure
    if [ "$CLEAN_LOCAL_ONLY" = "true" ]; then
        log_step "Local Docker Image Cleanup (AWS Steps Skipped)"
        log_info "Using --clean-local-only flag: skipping all AWS teardown steps"
        log_info "This will only clean up local Docker images built for ECR push"
        log_info "AWS resources will NOT be affected"
        echo ""
        
        if ! cleanup_local_images; then
            log_error "Local image cleanup failed"
            exit 1
        fi
        
        log_success "Local Docker image cleanup completed!"
        log_info "Only local Docker images were cleaned (AWS resources were not touched)"
        return 0
    fi
    
    # Normal AWS teardown flow
    if ! stop_services; then
        failed=true
    fi
    
    if ! empty_s3_buckets; then
        failed=true
    fi
    
    # Step 2.5.1: Wait for VPC endpoints and network interfaces to delete
    # VPC endpoints create network interfaces (ENIs) in private subnets that block deletion
    if ! wait_for_vpc_endpoints_deletion; then
        log_warning "VPC endpoints check had issues (may still be deleting)"
    fi
    
    # Step 2.5.2: Wait for Aurora deletion if it exists
    # This prevents Terraform destroy from timing out on subnet deletion
    # (Aurora deletion can take 10-20+ minutes, and subnets can't be deleted
    # until DB subnet group is deleted, which depends on Aurora cluster deletion)
    if ! wait_for_aurora_deletion; then
        log_warning "Aurora deletion check had issues (may still be deleting)"
        log_info "Terraform destroy will proceed, but may timeout on subnet deletion if Aurora is still deleting"
    fi
    
    if ! terraform_destroy; then
        failed=true
    fi
    
    if ! cleanup_orphaned; then
        failed=true
    fi
    
    # Step 4: Clean up local Docker images (images built locally and pushed to ECR)
    if ! cleanup_local_images; then
        log_warning "Local image cleanup had issues (non-critical)"
    fi
    
    echo ""
    log_step "Destruction Summary"
    log_info "════════════════════════════════════════════════════════════════"
    
    if [ "$DRY_RUN" = "true" ]; then
        log_warning "DRY-RUN MODE - No resources were actually destroyed"
        log_info ""
        log_info "Review the output above to see what would be destroyed"
        log_info ""
        log_info "To actually destroy infrastructure, run:"
        log_info "  $0 $ENVIRONMENT --force"
    else
        if [ "$failed" = "true" ]; then
            log_warning "Destruction completed with some issues"
            log_info "Review the output above for details"
        else
            log_success "Infrastructure destruction completed!"
            log_info ""
            log_info "All resources for environment '$ENVIRONMENT' have been destroyed"
            log_info "You can now run a fresh Terraform apply to recreate infrastructure"
        fi
    fi
    log_info "════════════════════════════════════════════════════════════════"
    
    if [ "$failed" = "true" ]; then
        exit 1
    fi
}

main "$@"

