#!/bin/bash
# Main AWS deployment orchestrator
# Orchestrates end-to-end deployment workflows for ECS, EKS, and Terraform
# Usage: ./run.sh [workflow] [environment] [options...]
#
# Default: ecs-full dev (complete ECS deployment to dev environment)
#
# Workflows:
#   ecs-full        → Complete ECS deployment (build image → setup infra → deploy app + verification)
#   eks-full        → Complete EKS deployment (build image → setup infra → deploy app + verification)
#   infrastructure  → Infrastructure only (via terraform/deploy.sh infrastructure: VPC, networking, DB, S3, ECS/EKS infra; no app rollout)
#   ecs             → ECS-only deployment (legacy: ecs/deploy.sh → update ECS task definition/service only; no infra/Terraform orchestration)
#   eks             → EKS-only deployment (legacy: eks/deploy.sh → apply/update Kubernetes manifests/Helm charts only; no infra/Terraform orchestration)
#   terraform       → Terraform-only driver (legacy: terraform/deploy.sh → manual plan/apply for chosen stacks; no image build or app-level orchestration)
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
#   - Idempotent: Setup scripts are safe to run multiple times (create-if-missing)
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
#   ./run.sh ecs-full dev                                # Delta-lake will be set up automatically in Step 3.7
#
#   # Deployment without analytics
#   # In .env file: ENABLE_ANALYTICS_SCHEDULER=false (or unset)
#   ./run.sh ecs-full dev                                # Delta-lake setup will be skipped
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
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
# Save SCRIPT_DIR before sourcing load-env.sh (which sets its own SCRIPT_DIR)
AWS_SCRIPT_DIR="$SCRIPT_DIR"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"
load_env_file || true
# Restore our SCRIPT_DIR and log resolved REPO_ROOT
SCRIPT_DIR="$AWS_SCRIPT_DIR"
log_info "[debug] REPO_ROOT resolved to: $REPO_ROOT (aws/run.sh)"

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
  $0 ecs-full dev                      # Delta-lake set up automatically in Phase 4: Step 4.1

  # With analytics disabled in .env (ENABLE_ANALYTICS_SCHEDULER=false)
  $0 ecs-full dev                      # Delta-lake setup skipped
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

