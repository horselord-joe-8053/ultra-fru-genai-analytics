#!/bin/bash
# Build and push Docker image to ECR
# Idempotent: checks if image exists before pushing
# Supports FORCE_REBUILD to rebuild even if image exists

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../" && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
# Save SCRIPT_DIR before sourcing load-env.sh (which sets its own SCRIPT_DIR)
BUILD_SCRIPT_DIR="$SCRIPT_DIR"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"
# Restore our SCRIPT_DIR
SCRIPT_DIR="$BUILD_SCRIPT_DIR"
ECR_REPO_NAME="fru-api"

# Check for dry-run mode (from parent script)
DRY_RUN="${DRY_RUN:-false}"

# Check for force rebuild flag
# Set FORCE_REBUILD=true to rebuild even if image exists
FORCE_REBUILD="${FORCE_REBUILD:-false}"

# Generate IMAGE_TAG if not set (using centralized function from load-env.sh)
# This ensures consistent tag generation across all scripts
ensure_image_tag

# Build ECR_REPO_URI if not set (using centralized function from load-env.sh)
# If CONTAINER_IMAGE is set, extract ECR_REPO_URI from it
# Otherwise, build from AWS account/region
if [ -z "${ECR_REPO_URI:-}" ]; then
    if [ -n "${CONTAINER_IMAGE:-}" ]; then
        # Extract ECR URI from CONTAINER_IMAGE (format: ECR_URI:IMAGE_TAG)
        ECR_REPO_URI="${CONTAINER_IMAGE%%:*}"
    else
        # Build ECR URI dynamically
        ECR_REPO_URI=$(build_ecr_repo_uri)
    fi
    export ECR_REPO_URI
fi

# Ensure IMAGE_TAG matches what's in CONTAINER_IMAGE (if set)
if [ -n "${CONTAINER_IMAGE:-}" ]; then
    IMAGE_TAG="${CONTAINER_IMAGE##*:}"
    export IMAGE_TAG
fi

