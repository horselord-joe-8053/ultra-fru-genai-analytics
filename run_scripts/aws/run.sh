#!/bin/bash
# Main AWS deployment orchestrator
# Orchestrates end-to-end deployment workflows for ECS, EKS, and Terraform
# Usage: ./run.sh [ecs-full|eks-full|infrastructure|ecs|eks|terraform] [options...]
#
# Default: ecs-full (complete ECS deployment)
#
# Workflows:
#   ecs-full        → Complete ECS deployment (build image → setup infra → deploy app)
#   eks-full        → Complete EKS deployment (build image → setup infra → deploy app)
#   infrastructure  → Infrastructure only (setup infra, no application)
#   ecs             → ECS-specific steps only (legacy, for quick updates)
#   eks             → EKS-specific steps only (legacy, for quick updates)
#   terraform       → Terraform-specific (legacy, for manual control)

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
REMAINING_ARGS=()

# First, extract --dry-run flag if present
ARGS_TO_PARSE=()
for arg in "$@"; do
    if [ "$arg" = "--dry-run" ]; then
        DRY_RUN=true
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

# Export DRY_RUN for sub-scripts
export DRY_RUN

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
  ${GREEN}--dry-run${NC}     Show what would be done without making changes
                              - Terraform: Shows plan only (no apply)
                              - Docker: Shows what would be built/pushed
                              - S3: Shows what files would be synced
                              - Kubernetes: Shows what would be applied

${BLUE}Examples:${NC}
  $0                                    # Default: $DEFAULT_DEPLOYMENT_TYPE deployment
  $0 ecs-full dev                      # Complete ECS deployment to dev
  $0 eks-full prod                     # Complete EKS deployment to prod
  $0 infrastructure dev                # Infrastructure only to dev
  $0 ecs --skip-build                  # ECS-specific (skip image build)
  $0 terraform dev all                 # Terraform manual control
  $0 ecs-full dev --dry-run            # Dry-run: show what would be deployed

${BLUE}Note:${NC}
  - All workflows are idempotent (safe to run multiple times)
  - Container image is checked/created automatically for *-full workflows
  - Infrastructure is shared between ECS and EKS deployments
  - Use --dry-run to preview changes without modifying AWS resources
EOF
}

