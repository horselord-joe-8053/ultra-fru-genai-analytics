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
source "$SCRIPT_DIR/../common/load-env.sh"

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
# If no arguments, default to ecs-full
# If first arg is a workflow, use it; otherwise it might be environment
if [ $# -eq 0 ]; then
    DEPLOYMENT_TYPE="$DEFAULT_DEPLOYMENT_TYPE"
    ENVIRONMENT="$DEFAULT_ENVIRONMENT"
elif [[ "$1" =~ ^(ecs-full|eks-full|infrastructure|ecs|eks|terraform|help|-h|--help)$ ]]; then
    DEPLOYMENT_TYPE="$1"
    ENVIRONMENT="${2:-$DEFAULT_ENVIRONMENT}"
else
    # First arg might be environment (legacy support)
    DEPLOYMENT_TYPE="$DEFAULT_DEPLOYMENT_TYPE"
    ENVIRONMENT="${1:-$DEFAULT_ENVIRONMENT}"
fi

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
                              → Deploy EKS application (Kubernetes manifests)

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

${BLUE}Examples:${NC}
  $0                                    # Default: $DEFAULT_DEPLOYMENT_TYPE deployment
  $0 ecs-full dev                      # Complete ECS deployment to dev
  $0 eks-full prod                     # Complete EKS deployment to prod
  $0 infrastructure dev                # Infrastructure only to dev
  $0 ecs --skip-build                  # ECS-specific (skip image build)
  $0 terraform dev all                 # Terraform manual control

${BLUE}Note:${NC}
  - All workflows are idempotent (safe to run multiple times)
  - Container image is checked/created automatically for *-full workflows
  - Infrastructure is shared between ECS and EKS deployments
EOF
}

# Check if container image exists in ECR (idempotent check)
check_or_build_image() {
    log_step "Checking container image availability"
    
    # Load environment variables
    load_env_file
    
    # Get AWS account and region
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    AWS_REGION="${AWS_REGION:-$DEFAULT_AWS_REGION}"
    ECR_REPO_NAME="$DEFAULT_ECR_REPO_NAME"
    IMAGE_TAG="${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"
    ECR_REPO_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME"
    
    # Check if image exists in ECR
    if aws ecr describe-images \
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
    
    # Step 1: Check/build container image (idempotent)
    if ! check_or_build_image; then
        log_error "Container image check/build failed"
        exit 1
    fi
    
    # Step 2: Setup Terraform state bucket
    log_step "Step 2/4: Setting up Terraform state bucket"
    "$SCRIPT_DIR/terraform/setup-s3-bucket.sh" || exit 1
    
    # Step 3: Deploy infrastructure
    log_step "Step 3/4: Deploying infrastructure layer"
    "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" infrastructure || exit 1
    
    # Step 4: Deploy application (CONTAINER_IMAGE is already exported from check_or_build_image)
    log_step "Step 4/4: Deploying application layer (ECS, ALB, Frontend)"
    log_info "Using container image: $CONTAINER_IMAGE"
    "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" application || exit 1
    
    log_success "Complete ECS deployment finished!"
    log_info "Your application should now be running on AWS ECS"
}

# Complete EKS deployment workflow
deploy_eks_full() {
    log_step "Starting complete EKS deployment workflow"
    log_info "Environment: $ENVIRONMENT"
    
    # Step 1: Check/build container image (idempotent)
    if ! check_or_build_image; then
        log_error "Container image check/build failed"
        exit 1
    fi
    
    # Step 2: Setup Terraform state bucket
    log_step "Step 2/4: Setting up Terraform state bucket"
    "$SCRIPT_DIR/terraform/setup-s3-bucket.sh" || exit 1
    
    # Step 3: Deploy infrastructure
    log_step "Step 3/4: Deploying infrastructure layer"
    "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" infrastructure || exit 1
    
    # Step 4: Deploy EKS application (CONTAINER_IMAGE is already exported from check_or_build_image)
    log_step "Step 4/4: Deploying EKS application (Kubernetes manifests)"
    log_info "Using container image: $CONTAINER_IMAGE"
    "$SCRIPT_DIR/eks/deploy.sh" || exit 1
    
    log_success "Complete EKS deployment finished!"
    log_info "Your application should now be running on AWS EKS"
}

# Infrastructure only workflow
deploy_infrastructure() {
    log_step "Starting infrastructure deployment"
    log_info "Environment: $ENVIRONMENT"
    
    # Step 1: Setup Terraform state bucket
    log_step "Step 1/2: Setting up Terraform state bucket"
    "$SCRIPT_DIR/terraform/setup-s3-bucket.sh" || exit 1
    
    # Step 2: Deploy infrastructure
    log_step "Step 2/2: Deploying infrastructure layer"
    "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" infrastructure || exit 1
    
    log_success "Infrastructure deployment finished!"
    log_info "Infrastructure is ready. Deploy application with: $0 ecs-full or $0 eks-full"
}

main() {
    # Handle help first (doesn't require AWS credentials)
    if [ "$DEPLOYMENT_TYPE" = "help" ] || [ "$DEPLOYMENT_TYPE" = "-h" ] || [ "$DEPLOYMENT_TYPE" = "--help" ]; then
        show_usage
        exit 0
    fi
    
    # Check AWS credentials for actual deployments
    "$SCRIPT_DIR/check-aws-credentials.sh" || exit 1
    
    # Handle deployment types
    case "$DEPLOYMENT_TYPE" in
        ecs-full)
            deploy_ecs_full
            echo ""
            "$SCRIPT_DIR/post_run_verify.sh" "$DEPLOYMENT_TYPE" "$ENVIRONMENT"
            ;;
        eks-full)
            deploy_eks_full
            echo ""
            "$SCRIPT_DIR/post_run_verify.sh" "$DEPLOYMENT_TYPE" "$ENVIRONMENT"
            ;;
        infrastructure)
            deploy_infrastructure
            echo ""
            "$SCRIPT_DIR/post_run_verify.sh" "$DEPLOYMENT_TYPE" "$ENVIRONMENT"
            ;;
        ecs)
            log_info "Starting ECS-specific deployment (legacy mode)..."
            "$SCRIPT_DIR/ecs/deploy.sh" "${@:2}"
            echo ""
            "$SCRIPT_DIR/post_run_verify.sh" "$DEPLOYMENT_TYPE" "$ENVIRONMENT"
            ;;
        eks)
            log_info "Starting EKS-specific deployment (legacy mode)..."
            "$SCRIPT_DIR/eks/deploy.sh" "${@:2}"
            echo ""
            "$SCRIPT_DIR/post_run_verify.sh" "$DEPLOYMENT_TYPE" "$ENVIRONMENT"
            ;;
        terraform)
            log_info "Starting Terraform deployment (legacy mode)..."
            "$SCRIPT_DIR/terraform/deploy.sh" "${@:2}"
            echo ""
            "$SCRIPT_DIR/post_run_verify.sh" "$DEPLOYMENT_TYPE" "$ENVIRONMENT"
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
