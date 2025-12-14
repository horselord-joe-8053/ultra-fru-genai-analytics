#!/bin/bash
# Build and push Docker image to ECR
# Idempotent: checks if image exists before pushing

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/../../common/logger.sh"
# Save SCRIPT_DIR before sourcing load-env.sh (which sets its own SCRIPT_DIR)
BUILD_SCRIPT_DIR="$SCRIPT_DIR"
source "$SCRIPT_DIR/../../common/load-env.sh"
# Restore our SCRIPT_DIR
SCRIPT_DIR="$BUILD_SCRIPT_DIR"

ECR_REPO_NAME="fru-api"
IMAGE_TAG="${IMAGE_TAG:-latest}"

build_and_push_ecr() {
    log_step "Building and pushing Docker image to ECR"
    
    # Check AWS credentials
    "$SCRIPT_DIR/../check-aws-credentials.sh" || exit 1
    
    # Load environment variables
    load_env_file
    
    # Use admin profile for infrastructure operations (ECR)
    AWS_PROFILE="${AWS_PROFILE:-admin}"
    log_info "Using AWS profile: $AWS_PROFILE (for infrastructure operations)"
    
    # Get AWS account and region
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text)
    AWS_REGION="${AWS_REGION:-us-east-1}"
    ECR_URL="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
    ECR_REPO_URI="$ECR_URL/$ECR_REPO_NAME"
    
    log_info "ECR Repository: $ECR_REPO_URI"
    log_info "Image Tag: $IMAGE_TAG"
    
    # Check if ECR repository exists, create if not
    if ! aws ecr describe-repositories --profile "$AWS_PROFILE" --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
        log_info "ECR repository does not exist, creating..."
        aws ecr create-repository --profile "$AWS_PROFILE" --repository-name "$ECR_REPO_NAME" --region "$AWS_REGION"
        log_success "ECR repository created"
    else
        log_info "ECR repository already exists"
    fi
    
    # Login to ECR
    log_info "Logging in to ECR..."
    aws ecr get-login-password --profile "$AWS_PROFILE" --region "$AWS_REGION" | \
        docker login --username AWS --password-stdin "$ECR_URL"
    
    # Build Docker image
    log_info "Building Docker image..."
    cd "$REPO_ROOT"
    docker build -t "$ECR_REPO_NAME:$IMAGE_TAG" -f $REPO_ROOT/infra/docker/Dockerfile.api .
    
    # Tag image
    log_info "Tagging image..."
    docker tag "$ECR_REPO_NAME:$IMAGE_TAG" "$ECR_REPO_URI:$IMAGE_TAG"
    
    # Push image
    log_info "Pushing image to ECR..."
    docker push "$ECR_REPO_URI:$IMAGE_TAG"
    
    log_success "Image pushed successfully: $ECR_REPO_URI:$IMAGE_TAG"
    log_info "Use this image URI in your ECS task definition"
}

main() {
    build_and_push_ecr
}

main "$@"

