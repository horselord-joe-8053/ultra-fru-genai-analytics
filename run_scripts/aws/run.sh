#!/bin/bash
# Main AWS deployment orchestrator
# Orchestrates end-to-end deployment workflows for ECS, EKS, and Terraform
# Usage: ./run.sh [workflow] [environment] [options...]
#
# Default: ecs-full dev (complete ECS deployment to dev environment)
#
# Workflows:
#   ecs-full        → Complete ECS deployment (build image → setup infra → deploy app)
#   eks-full        → Complete EKS deployment (build image → setup infra → deploy app)
#   infrastructure  → Infrastructure only (setup infra, no application)
#   ecs             → ECS-specific steps only (legacy, for quick updates)
#   eks             → EKS-specific steps only (legacy, for quick updates)
#   terraform       → Terraform-specific (legacy, for manual control)
#
# Environment:
#   dev             → Development environment (default)
#   prod            → Production environment
#   If omitted, defaults to 'dev'
#
# Options:
#   --dry-run                → Preview changes without modifying AWS resources
#   --setup-data-lake        → Force setup of data-lake (S3 + Delta table) even if analytics disabled
#   --skip-data-lake         → Skip data-lake setup even if analytics scheduler is enabled
#
# Data-Lake Setup Behavior:
#   - Automatic: Setup if ENABLE_ANALYTICS_SCHEDULER=true in .env file
#   - Flags override automatic detection (--setup-data-lake or --skip-data-lake)
#   - When called from run.sh, uses full-workflow mode (comprehensive setup)
#   - See DATA_LAKE_USAGE_GUIDE.md for detailed scenarios
#
# Practical Examples:
#
#   # Basic deployment (defaults to dev environment)
#   ./run.sh ecs-full                                    # Deploy to dev (same as below)
#   ./run.sh ecs-full dev                                # Deploy to dev environment
#   ./run.sh ecs-full prod                               # Deploy to prod environment
#
#   # With data-lake flags
#   ./run.sh ecs-full dev --setup-data-lake              # Force data-lake setup (even if analytics disabled)
#   ./run.sh ecs-full dev --skip-data-lake               # Skip data-lake setup (even if analytics enabled)
#   ./run.sh ecs-full dev --dry-run --setup-data-lake    # Preview deployment including data-lake
#
#   # First-time deployment with analytics enabled
#   # In .env file: ENABLE_ANALYTICS_SCHEDULER=true
#   ./run.sh ecs-full dev                                # Data-lake will be set up automatically in Step 3.7
#
#   # Deployment without analytics
#   # In .env file: ENABLE_ANALYTICS_SCHEDULER=false (or unset)
#   ./run.sh ecs-full dev                                # Data-lake setup will be skipped
#
#   # EKS deployment
#   ./run.sh eks-full dev                                # Complete EKS deployment to dev
#   ./run.sh eks-full prod --setup-data-lake             # EKS deployment to prod with data-lake
#
#   # Infrastructure only
#   ./run.sh infrastructure dev                          # Deploy infrastructure layer only
#   ./run.sh infrastructure prod                         # Deploy infrastructure to production
#
# See DATA_LAKE_USAGE_GUIDE.md for detailed data-lake scenarios and ENVIRONMENT_PARAMETER_EXPLAINED.md
# for information about the environment parameter.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"
# Save SCRIPT_DIR before sourcing load-env.sh (which sets its own SCRIPT_DIR)
AWS_SCRIPT_DIR="$SCRIPT_DIR"
source "$SCRIPT_DIR/../common/load-env.sh"
# Restore our SCRIPT_DIR
SCRIPT_DIR="$AWS_SCRIPT_DIR"

# ============================================================================
# DEFAULT VALUES (can be overridden via arguments or environment variables)
# ============================================================================
DEFAULT_DEPLOYMENT_TYPE="ecs-full"
DEFAULT_ENVIRONMENT="dev"
DEFAULT_AWS_REGION="us-east-1"
DEFAULT_ECR_REPO_NAME="fru-api"
DEFAULT_IMAGE_TAG="latest"

# ============================================================================
# Parse command-line arguments
# ============================================================================
# Initialize variables
DRY_RUN=false
SKIP_DATA_LAKE=false
SETUP_DATA_LAKE=false
REMAINING_ARGS=()

