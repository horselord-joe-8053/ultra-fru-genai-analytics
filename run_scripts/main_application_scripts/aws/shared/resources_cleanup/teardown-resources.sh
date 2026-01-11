#!/bin/bash
# Complete infrastructure destruction - leaves blank slate for fresh Terraform apply
# Usage: ./teardown-resources.sh [dev|prod] [--force] [--skip-confirmation] [--dry-run]
#
# This script:
# 1. Stops ECS/EKS services (to release resources)
# 2. Empties S3 buckets (before Terraform destroy)
# 3. Destroys Terraform infrastructure
# 4. Cleans up orphaned resources
#
# WARNING: This will DESTROY ALL infrastructure for the specified environment!

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"

DRY_RUN="false"
FORCE_DELETE="false"
SKIP_CONFIRMATION="false"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${1:-dev}"
PROJECT_NAME="fru"

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
        --help|-h)
            cat << EOF
Usage: $0 [dev|prod] [--force] [--skip-confirmation] [--dry-run]

Complete infrastructure destruction - leaves blank slate for fresh Terraform apply.

WARNING: This will DESTROY ALL infrastructure for the specified environment!

Options:
  <environment>         Environment name (dev, prod) - defaults to 'dev'
  --dry-run             Show what would be destroyed without actually destroying (default: false)
  --force               Skip confirmation prompts and actually destroy (default: requires confirmation)
  --skip-confirmation   Alias for --force
  --help                Show this help message

Examples:
  $0 dev --dry-run                    # Preview what would be destroyed
  $0 dev                              # Destroy with confirmation prompt
  $0 dev --force                      # Destroy without confirmation

Note: By default, this script requires confirmation before destroying.
      Use --force to skip confirmation prompts.

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
# Step 1: Stop Services
# ============================================================================
stop_services() {
    log_step "Step 1: Stopping Services"
    
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
empty_s3_buckets() {
    log_step "Step 2: Emptying S3 Buckets"
    
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
# Step 2.5: Wait for VPC Endpoints and Network Interfaces to Delete
# ============================================================================
# This step handles VPC endpoint deletion because:
# - Interface VPC endpoints create network interfaces (ENIs) in private subnets
# - Network interfaces must be fully deleted before subnets can be deleted
# - ENIs can take a few minutes to fully delete after endpoint deletion
wait_for_vpc_endpoints_deletion() {
    log_step "Step 2.5.1: Checking VPC Endpoints and Network Interfaces"
    
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
# Step 2.5: Wait for Aurora to Delete (if it exists)
# ============================================================================
# This step handles Aurora deletion BEFORE Terraform destroy because:
# - Aurora instances take 10-20+ minutes to delete
# - DB subnet groups block private subnet deletion
# - Terraform destroy will timeout if Aurora is still deleting
wait_for_aurora_deletion() {
    log_step "Step 2.5: Checking Aurora Cluster Status"
    
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
terraform_destroy() {
    log_step "Step 3: Destroying Terraform Infrastructure"
    
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
# Step 4: Clean Up Orphaned Resources
# ============================================================================
cleanup_orphaned() {
    log_step "Step 4: Cleaning Up Orphaned Resources"
    
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