build_and_push_ecr() {
    log_step "Building and pushing Docker image to ECR"
    
    # Check AWS credentials
    "$REPO_ROOT/run_scripts/main_application_scripts/aws/check-aws-credentials.sh" || exit 1
    
    # Load environment variables
    load_env_file
    
    # Use admin profile for infrastructure operations (ECR)
    AWS_PROFILE="${AWS_PROFILE:-admin}"
    log_info "Using AWS profile: $AWS_PROFILE (for infrastructure operations)"
    
    # Ensure ECR_REPO_URI is set (should already be set above, but double-check)
    if [ -z "${ECR_REPO_URI:-}" ]; then
        ECR_REPO_URI=$(build_ecr_repo_uri)
        export ECR_REPO_URI
    fi
    
    # Extract ECR_URL (base URL without repo name) for docker login
    # ECR_REPO_URI format: account.dkr.ecr.region.amazonaws.com/repo-name
    # ECR_URL format: account.dkr.ecr.region.amazonaws.com
    ECR_URL="${ECR_REPO_URI%/*}"
    export ECR_URL
    
    log_info "ECR Repository: $ECR_REPO_URI"
    log_info "Image Tag: $IMAGE_TAG"
    log_info "Full Image URI: $ECR_REPO_URI:$IMAGE_TAG"
    
    # Check if ECR repository exists
    local repo_exists=false
    if aws ecr describe-repositories --profile "$AWS_PROFILE" --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
        repo_exists=true
        log_info "ECR repository already exists"
    else
        log_info "ECR repository does not exist"
    fi
    
    # Check if image exists (by tag)
    # Note: We check by tag, not by content, so code changes with same tag won't be detected
    # This is why we use git SHA tags - each commit gets a unique tag
    local image_exists=false
    if [ "$repo_exists" = true ]; then
        if aws ecr describe-images --profile "$AWS_PROFILE" --repository-name "$ECR_REPO_NAME" --image-ids imageTag="$IMAGE_TAG" --region "$AWS_REGION" >/dev/null 2>&1; then
            image_exists=true
            log_info "Container image already exists: $ECR_REPO_URI:$IMAGE_TAG"
            log_info "Note: If code changed but tag is the same, set FORCE_REBUILD=true to rebuild"
        fi
    fi
    
    # Handle force rebuild
    local should_rebuild=false
    if [ "$FORCE_REBUILD" = "true" ]; then
        if [ "$image_exists" = true ]; then
            log_info "FORCE_REBUILD=true: Will rebuild and replace existing image"
            should_rebuild=true
        else
            log_info "FORCE_REBUILD=true: Will build new image"
            should_rebuild=true
        fi
    elif [ "$image_exists" = false ]; then
        log_info "Image does not exist: Will build new image"
        should_rebuild=true
    else
        log_info "Image already exists and FORCE_REBUILD=false: Skipping build"
        should_rebuild=false
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would perform the following operations:"
        if [ "$repo_exists" = false ]; then
            log_info "[DRY-RUN]   - Create ECR repository: $ECR_REPO_NAME"
        fi
        if [ "$should_rebuild" = true ]; then
            if [ "$image_exists" = true ] && [ "$FORCE_REBUILD" = "true" ]; then
                log_info "[DRY-RUN]   - Delete existing image: $ECR_REPO_URI:$IMAGE_TAG"
            fi
            log_info "[DRY-RUN]   - Build Docker image: $ECR_REPO_NAME:$IMAGE_TAG"
            log_info "[DRY-RUN]   - Tag image: $ECR_REPO_URI:$IMAGE_TAG"
            log_info "[DRY-RUN]   - Push image to ECR: $ECR_REPO_URI:$IMAGE_TAG"
        else
            log_info "[DRY-RUN]   - Image already exists, no build/push needed"
        fi
        log_info "[DRY-RUN] ECR Repository URI: $ECR_REPO_URI"
        log_info "[DRY-RUN] Image Tag: $IMAGE_TAG"
        log_info "[DRY-RUN] FORCE_REBUILD: $FORCE_REBUILD"
        return 0
    fi
    
    # Create ECR repository if it doesn't exist
    if [ "$repo_exists" = false ]; then
        log_info "ECR repository does not exist, creating..."
        aws ecr create-repository --profile "$AWS_PROFILE" --repository-name "$ECR_REPO_NAME" --region "$AWS_REGION"
        log_success "ECR repository created"
    fi
    
    # If image exists and we're not forcing rebuild, we're done
    if [ "$should_rebuild" = false ]; then
        log_success "Image already exists: $ECR_REPO_URI:$IMAGE_TAG"
        log_info "To force rebuild, set FORCE_REBUILD=true"
        return 0
    fi
    
    # Delete existing image if forcing rebuild
    if [ "$image_exists" = true ] && [ "$FORCE_REBUILD" = "true" ]; then
        log_info "Deleting existing image: $ECR_REPO_URI:$IMAGE_TAG"
        if aws ecr batch-delete-image --profile "$AWS_PROFILE" --repository-name "$ECR_REPO_NAME" --image-ids imageTag="$IMAGE_TAG" --region "$AWS_REGION" >/dev/null 2>&1; then
            log_success "Existing image deleted"
        else
            log_warning "Failed to delete existing image (may not exist or already deleted)"
        fi
    fi
    
    # Ensure Docker daemon is running
    source "$REPO_ROOT/run_scripts/main_application_scripts/common/docker_run.sh"
    if ! ensure_docker_running; then
        log_error "Failed to start Docker daemon"
        exit 1
    fi
    
    # Login to ECR
    log_info "Logging in to ECR..."
    aws ecr get-login-password --profile "$AWS_PROFILE" --region "$AWS_REGION" | \
        docker login --username AWS --password-stdin "$ECR_URL"
    
    # Build Docker image
    # Pass Spark and Hadoop versions from .env (source of truth)
    # load_env_file was called earlier, so SPARK_VERSION and HADOOP_VERSION are available
    log_info "Building Docker image for linux/amd64 platform (required for ECS Fargate)..."
    log_info "Using SPARK_VERSION=${SPARK_VERSION:-4.0.1}, HADOOP_VERSION=${HADOOP_VERSION:-3}"
    cd "$REPO_ROOT"
    docker build --platform linux/amd64 \
        --build-arg SPARK_VERSION=${SPARK_VERSION:-4.0.1} \
        --build-arg HADOOP_VERSION=${HADOOP_VERSION:-3} \
        -t "$ECR_REPO_NAME:$IMAGE_TAG" \
        -f $REPO_ROOT/infra/docker/Dockerfile.api .
    
    # Tag image
    log_info "Tagging image..."
    docker tag "$ECR_REPO_NAME:$IMAGE_TAG" "$ECR_REPO_URI:$IMAGE_TAG"
    
    # Push image
    log_info "Pushing image to ECR..."
    docker push "$ECR_REPO_URI:$IMAGE_TAG"
    
    # Also tag as 'latest' for convenience (Terraform will use the git SHA tag)
    # This allows manual operations to use 'latest' while Terraform uses specific version
    log_info "Tagging as 'latest' for convenience..."
    docker tag "$ECR_REPO_URI:$IMAGE_TAG" "$ECR_REPO_URI:latest"
    docker push "$ECR_REPO_URI:latest" || log_warning "Failed to push 'latest' tag (non-critical)"
    
    log_success "Image pushed successfully: $ECR_REPO_URI:$IMAGE_TAG"
    log_info "Image URI for Terraform: $ECR_REPO_URI:$IMAGE_TAG"
    log_info "Note: Terraform will use the git SHA tag to detect changes automatically"
}

main() {
    build_and_push_ecr
}

main "$@"