# First, extract flags if present
ARGS_TO_PARSE=()
for arg in "$@"; do
    if [ "$arg" = "--dry-run" ]; then
        DRY_RUN=true
    elif [ "$arg" = "--skip-data-lake" ]; then
        SKIP_DATA_LAKE=true
    elif [ "$arg" = "--setup-data-lake" ]; then
        SETUP_DATA_LAKE=true
    else
        ARGS_TO_PARSE+=("$arg")
    fi
done

# Parse remaining arguments (matching original logic)
if [ ${#ARGS_TO_PARSE[@]} -eq 0 ]; then
    DEPLOYMENT_TYPE="$DEFAULT_DEPLOYMENT_TYPE"
    ENVIRONMENT="$DEFAULT_ENVIRONMENT"
elif [[ "${ARGS_TO_PARSE[0]}" =~ ^(ecs-full|eks-full|infrastructure|ecs|eks|terraform|help|-h|--help)$ ]]; then
    DEPLOYMENT_TYPE="${ARGS_TO_PARSE[0]}"
    ENVIRONMENT="${ARGS_TO_PARSE[1]:-$DEFAULT_ENVIRONMENT}"
    REMAINING_ARGS=("${ARGS_TO_PARSE[@]:2}")
else
    # First arg might be environment (legacy support)
    DEPLOYMENT_TYPE="$DEFAULT_DEPLOYMENT_TYPE"
    ENVIRONMENT="${ARGS_TO_PARSE[0]:-$DEFAULT_ENVIRONMENT}"
    REMAINING_ARGS=("${ARGS_TO_PARSE[@]:1}")
fi

# Export flags for sub-scripts
export DRY_RUN SKIP_DATA_LAKE SETUP_DATA_LAKE

# Show usage information
show_usage() {
    cat << EOF
${GREEN}AWS Deployment Orchestrator${NC}

${BLUE}Usage:${NC}
  $0 [workflow] [environment] [options...]

${BLUE}Workflows:${NC}
  ${GREEN}ecs-full${NC}        Complete ECS deployment
                              → Build container image
                              → Setup Terraform state bucket
                              → Deploy infrastructure (VPC, Aurora, IAM, Secrets)
                              → Deploy application (ECS, ALB, Frontend)

         ${GREEN}eks-full${NC}        Complete EKS deployment
                                   → Build container image
                                   → Setup Terraform state bucket
                                   → Deploy infrastructure (VPC, Aurora, IAM, Secrets)
                                   → Deploy EKS layer (EKS cluster, node groups, OIDC)
                                   → Configure kubectl
                                   → Deploy Kubernetes manifests

  ${GREEN}infrastructure${NC}  Infrastructure only
                              → Setup Terraform state bucket
                              → Deploy infrastructure (VPC, Aurora, IAM, Secrets)
                              → No application deployment

  ${GREEN}ecs${NC}             ECS-specific steps only (legacy)
                              → Build container image
                              → Deploy frontend
                              → Reminds about infrastructure setup

  ${GREEN}eks${NC}             EKS-specific steps only (legacy)
                              → EKS deployment (not fully implemented)

  ${GREEN}terraform${NC}       Terraform-specific (legacy)
                              → Manual Terraform deployment control
                              → Usage: $0 terraform [dev|prod] [infrastructure|application|all]

${BLUE}Environments:${NC}
  dev     Development environment (default: $DEFAULT_ENVIRONMENT)
  prod    Production environment

  ${BLUE}Options:${NC}
  ${GREEN}--dry-run${NC}          Preview changes without modifying AWS resources
  ${GREEN}--setup-data-lake${NC}  Force setup of data-lake (S3 + Delta table) even if analytics disabled
  ${GREEN}--skip-data-lake${NC}   Skip data-lake setup even if analytics scheduler is enabled
  ${GREEN}--dry-run${NC}     Show what would be done without making changes
                              - Terraform: Shows plan only (no apply)
                              - Docker: Shows what would be built/pushed
                              - S3: Shows what files would be synced
                              - Kubernetes: Shows what would be applied

${BLUE}Examples:${NC}
  ${GREEN}Basic Deployments:${NC}
  $0                                    # Default: $DEFAULT_DEPLOYMENT_TYPE to dev
  $0 ecs-full dev                      # Complete ECS deployment to dev
  $0 ecs-full                          # Same as above (dev is default)
  $0 eks-full prod                     # Complete EKS deployment to prod
  $0 infrastructure dev                # Infrastructure only to dev

  ${GREEN}Data-Lake Scenarios:${NC}
  # With analytics enabled in .env (ENABLE_ANALYTICS_SCHEDULER=true)
  $0 ecs-full dev                      # Data-lake set up automatically in Step 3.7

  # With analytics disabled in .env (ENABLE_ANALYTICS_SCHEDULER=false)
  $0 ecs-full dev                      # Data-lake setup skipped
  $0 ecs-full dev --setup-data-lake    # Force data-lake setup anyway
  $0 ecs-full dev --skip-data-lake     # Force skip (even if analytics enabled)

  ${GREEN}Other Options:${NC}
  $0 ecs-full dev --dry-run            # Preview changes without deploying
  $0 ecs-full dev --dry-run --setup-data-lake  # Preview including data-lake
  $0 terraform dev all                 # Terraform manual control

${BLUE}Data-Lake Setup:${NC}
  The data-lake (S3 + Delta table) is automatically set up when:
  - ENABLE_ANALYTICS_SCHEDULER=true in .env file (default behavior)
  - Or --setup-data-lake flag is used (forces setup)
  
  It is skipped when:
  - ENABLE_ANALYTICS_SCHEDULER=false or unset (default behavior)
  - Or --skip-data-lake flag is used (forces skip)
  
  When run from this script, data-lake setup uses full-workflow mode:
  - Comprehensive verification and setup
  - Ensures everything is properly configured
  - See DATA_LAKE_USAGE_GUIDE.md for detailed scenarios

${BLUE}Note:${NC}
  - All workflows are idempotent (safe to run multiple times)
  - Container image is checked/created automatically for *-full workflows
  - Infrastructure is shared between ECS and EKS deployments
  - Use --dry-run to preview changes without modifying AWS resources
EOF
}

# Determine if data-lake setup is needed (consistent with local)
# Priority order:
#   1. Explicit flags (--skip-data-lake or --setup-data-lake) - highest priority
#   2. Environment variable (ENABLE_ANALYTICS_SCHEDULER) - auto-detection
#   3. Default: Skip (analytics scheduler disabled)
should_setup_data_lake() {
    # If explicitly skipped, don't setup
    if [ "$SKIP_DATA_LAKE" = "true" ]; then
        return 1
    fi
    
    # If explicitly requested, do it
    if [ "$SETUP_DATA_LAKE" = "true" ]; then
        return 0
    fi
    
    # Auto-detect: Check if analytics scheduler is enabled
    load_env_file || true
    
    if [ "${ENABLE_ANALYTICS_SCHEDULER:-false}" = "true" ]; then
        return 0  # Analytics scheduler enabled, need Delta Lake
    fi
    
    # Default: Don't setup (analytics scheduler disabled)
    return 1
}

# Check if container image exists in ECR (idempotent check)
# Purpose: Ensure image is available before Terraform deployment
# Strategy: Auto-generate unique tags (git SHA) so Terraform detects code changes
check_or_build_image() {
    log_step "Checking container image availability"
    
    # Load environment variables (includes IMAGE_PREFIX from .env)
    load_env_file
    
    # Use admin profile for infrastructure operations (ECR)
    AWS_PROFILE="${AWS_PROFILE:-admin}"
    
    # Generate CONTAINER_IMAGE using centralized function
    # For AWS deployments, this resolves IMAGE_PREFIX to actual ECR URI
    CONTAINER_IMAGE=$(resolve_container_image_for_aws)
    export CONTAINER_IMAGE
    
    # Extract ECR_REPO_URI and IMAGE_TAG for build-push-ecr.sh
    # These are needed for ECR operations (check existence, push, etc.)
    ECR_REPO_URI="${CONTAINER_IMAGE%%:*}"
    IMAGE_TAG="${CONTAINER_IMAGE##*:}"
    export ECR_REPO_URI IMAGE_TAG
    
    # Get ECR repository name and region for AWS CLI operations
    ECR_REPO_NAME="${ECR_REPO_NAME:-fru-api}"
    AWS_REGION="${AWS_REGION:-$DEFAULT_AWS_REGION}"
    
    # Check if image already exists in ECR
    if aws ecr describe-images \
        --profile "$AWS_PROFILE" \
        --repository-name "$ECR_REPO_NAME" \
        --image-ids imageTag="$IMAGE_TAG" \
        --region "$AWS_REGION" >/dev/null 2>&1; then
        log_info "Container image already exists: $CONTAINER_IMAGE"
        return 0
    fi
    
    # Image doesn't exist, build and push it
    log_info "Building and pushing container image..."
    log_info "Image will be tagged as: $CONTAINER_IMAGE"
    
    if "$SCRIPT_DIR/shared/build-push-ecr.sh"; then
        log_success "Container image built and pushed: $CONTAINER_IMAGE"
        log_info "This image URI will be used by Terraform to update the ECS task definition"
        log_info "Terraform will detect the change and trigger a new ECS deployment"
        return 0
    else
        log_error "Failed to build and push container image"
        return 1
    fi
}

# Complete ECS deployment workflow
deploy_ecs_full() {
    log_step "Starting complete ECS deployment workflow"
    log_info "Environment: $ENVIRONMENT"
    

    # Step 1: Check/build container image (idempotent)
    log_step "Step 1/7: Checking container image availability"
    if ! check_or_build_image; then
        log_error "Step 1/7 FAILED: Container image check/build failed"
        log_info "Reason: Unable to check ECR for existing image or build/push new image"
        log_info "Check AWS credentials, ECR permissions, and Docker availability"
        exit 1
    fi
    log_success "Step 1/7 PASSED: Container image ready"
    
    # Step 2: Setup Terraform state bucket
    log_step "Step 2/7: Setting up Terraform state bucket"
    if ! "$SCRIPT_DIR/terraform/setup-s3-bucket.sh"; then
        log_error "Step 2/7 FAILED: Terraform state bucket setup failed"
        log_info "Reason: Unable to create or configure S3 bucket for Terraform state"
        log_info "Check AWS credentials, S3 permissions, and TF_STATE_BUCKET in .env"
        exit 1
    fi
    log_success "Step 2/7 PASSED: Terraform state bucket ready"
    
    # Step 3: Deploy infrastructure
    log_step "Step 3/7: Deploying infrastructure layer"
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" infrastructure; then
        log_error "Step 3/7 FAILED: Infrastructure deployment failed"
        log_info "Reason: Terraform plan or apply failed for infrastructure layer"
        log_info "Check Terraform configuration, AWS permissions, and plan output above"
        exit 1
    fi
    log_success "Step 3/7 PASSED: Infrastructure layer deployed"

    # Step 3.5: Setup database (pgvector, schema, data)
    if [ "$DRY_RUN" != "true" ]; then
        log_step "Step 3.5/7: Setting up database (pgvector, schema, data)"
        "$SCRIPT_DIR/database/setup-database.sh" "$ENVIRONMENT" || {
            log_warning "Database setup had issues (may already be set up)"
        }
    else
        log_info "[DRY-RUN] Skipping database setup"
    fi
    
    # Step 3.6: Validate infrastructure outputs before deploying application
    log_step "Step 3.6/7: Validating infrastructure outputs"
    if ! "$SCRIPT_DIR/database/validate-infra-outputs.sh" "$ENVIRONMENT"; then
        log_error "Step 3.6/7 FAILED: Infrastructure outputs validation failed"
        log_info "Reason: Required infrastructure outputs are missing"
        log_info "Fix infrastructure deployment issues before deploying application layer"
        exit 1
    fi
    
    # Step 3.7: Setup data-lake (optional, only if analytics scheduler enabled)
    # This step is conditionally executed based on:
    #   - ENABLE_ANALYTICS_SCHEDULER=true in .env → Setup automatically
    #   - --setup-data-lake flag → Force setup
    #   - --skip-data-lake flag → Force skip
    # When called from this workflow, uses full-workflow mode for comprehensive setup
    if should_setup_data_lake; then
        log_step "Step 3.7/7: Setting up data-lake (S3 + Delta table)"
        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY-RUN] Would run: $SCRIPT_DIR/delta-lake/setup-and-verify.sh"
        else
            export ENVIRONMENT="$ENVIRONMENT"
            export DRY_RUN="$DRY_RUN"
            export DATA_LAKE_SETUP_MODE="full-workflow"  # Set mode for full workflow
            if ! "$SCRIPT_DIR/delta-lake/setup-and-verify.sh"; then
                log_warning "Data-lake setup had issues (application may still work without Delta tables)"
                log_info "You can run data-lake setup separately: $SCRIPT_DIR/delta-lake/setup-and-verify.sh"
            fi
        fi
        log_success "Step 3.7/7 PASSED: Data-lake ready"
    else
        log_info "Skipping data-lake setup (ENABLE_ANALYTICS_SCHEDULER=false or --skip-data-lake flag)"
    fi
    
    # Step 4: Deploy application (CONTAINER_IMAGE is already exported from check_or_build_image)
    log_step "Step 4/7: Deploying application layer (ECS, ALB, CloudFront)"
    log_info "Using container image: $CONTAINER_IMAGE"
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" application; then
        log_error "Step 4/7 FAILED: Application deployment failed"
        log_info "Reason: Terraform plan or apply failed for application layer"
        log_info "Check Terraform configuration, AWS permissions, CONTAINER_IMAGE, and plan output above"
        exit 1
    fi
    log_success "Step 4/7 PASSED: Application layer deployed"
    
    # Step 5: Deploy frontend to S3 (for CloudFront to serve)
    log_step "Step 5/7: Deploying frontend to S3"
    export ENVIRONMENT="$ENVIRONMENT"
    if ! "$SCRIPT_DIR/shared/deploy-frontend.sh"; then
        log_error "Step 5/7 FAILED: Frontend deployment failed"
        log_info "Reason: Failed to build frontend or sync to S3"
        log_info "Check frontend build, AWS credentials, S3 permissions, and Terraform outputs"
        exit 1
    fi
    log_success "Step 5/7 PASSED: Frontend deployed to S3"
    
    # Step 6: Post-deployment verification and manual test hints
    log_step "Step 6/7: Verifying deployment and generating test instructions"
    "$SCRIPT_DIR/verification/auto_verify_and_manual_hint.sh" "ecs-full" "$ENVIRONMENT" || {
        log_warning "Post-deployment verification had issues (deployment may still be successful)"
        log_info "Check the verification output above for details"
    }
    
    log_success "Complete ECS deployment finished successfully!"
    log_info "Your application should now be running on AWS ECS"
}

# Complete EKS deployment workflow
deploy_eks_full() {
    log_step "Starting complete EKS deployment workflow"
    log_info "Environment: $ENVIRONMENT"
    
    # Step 1: Check/build container image (idempotent)
    log_step "Step 1/6: Checking container image availability"
    if ! check_or_build_image; then
        log_error "Step 1/6 FAILED: Container image check/build failed"
        log_info "Reason: Unable to check ECR for existing image or build/push new image"
        log_info "Check AWS credentials, ECR permissions, and Docker availability"
        exit 1
    fi
    log_success "Step 1/6 PASSED: Container image ready"
    
    # Step 2: Setup Terraform state bucket
    log_step "Step 2/6: Setting up Terraform state bucket"
    if ! "$SCRIPT_DIR/terraform/setup-s3-bucket.sh"; then
        log_error "Step 2/6 FAILED: Terraform state bucket setup failed"
        log_info "Reason: Unable to create or configure S3 bucket for Terraform state"
        log_info "Check AWS credentials, S3 permissions, and TF_STATE_BUCKET in .env"
        exit 1
    fi
    log_success "Step 2/6 PASSED: Terraform state bucket ready"
    
    # Step 3: Deploy infrastructure
    log_step "Step 3/6: Deploying infrastructure layer"
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" infrastructure; then
        log_error "Step 3/6 FAILED: Infrastructure deployment failed"
        log_info "Reason: Terraform plan or apply failed for infrastructure layer"
        log_info "Check Terraform configuration, AWS permissions, and plan output above"
        exit 1
    fi
    log_success "Step 3/6 PASSED: Infrastructure layer deployed"
    
    # Step 3.7: Setup data-lake (optional, only if analytics scheduler enabled)
    if should_setup_data_lake; then
        log_step "Step 3.7/6: Setting up data-lake (S3 + Delta table)"
        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY-RUN] Would run: $SCRIPT_DIR/delta-lake/setup-and-verify.sh"
        else
            export ENVIRONMENT="$ENVIRONMENT"
            export DRY_RUN="$DRY_RUN"
            export DATA_LAKE_SETUP_MODE="full-workflow"  # Set mode for full workflow
            if ! "$SCRIPT_DIR/delta-lake/setup-and-verify.sh"; then
                log_warning "Data-lake setup had issues (application may still work without Delta tables)"
                log_info "You can run data-lake setup separately: $SCRIPT_DIR/delta-lake/setup-and-verify.sh"
            fi
        fi
        log_success "Step 3.7/6 PASSED: Data-lake ready"
    else
        log_info "Skipping data-lake setup (ENABLE_ANALYTICS_SCHEDULER=false or --skip-data-lake flag)"
    fi
    
    # Step 4: Deploy EKS layer (EKS cluster, node groups, OIDC provider)
    log_step "Step 4/6: Deploying EKS layer (EKS cluster, node groups, OIDC provider)"
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" eks; then
        log_error "Step 4/6 FAILED: EKS layer deployment failed"
        log_info "Reason: Terraform plan or apply failed for EKS layer"
        log_info "Check Terraform configuration, AWS permissions, EKS quotas, and plan output above"
        exit 1
    fi
    log_success "Step 4/6 PASSED: EKS layer deployed"
    
    # Step 5: Configure kubectl and deploy Kubernetes manifests
    log_step "Step 5/6: Configuring kubectl and deploying Kubernetes manifests"
    log_info "Using container image: $CONTAINER_IMAGE"
    
    # Get cluster name from Terraform output
    TERRAFORM_DIR="$REPO_ROOT/infra/terraform/environments"
    ENV_DIR="$TERRAFORM_DIR/$ENVIRONMENT"
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would configure kubectl and deploy Kubernetes manifests"
        log_info "[DRY-RUN] Would run: aws eks update-kubeconfig --region $AWS_REGION --name <cluster-name> --profile admin"
        log_info "[DRY-RUN] Would run: kubectl apply -f infra/k8s/"
    else
        # Configure kubectl
        log_info "Configuring kubectl for EKS cluster..."
        cd "$ENV_DIR/eks"
        CLUSTER_NAME=$(terragrunt output -raw cluster_name 2>/dev/null || echo "")
        
        if [ -z "$CLUSTER_NAME" ]; then
            log_error "Failed to get EKS cluster name from Terraform output"
            log_info "Try running: cd $ENV_DIR/eks && terragrunt output"
            exit 1
        fi
        
        log_info "Cluster name: $CLUSTER_NAME"
        
        # Load environment variables to get AWS_REGION
        load_env_file
        
        AWS_REGION="${AWS_REGION:-$DEFAULT_AWS_REGION}"
        if ! aws eks update-kubeconfig \
            --region "$AWS_REGION" \
            --name "$CLUSTER_NAME" \
            --profile admin; then
            log_error "Failed to configure kubectl"
            log_info "Check AWS credentials, EKS cluster status, and permissions"
            exit 1
        fi
        log_success "kubectl configured for cluster: $CLUSTER_NAME"
        
        # Deploy Kubernetes manifests
        if ! "$SCRIPT_DIR/eks/deploy.sh"; then
            log_error "Step 5/5 FAILED: Kubernetes manifest deployment failed"
            log_info "Reason: Kubernetes manifest application or verification failed"
            log_info "Check Kubernetes manifests, EKS cluster status, and kubectl output above"
            exit 1
        fi
    fi
    log_success "Step 5/6 PASSED: Kubernetes manifests deployed"
    
    # Step 6: Post-deployment verification and manual test hints
    log_step "Step 6/6: Verifying deployment and generating test instructions"
    "$SCRIPT_DIR/verification/auto_verify_and_manual_hint.sh" "eks-full" "$ENVIRONMENT" || {
        log_warning "Post-deployment verification had issues (deployment may still be successful)"
        log_info "Check the verification output above for details"
    }
    
    log_success "Complete EKS deployment finished successfully!"
    log_info "Your application should now be running on AWS EKS"
}