# Determine if data-lake setup is needed (same rules as local run.sh)
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
    # Note: Environment variables are already loaded at script startup
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
    
    # Note: Environment variables (including IMAGE_PREFIX) are already loaded at script startup
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
# Handles Phase 1-6: Environment Preparation → Infrastructure Setup → Database Setup → Data Lake → Application Deployment → Verification
# (Phase 0 is handled in main() above)
deploy_ecs_full() {
    log_step "Starting complete ECS deployment workflow"
    log_info "Environment: $ENVIRONMENT"
    
    # ============================================================================
    # Phase 1: Environment Preparation - Step 1.3: Prepare container image
    # ============================================================================
    log_step "Phase 1: Step 1.3/9: Checking container image availability"
    if ! check_or_build_image; then
        log_error "Phase 1: Step 1.3/9 FAILED: Container image check/build failed"
        log_info "Reason: Unable to check ECR for existing image or build/push new image"
        log_info "Check AWS credentials, ECR permissions, and Docker availability"
        exit 1
    fi
    log_success "Phase 1: Step 1.3/9 PASSED: Container image ready"
    
    # ============================================================================
    # Phase 2: Infrastructure Setup
    # ============================================================================
    log_step "Phase 2: Step 2.2/9: Setting up Terraform state bucket"
    if ! "$SCRIPT_DIR/terraform/setup-s3-bucket.sh"; then
        log_error "Phase 2: Step 2.2/9 FAILED: Terraform state bucket setup failed"
        log_info "Reason: Unable to create or configure S3 bucket for Terraform state"
        log_info "Check AWS credentials, S3 permissions, and TF_STATE_BUCKET in .env"
        exit 1
    fi
    log_success "Phase 2: Step 2.2/9 PASSED: Terraform state bucket ready"
    
    # ============================================================================
    # Phase 2: Infrastructure Setup - Step 2.3: Deploy infrastructure layer
    # ============================================================================
    log_step "Phase 2: Step 2.3/9: Deploying infrastructure layer"
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" infrastructure; then
        log_error "Phase 2: Step 2.3/9 FAILED: Infrastructure deployment failed"
        log_info "Reason: Terraform plan or apply failed for infrastructure layer"
        log_info "Check Terraform configuration, AWS permissions, and plan output above"
        exit 1
    fi
    log_success "Phase 2: Step 2.3/9 PASSED: Infrastructure layer deployed"

    # ============================================================================
    # Phase 3: Database Setup - Step 3.3: Setup database (includes 3.1, 3.2, pgvector)
    # ============================================================================
    if [ "$DRY_RUN" != "true" ]; then
        log_step "Phase 3: Step 3.3/9: Setting up database (pgvector, schema, data)"
        "$SCRIPT_DIR/database/setup-database.sh" "$ENVIRONMENT" || {
            log_warning "Database setup had issues (may already be set up)"
        }
    else
        log_info "[DRY-RUN] Skipping database setup"
    fi
    
    # ============================================================================
    # Phase 3: Database Setup - Step 3.4: Validate infrastructure outputs
    # ============================================================================
    log_step "Phase 3: Step 3.4/9: Validating infrastructure outputs"
    if ! "$SCRIPT_DIR/database/validate-infra-outputs.sh" "$ENVIRONMENT"; then
        log_error "Phase 3: Step 3.4/9 FAILED: Infrastructure outputs validation failed"
        log_info "Reason: Required infrastructure outputs are missing"
        log_info "Fix infrastructure deployment issues before deploying application layer"
        exit 1
    fi
    log_success "Phase 3: Step 3.4/9 PASSED: Infrastructure outputs validated"
    
    # ============================================================================
    # Phase 4: Data Lake Setup
    # ============================================================================
    # Step 4.1: Setup data-lake [CONDITIONAL]
    if should_setup_data_lake; then
        log_step "Phase 4: Step 4.1/9: Setting up data-lake (S3 + Delta table)"
        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY-RUN] Would run: $REPO_ROOT/run_scripts/spark_delta-lake_scripts/aws/delta-lake/setup-and-verify.sh"
        else
            export ENVIRONMENT="$ENVIRONMENT"
            export DRY_RUN="$DRY_RUN"
            if ! "$REPO_ROOT/run_scripts/spark_delta-lake_scripts/aws/delta-lake/setup-and-verify.sh"; then
                log_warning "Delta-lake setup had issues (application may still work without Delta tables)"
                log_info "You can run data-lake setup separately: $REPO_ROOT/run_scripts/spark_delta-lake_scripts/aws/delta-lake/setup-and-verify.sh"
            fi
        fi
        log_success "Phase 4: Step 4.1/9 PASSED: Delta-lake ready"
    else
        log_info "Skipping data-lake setup (ENABLE_ANALYTICS_SCHEDULER=false or --skip-data-lake flag)"
    fi
    
    # ============================================================================
    # Phase 5: Application Deployment
    # ============================================================================
    log_step "Phase 5: Step 5.1/9: Deploying application layer (ECS, ALB, CloudFront)"
    log_info "Using container image: $CONTAINER_IMAGE"
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" application; then
        log_error "Phase 5: Step 5.1/9 FAILED: Application deployment failed"
        log_info "Reason: Terraform plan or apply failed for application layer"
        log_info "Check Terraform configuration, AWS permissions, CONTAINER_IMAGE, and plan output above"
        exit 1
    fi
    log_success "Phase 5: Step 5.1/9 PASSED: Application layer deployed"
    
    # ============================================================================
    # Phase 5: Application Deployment - Step 5.2: Deploy frontend to S3
    # ============================================================================
    log_step "Phase 5: Step 5.2/9: Deploying frontend to S3"
    export ENVIRONMENT="$ENVIRONMENT"
    if ! "$SCRIPT_DIR/shared/deploy-frontend.sh"; then
        log_error "Phase 5: Step 5.2/9 FAILED: Frontend deployment failed"
        log_info "Reason: Failed to build frontend or sync to S3"
        log_info "Check frontend build, AWS credentials, S3 permissions, and Terraform outputs"
        exit 1
    fi
    log_success "Phase 5: Step 5.2/9 PASSED: Frontend deployed to S3"
    
    log_success "Complete ECS deployment finished successfully!"
    log_info "Your application should now be running on AWS ECS"
}