# Check if container image exists in ECR (idempotent check)
check_or_build_image() {
    log_step "Checking container image availability"
    
    # Load environment variables
    load_env_file
    
    # Use admin profile for infrastructure operations (ECR)
    AWS_PROFILE="${AWS_PROFILE:-admin}"
    
    # Get AWS account and region
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text)
    AWS_REGION="${AWS_REGION:-$DEFAULT_AWS_REGION}"
    ECR_REPO_NAME="$DEFAULT_ECR_REPO_NAME"
    IMAGE_TAG="${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"
    ECR_REPO_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME"
    
    # Check if image exists in ECR
    if aws ecr describe-images \
        --profile "$AWS_PROFILE" \
        --repository-name "$ECR_REPO_NAME" \
        --image-ids imageTag="$IMAGE_TAG" \
        --region "$AWS_REGION" >/dev/null 2>&1; then
        log_info "Container image already exists: $ECR_REPO_URI:$IMAGE_TAG"
        export CONTAINER_IMAGE="$ECR_REPO_URI:$IMAGE_TAG"
        return 0
    fi
    
    # Image doesn't exist, build and push it
    log_info "Container image not found in ECR"
    log_info "Building and pushing container image..."
    
    if "$SCRIPT_DIR/common_ecs_eks/build-push-ecr.sh"; then
        export CONTAINER_IMAGE="$ECR_REPO_URI:$IMAGE_TAG"
        log_success "Container image built and pushed: $CONTAINER_IMAGE"
        log_info "Consider adding to .env: CONTAINER_IMAGE=$CONTAINER_IMAGE"
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
    
    # Helper: ensure pgvector extension exists
    ensure_pgvector_extension() {
        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY-RUN] Skipping pgvector extension creation"
            return 0
        fi

        local infra_dir="$REPO_ROOT/infra/terraform/environments/$ENVIRONMENT/infrastructure"
        if [ ! -d "$infra_dir" ]; then
            log_warning "Infrastructure directory not found at $infra_dir; skipping pgvector extension step"
            return 0
        fi

        log_step "Ensuring pgvector extension on database"

        # Fetch outputs from Terragrunt
        local db_password_secret_arn db_endpoint db_port db_name db_user
        db_password_secret_arn=$(cd "$infra_dir" && terragrunt output -raw db_password_secret_arn 2>/dev/null || true)
        db_endpoint=$(cd "$infra_dir" && terragrunt output -raw aurora_endpoint 2>/dev/null || true)
        db_port=$(cd "$infra_dir" && terragrunt output -raw aurora_port 2>/dev/null || echo "5432")
        db_name=$(cd "$infra_dir" && terragrunt output -raw aurora_database_name 2>/dev/null || echo "fru_db")
        db_user="${PGUSER:-fru_user}"

        if [ -z "$db_password_secret_arn" ] || [ -z "$db_endpoint" ]; then
            log_warning "Missing DB outputs (password secret or endpoint); skipping pgvector extension step"
            return 0
        fi

        DB_PASSWORD_SECRET_ARN="$db_password_secret_arn" \
        DB_ENDPOINT="$db_endpoint" \
        DB_PORT="$db_port" \
        DB_NAME="$db_name" \
        DB_USERNAME="$db_user" \
        AWS_PROFILE="${AWS_PROFILE:-admin}" \
        AWS_REGION="${AWS_REGION:-$DEFAULT_AWS_REGION}" \
        "$SCRIPT_DIR/terraform/post_create_pgvector.sh" "$ENVIRONMENT"
    }

    # Step 1: Check/build container image (idempotent)
    log_step "Step 1/4: Checking container image availability"
    if ! check_or_build_image; then
        log_error "Step 1/4 FAILED: Container image check/build failed"
        log_info "Reason: Unable to check ECR for existing image or build/push new image"
        log_info "Check AWS credentials, ECR permissions, and Docker availability"
        exit 1
    fi
    log_success "Step 1/4 PASSED: Container image ready"
    
    # Step 2: Setup Terraform state bucket
    log_step "Step 2/4: Setting up Terraform state bucket"
    if ! "$SCRIPT_DIR/terraform/setup-s3-bucket.sh"; then
        log_error "Step 2/4 FAILED: Terraform state bucket setup failed"
        log_info "Reason: Unable to create or configure S3 bucket for Terraform state"
        log_info "Check AWS credentials, S3 permissions, and TF_STATE_BUCKET in .env"
        exit 1
    fi
    log_success "Step 2/4 PASSED: Terraform state bucket ready"
    
    # Step 3: Deploy infrastructure
    log_step "Step 3/4: Deploying infrastructure layer"
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" infrastructure; then
        log_error "Step 3/4 FAILED: Infrastructure deployment failed"
        log_info "Reason: Terraform plan or apply failed for infrastructure layer"
        log_info "Check Terraform configuration, AWS permissions, and plan output above"
        exit 1
    fi
    log_success "Step 3/4 PASSED: Infrastructure layer deployed"

    # Step 3.5: Ensure pgvector extension exists (Aurora/Postgres)
    ensure_pgvector_extension
    
    # Step 4: Deploy application (CONTAINER_IMAGE is already exported from check_or_build_image)
    log_step "Step 4/4: Deploying application layer (ECS, ALB, Frontend)"
    log_info "Using container image: $CONTAINER_IMAGE"
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" application; then
        log_error "Step 4/4 FAILED: Application deployment failed"
        log_info "Reason: Terraform plan or apply failed for application layer"
        log_info "Check Terraform configuration, AWS permissions, CONTAINER_IMAGE, and plan output above"
        exit 1
    fi
    log_success "Step 4/4 PASSED: Application layer deployed"
    
    log_success "Complete ECS deployment finished successfully!"
    log_info "Your application should now be running on AWS ECS"
}