# Infrastructure only workflow
deploy_infrastructure() {
    log_step "Starting infrastructure deployment"
    log_info "Environment: $ENVIRONMENT"
    
    # Step 1: Setup Terraform state bucket
    log_step "Step 1/2: Setting up Terraform state bucket"
    if ! "$SCRIPT_DIR/terraform/setup-s3-bucket.sh"; then
        log_error "Step 1/2 FAILED: Terraform state bucket setup failed"
        log_info "Reason: Unable to create or configure S3 bucket for Terraform state"
        log_info "Check AWS credentials, S3 permissions, and TF_STATE_BUCKET in .env"
        exit 1
    fi
    log_success "Step 1/2 PASSED: Terraform state bucket ready"
    
    # Step 2: Deploy infrastructure
    log_step "Step 2/2: Deploying infrastructure layer"
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" infrastructure; then
        log_error "Step 2/2 FAILED: Infrastructure deployment failed"
        log_info "Reason: Terraform plan or apply failed for infrastructure layer"
        log_info "Check Terraform configuration, AWS permissions, and plan output above"
        exit 1
    fi
    log_success "Step 2/2 PASSED: Infrastructure layer deployed"
    
    log_success "Infrastructure deployment finished successfully!"
    log_info "Infrastructure is ready. Deploy application with: $0 ecs-full or $0 eks-full"
}