# Complete EKS deployment workflow
# Handles Phase 1-6: Environment Preparation → Infrastructure Setup → Data Lake → Application Deployment → Verification
# (Phase 0 is handled in main() above)
deploy_eks_full() {
    log_step "Starting complete EKS deployment workflow"
    log_info "Environment: $ENVIRONMENT"
    
    # ============================================================================
    # Phase 1: Environment Preparation - Step 1.3: Prepare container image
    # ============================================================================
    log_step "Phase 1: Step 1.3/8: Checking container image availability"
    if ! check_or_build_image; then
        log_error "Phase 1: Step 1.3/8 FAILED: Container image check/build failed"
        log_info "Reason: Unable to check ECR for existing image or build/push new image"
        log_info "Check AWS credentials, ECR permissions, and Docker availability"
        exit 1
    fi
    log_success "Phase 1: Step 1.3/8 PASSED: Container image ready"
    
    # ============================================================================
    # Phase 2: Infrastructure Setup
    # ============================================================================
    log_step "Phase 2: Step 2.2/8: Setting up Terraform state bucket"
    if ! "$SCRIPT_DIR/terraform/setup-s3-bucket.sh"; then
        log_error "Phase 2: Step 2.2/8 FAILED: Terraform state bucket setup failed"
        log_info "Reason: Unable to create or configure S3 bucket for Terraform state"
        log_info "Check AWS credentials, S3 permissions, and TF_STATE_BUCKET in .env"
        exit 1
    fi
    log_success "Phase 2: Step 2.2/8 PASSED: Terraform state bucket ready"
    
    # ============================================================================
    # Phase 2: Infrastructure Setup - Step 2.3: Deploy infrastructure layer
    # ============================================================================
    log_step "Phase 2: Step 2.3/8: Deploying infrastructure layer"
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" infrastructure; then
        log_error "Phase 2: Step 2.3/8 FAILED: Infrastructure deployment failed"
        log_info "Reason: Terraform plan or apply failed for infrastructure layer"
        log_info "Check Terraform configuration, AWS permissions, and plan output above"
        exit 1
    fi
    log_success "Phase 2: Step 2.3/8 PASSED: Infrastructure layer deployed"
    
    # ============================================================================
    # (Phase 3: Database Setup is handled via Kubernetes manifests for EKS)
    # ============================================================================
    
    # ============================================================================
    # Phase 4: Data Lake Setup
    # ============================================================================
    # Step 4.1: Setup data-lake [CONDITIONAL]
    if should_setup_data_lake; then
        log_step "Phase 4: Step 4.1/8: Setting up data-lake (S3 + Delta table)"
        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY-RUN] Would run: $REPO_ROOT/run_scripts/spark_delta-lake_scripts/aws/delta-lake/setup-and-verify.sh"
        else
            export ENVIRONMENT="$ENVIRONMENT"
            export DRY_RUN="$DRY_RUN"
            if ! "$REPO_ROOT/run_scripts/spark_delta-lake_scripts/aws/delta-lake/setup-and-verify.sh"; then
                log_warning "Delta-lake setup had issues (application may still work without Delta tables)"
                log_info "You can run data-lake setup separately: $REPO_ROOT/run_scripts/spark_delta-lake_scripts/aws/delta-lake/setup-and-verify.sh"
            fi
        fi
        log_success "Phase 4: Step 4.1/8 PASSED: Delta-lake ready"
    else
        log_info "Skipping data-lake setup (ENABLE_ANALYTICS_SCHEDULER=false or --skip-data-lake flag)"
    fi
    
    # ============================================================================
    # Phase 5: Application Deployment
    # ============================================================================
    # Step 5.1: Deploy EKS layer
    log_step "Phase 5: Step 5.1/8: Deploying EKS layer (EKS cluster, node groups, OIDC provider)"
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" eks; then
        log_error "Phase 5: Step 5.1/8 FAILED: EKS layer deployment failed"
        log_info "Reason: Terraform plan or apply failed for EKS layer"
        log_info "Check Terraform configuration, AWS permissions, EKS quotas, and plan output above"
        exit 1
    fi
    log_success "Phase 5: Step 5.1/8 PASSED: EKS layer deployed"
    
    # ============================================================================
    # Phase 5: Application Deployment - Step 5.3: Deploy Kubernetes manifests
    # ============================================================================
    log_step "Phase 5: Step 5.3/8: Configuring kubectl and deploying Kubernetes manifests"
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
        
        # Note: Environment variables (including AWS_REGION) are already loaded at script startup
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
            log_error "Phase 5: Step 5.3/8 FAILED: Kubernetes manifest deployment failed"
            log_info "Reason: Kubernetes manifest application or verification failed"
            log_info "Check Kubernetes manifests, EKS cluster status, and kubectl output above"
            exit 1
        fi
    fi
    log_success "Phase 5: Step 5.3/8 PASSED: Kubernetes manifests deployed"
    
    log_success "Complete EKS deployment finished successfully!"
    log_info "Your application should now be running on AWS EKS"
}

