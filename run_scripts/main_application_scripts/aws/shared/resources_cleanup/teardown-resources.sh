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
            log_info "[DRY-RUN] Would stop ECS services in cluster: $cluster_name"
        else
            # Get all services
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
                log_info "  Stopping ECS service: $service_name"
                aws ecs update-service \
                    --cluster "$cluster_name" \
                    --service "$service_name" \
                    --desired-count 0 \
                    --profile "$AWS_PROFILE" \
                    --region "$AWS_REGION" >/dev/null 2>&1 || {
                    log_warning "    Failed to stop service: $service_name (may already be stopped)"
                }
            done
            
            if [ -n "$service_arns" ]; then
                log_info "  Waiting for services to stop..."
                sleep 10
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

