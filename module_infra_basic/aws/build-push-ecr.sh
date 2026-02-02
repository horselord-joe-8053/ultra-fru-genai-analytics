#!/bin/bash
# Build and push Docker image to ECR
# Idempotent: checks if image exists before pushing
# Supports FORCE_REBUILD to rebuild even if image exists

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
source "$REPO_ROOT/orchestration/common/logger.sh"
# Save SCRIPT_DIR before sourcing load-env.sh (which sets its own SCRIPT_DIR)
BUILD_SCRIPT_DIR="$SCRIPT_DIR"
source "$REPO_ROOT/orchestration/common/env/load-env.sh"
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

# Ensure IMAGE_TAG matches what's in CONTAINER_IMAGE (if set and tag part is non-empty)
# Do not overwrite a valid IMAGE_TAG with an empty tag from CONTAINER_IMAGE (e.g. "ecr_uri:")
if [ -n "${CONTAINER_IMAGE:-}" ]; then
    _tag_from_image="${CONTAINER_IMAGE##*:}"
    _tag_from_image=$(echo "$_tag_from_image" | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -n "$_tag_from_image" ]; then
        IMAGE_TAG="$_tag_from_image"
        export IMAGE_TAG
    fi
    unset _tag_from_image
fi

build_and_push_ecr() {
    log_step "Building and pushing Docker image to ECR"
    
    # Fail fast if IMAGE_TAG is empty
    if [ -z "${IMAGE_TAG:-}" ]; then
        log_error "IMAGE_TAG is empty; cannot build or push. Check that ensure_image_tag ran and git_helpers.sh is on the path."
        exit 1
    fi
    
    # AWS credentials are already checked in Phase 0.4 of run.sh
    # Skip redundant check here
    
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
    
    # --- Step 1/4: Check ECR repository ---
    log_info "[Phase 1 build-push] Step 1/4: Checking if ECR repository exists: $ECR_REPO_NAME"
    local repo_exists=false
    local repo_check_output
    if repo_check_output=$(aws ecr describe-repositories --profile "$AWS_PROFILE" --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION" 2>&1); then
        repo_exists=true
        log_success "ECR repository exists: $ECR_REPO_NAME"
    else
        local repo_check_exit=$?
        if echo "$repo_check_output" | grep -q "RepositoryNotFoundException"; then
            log_info "ECR repository does not exist: $ECR_REPO_NAME (will be created)"
        else
            log_error "Failed to check ECR repository existence (exit code: $repo_check_exit)"
            log_error "Error: $repo_check_output"
            exit 1
        fi
    fi
    
    # --- Step 2/4: Check if image exists (by tag) ---
    # Note: We check by tag, not by content, so code changes with same tag won't be detected
    # This is why we use git SHA tags - each commit gets a unique tag
    local image_exists=false
    if [ "$repo_exists" = true ]; then
        log_info "[Phase 1 build-push] Step 2/4: Checking if container image exists: $ECR_REPO_URI:$IMAGE_TAG"
        local image_check_output
        if image_check_output=$(aws ecr describe-images --profile "$AWS_PROFILE" --repository-name "$ECR_REPO_NAME" --image-ids imageTag="$IMAGE_TAG" --region "$AWS_REGION" 2>&1); then
            image_exists=true
            log_success "Container image already exists: $ECR_REPO_URI:$IMAGE_TAG"
            log_info "Note: If code changed but tag is the same, set FORCE_REBUILD=true to rebuild"
        else
            local image_check_exit=$?
            if echo "$image_check_output" | grep -q "ImageNotFoundException\|does not exist"; then
                log_info "Container image not found: $ECR_REPO_URI:$IMAGE_TAG (will be built)"
            else
                log_error "Failed to check container image existence (exit code: $image_check_exit)"
                log_error "Error: $image_check_output"
                exit 1
            fi
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
    source "$REPO_ROOT/orchestration/common/docker_run.sh"
    if ! ensure_docker_running; then
        log_error "Failed to start Docker daemon"
        exit 1
    fi
    
    # --- Step 3/4: ECR login ---
    log_info "[Phase 1 build-push] Step 3/4: Logging in to ECR..."
    if ! aws ecr get-login-password --profile "$AWS_PROFILE" --region "$AWS_REGION" | \
        docker login --username AWS --password-stdin "$ECR_URL"; then
        log_error "ECR login failed. Check AWS credentials and ECR permissions."
        exit 1
    fi
    log_success "ECR login succeeded"
    
    # --- Step 4/4: Docker build (this is the slow step; output streams so you see progress) ---
    log_info "[Phase 1 build-push] Step 4/4: Building Docker image for linux/amd64 (required for ECS Fargate)..."
    log_info "  Build args: SPARK_VERSION=${SPARK_VERSION:-4.0.1}, HADOOP_VERSION=${HADOOP_VERSION:-3}"
    log_info "  Dockerfile: $REPO_ROOT/module_app_core/pack_with_docker/Dockerfile.api"
    log_info "  Docker build output (streaming) — next lines are from 'docker build':"
    cd "$REPO_ROOT"
    docker build --platform linux/amd64 --progress=plain \
        --build-arg SPARK_VERSION=${SPARK_VERSION:-4.0.1} \
        --build-arg HADOOP_VERSION=${HADOOP_VERSION:-3} \
        -t "$ECR_REPO_NAME:$IMAGE_TAG" \
        -f $REPO_ROOT/module_app_core/pack_with_docker/Dockerfile.api .
    
    # Tag image
    log_info "Tagging image for ECR..."
    docker tag "$ECR_REPO_NAME:$IMAGE_TAG" "$ECR_REPO_URI:$IMAGE_TAG"
    
    # Push image (streams progress)
    log_info "Pushing image to ECR (this may take a few minutes)..."
    log_info "  Full image: $ECR_REPO_URI:$IMAGE_TAG"
    log_info "  Note: 'Waiting' per layer is normal; Docker does not stream upload progress. 'Layer already exists' = skip (already in ECR)."
    if ! docker push "$ECR_REPO_URI:$IMAGE_TAG"; then
        log_error "Docker push failed. Check ECR permissions and network."
        exit 1
    fi
    
    # Also tag as 'latest' for convenience (Terraform will use the git SHA tag)
    # This allows manual operations to use 'latest' while Terraform uses specific version
    log_info "Tagging as 'latest' for convenience..."
    docker tag "$ECR_REPO_URI:$IMAGE_TAG" "$ECR_REPO_URI:latest"
    docker push "$ECR_REPO_URI:latest" || log_warning "Failed to push 'latest' tag (non-critical)"
    
    log_success "Image pushed successfully: $ECR_REPO_URI:$IMAGE_TAG"
    log_info "Image URI for Terraform: $ECR_REPO_URI:$IMAGE_TAG"
    log_info "Note: Terraform will use the git SHA tag to detect changes automatically"
    
    # Clean up local Docker images after successful push
    # Only cleanup if we actually built and pushed (not if image already existed)
    if [ "$should_rebuild" = true ]; then
        log_info "Cleaning up local Docker images after successful ECR push..."
        
        # Verify image exists in ECR before cleanup (safety check)
        log_info "Verifying image exists in ECR before cleanup..."
        if aws ecr describe-images \
            --profile "$AWS_PROFILE" \
            --repository-name "$ECR_REPO_NAME" \
            --image-ids imageTag="$IMAGE_TAG" \
            --region "$AWS_REGION" >/dev/null 2>&1; then
            
            log_success "ECR image verified, proceeding with local cleanup..."
            
            # Source cleanup helper function
            local cleanup_helper="$REPO_ROOT/orchestration/common/deploy/cleanup-local-docker-images.sh"
            if [ -f "$cleanup_helper" ]; then
                source "$cleanup_helper"
                
                # Call cleanup function (non-fatal - errors are warnings)
                cleanup_local_docker_images_after_ecr_push \
                    "$ECR_REPO_NAME" "$ECR_REPO_URI" "$IMAGE_TAG" || {
                    log_warning "Local image cleanup had issues (non-fatal - deployment will continue)"
                }
            else
                log_warning "Cleanup helper script not found: $cleanup_helper"
                log_warning "Skipping local image cleanup (images will remain on disk)"
            fi
        else
            log_warning "ECR image verification failed - skipping cleanup for safety"
            log_warning "  Image may not have been pushed successfully or tag may be incorrect"
            log_warning "  Local images will remain on disk to prevent data loss"
        fi
    else
        log_info "Skipping cleanup (image already existed, no new build/push occurred)"
    fi
}

main() {
    build_and_push_ecr
}

main "$@"