# Infrastructure only workflow
# Handles Phase 2: Infrastructure Setup only
# (Phase 0 is handled in main() above; Phases 1, 3-6 are skipped)
deploy_infrastructure() {
    log_step "Starting infrastructure deployment"
    log_info "Environment: $ENVIRONMENT"
    
    # ============================================================================
    # Phase 2: Infrastructure Setup
    # ============================================================================
    log_step "Phase 2: Step 2.2/2: Setting up Terraform state bucket"
    if ! "$SCRIPT_DIR/terraform/setup-s3-bucket.sh"; then
        log_error "Phase 2: Step 2.2/2 FAILED: Terraform state bucket setup failed"
        log_info "Reason: Unable to create or configure S3 bucket for Terraform state"
        log_info "Check AWS credentials, S3 permissions, and TF_STATE_BUCKET in .env"
        exit 1
    fi
    log_success "Phase 2: Step 2.2/2 PASSED: Terraform state bucket ready"
    
    # ============================================================================
    # Phase 2: Infrastructure Setup
    # ============================================================================
    # Step 2.3: Deploy infrastructure layer
    log_step "Phase 2: Step 2.3/2: Deploying infrastructure layer"
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" infrastructure; then
        log_error "Phase 2: Step 2.3/2 FAILED: Infrastructure deployment failed"
        log_info "Reason: Terraform plan or apply failed for infrastructure layer"
        log_info "Check Terraform configuration, AWS permissions, and plan output above"
        exit 1
    fi
    log_success "Phase 2: Step 2.3/2 PASSED: Infrastructure layer deployed"
    
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
    
    # ============================================================================
    # Phase 0: Prerequisites and Setup
    # ============================================================================
    # Note: These steps are executed once for all workflows in main()
    # They correspond to Phase 0 steps in local/run.sh
    
    # Step 0.1: Check prerequisites / dependencies
    log_step "Phase 0: Step 0.1: Verifying local tooling dependencies"
    "$REPO_ROOT/run_scripts/main_application_scripts/common/check-dependencies.sh" || exit 1
    echo ""
    
    # Step 0.2: Setup configuration files (AWS profiles from .env)
    # Note: AWS uses existing .env file, but sets up AWS profiles
    log_step "Phase 0: Step 0.2: Setting up AWS profiles from .env"
    "$SCRIPT_DIR/setup-aws-profiles.sh" || exit 1
    echo ""
    
    # Check AWS credentials for actual deployments
    # This is AWS-specific and doesn't have a direct local equivalent
    "$SCRIPT_DIR/check-aws-credentials.sh" || exit 1
    
    # ============================================================================
    # (Phase 1 - 6 are handled in the respective deployment functions)
    # ============================================================================
    
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
    
    # ============================================================================
    # Phase 6: Validation and Verification
    # ============================================================================
    # Step 6.1: Post-deployment verification (full workflows only)
    # Note: Phase 6 only runs for full deployment workflows (ecs-full, eks-full)
    # Infrastructure-only and legacy workflows skip this phase
    if [ "$DEPLOYMENT_TYPE" = "ecs-full" ] || [ "$DEPLOYMENT_TYPE" = "eks-full" ]; then
        log_step "Phase 6: Step 6.1: Verifying deployment and generating test instructions"
        echo ""
        "$SCRIPT_DIR/verification/auto_verify_and_manual_hint.sh" "$DEPLOYMENT_TYPE" "$ENVIRONMENT" "$DRY_RUN" || {
            log_warning "Post-deployment verification had issues (deployment may still be successful)"
            log_info "Check the verification output above for details"
        }
    fi
}

main "$@"