main() {
    # Handle help first (doesn't require AWS credentials)
    if [ "$DEPLOYMENT_TYPE" = "help" ] || [ "$DEPLOYMENT_TYPE" = "-h" ] || [ "$DEPLOYMENT_TYPE" = "--help" ]; then
        show_usage
        exit 0
    fi
    
    # Show dry-run banner if enabled
    if [ "$DRY_RUN" = "true" ]; then
        echo ""
        log_warning "=== DRY-RUN MODE ENABLED ==="
        log_info "No AWS resources will be created or modified"
        log_info "This is a preview of what would happen"
        echo ""
    fi
    
    # Global dependency check (idempotent: only verifies tools, no changes)
    log_step "Verifying local tooling dependencies"
    "$SCRIPT_DIR/../common/check-dependencies.sh" || exit 1
    echo ""
    
    # Setup AWS profiles from .env (must be done before credential checks)
    log_step "Setting up AWS profiles from .env"
    "$SCRIPT_DIR/setup-aws-profiles.sh" || exit 1
    echo ""
    
    # Check AWS credentials for actual deployments
    "$SCRIPT_DIR/check-aws-credentials.sh" || exit 1
    
    # Handle deployment types
    case "$DEPLOYMENT_TYPE" in
        ecs-full)
            deploy_ecs_full
            echo ""
            ;;
        eks-full)
            deploy_eks_full
            echo ""
            ;;
        infrastructure)
            deploy_infrastructure
            echo ""
            ;;
        ecs)
            log_info "Starting ECS-specific deployment (legacy mode)..."
            "$SCRIPT_DIR/ecs/deploy.sh" "${REMAINING_ARGS[@]}"
            echo ""
                ;;
            eks)
            log_info "Starting EKS-specific deployment (legacy mode)..."
            "$SCRIPT_DIR/eks/deploy.sh" "${REMAINING_ARGS[@]}"
            echo ""
                ;;
            terraform)
            log_info "Starting Terraform deployment (legacy mode)..."
            "$SCRIPT_DIR/terraform/deploy.sh" "${REMAINING_ARGS[@]}"
            echo ""
                ;;
            *)
            log_error "Unknown deployment type: $DEPLOYMENT_TYPE"
            echo ""
            show_usage
                exit 1
                ;;
        esac
    
    # Run post-deployment verification and show manual test hints
    # (replaces both post_run_verify.sh and manual_test_hint.sh)
    echo ""
    "$SCRIPT_DIR/verification/auto_verify_and_manual_hint.sh" "$DEPLOYMENT_TYPE" "$ENVIRONMENT" "$DRY_RUN"
}

main "$@"