# Complete EKS deployment workflow
deploy_eks_full() {
    log_step "Starting complete EKS deployment workflow"
    log_info "Environment: $ENVIRONMENT"
    
    # Step 1: Check/build container image (idempotent)
    log_step "Step 1/5: Checking container image availability"
    if ! check_or_build_image; then
        log_error "Step 1/5 FAILED: Container image check/build failed"
        log_info "Reason: Unable to check ECR for existing image or build/push new image"
        log_info "Check AWS credentials, ECR permissions, and Docker availability"
        exit 1
    fi
    log_success "Step 1/5 PASSED: Container image ready"
    
    # Step 2: Setup Terraform state bucket
    log_step "Step 2/5: Setting up Terraform state bucket"
    if ! "$SCRIPT_DIR/terraform/setup-s3-bucket.sh"; then
        log_error "Step 2/5 FAILED: Terraform state bucket setup failed"
        log_info "Reason: Unable to create or configure S3 bucket for Terraform state"
        log_info "Check AWS credentials, S3 permissions, and TF_STATE_BUCKET in .env"
        exit 1
    fi
    log_success "Step 2/5 PASSED: Terraform state bucket ready"
    
    # Step 3: Deploy infrastructure
    log_step "Step 3/5: Deploying infrastructure layer"
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" infrastructure; then
        log_error "Step 3/5 FAILED: Infrastructure deployment failed"
        log_info "Reason: Terraform plan or apply failed for infrastructure layer"
        log_info "Check Terraform configuration, AWS permissions, and plan output above"
        exit 1
    fi
    log_success "Step 3/5 PASSED: Infrastructure layer deployed"
    
    # Step 4: Deploy EKS layer (EKS cluster, node groups, OIDC provider)
    log_step "Step 4/5: Deploying EKS layer (EKS cluster, node groups, OIDC provider)"
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" eks; then
        log_error "Step 4/5 FAILED: EKS layer deployment failed"
        log_info "Reason: Terraform plan or apply failed for EKS layer"
        log_info "Check Terraform configuration, AWS permissions, EKS quotas, and plan output above"
        exit 1
    fi
    log_success "Step 4/5 PASSED: EKS layer deployed"
    
    # Step 5: Configure kubectl and deploy Kubernetes manifests
    log_step "Step 5/5: Configuring kubectl and deploying Kubernetes manifests"
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
    log_success "Step 5/5 PASSED: Kubernetes manifests deployed"
    
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
            if [ "$DRY_RUN" != "true" ]; then
                "$SCRIPT_DIR/post_run_verify.sh" "$DEPLOYMENT_TYPE" "$ENVIRONMENT"
            fi
            ;;
        eks-full)
            deploy_eks_full
            echo ""
            if [ "$DRY_RUN" != "true" ]; then
                "$SCRIPT_DIR/post_run_verify.sh" "$DEPLOYMENT_TYPE" "$ENVIRONMENT"
            fi
            ;;
        infrastructure)
            deploy_infrastructure
            echo ""
            if [ "$DRY_RUN" != "true" ]; then
                "$SCRIPT_DIR/post_run_verify.sh" "$DEPLOYMENT_TYPE" "$ENVIRONMENT"
            fi
            ;;
        ecs)
            log_info "Starting ECS-specific deployment (legacy mode)..."
            "$SCRIPT_DIR/ecs/deploy.sh" "${REMAINING_ARGS[@]}"
            echo ""
            if [ "$DRY_RUN" != "true" ]; then
                "$SCRIPT_DIR/post_run_verify.sh" "$DEPLOYMENT_TYPE" "$ENVIRONMENT"
            fi
            ;;
        eks)
            log_info "Starting EKS-specific deployment (legacy mode)..."
            "$SCRIPT_DIR/eks/deploy.sh" "${REMAINING_ARGS[@]}"
            echo ""
            if [ "$DRY_RUN" != "true" ]; then
                "$SCRIPT_DIR/post_run_verify.sh" "$DEPLOYMENT_TYPE" "$ENVIRONMENT"
            fi
            ;;
        terraform)
            log_info "Starting Terraform deployment (legacy mode)..."
            "$SCRIPT_DIR/terraform/deploy.sh" "${REMAINING_ARGS[@]}"
            echo ""
            if [ "$DRY_RUN" != "true" ]; then
                "$SCRIPT_DIR/post_run_verify.sh" "$DEPLOYMENT_TYPE" "$ENVIRONMENT"
            fi
            ;;
        *)
            log_error "Unknown deployment type: $DEPLOYMENT_TYPE"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
