#!/bin/bash
# Reusable function to clean up local Docker images after ECR push
# This function safely removes local images that have been successfully pushed to ECR
#
# Usage:
#   source cleanup-local-docker-images.sh
#   cleanup_local_docker_images_after_ecr_push <repo_name> <ecr_repo_uri> <image_tag> [dry_run]
#
# Parameters:
#   $1: ECR repository name (e.g., "fru-api")
#   $2: ECR repository URI (e.g., "744139897900.dkr.ecr.us-east-1.amazonaws.com/fru-api")
#   $3: Image tag (e.g., "fru-dev-20260121-93c2d3f")
#   $4: Dry-run flag (optional, defaults to $DRY_RUN env var)
#
# Safety Features:
#   - Verifies ECR image exists before removing local copy
#   - Only removes specific images (not pattern-based)
#   - Non-fatal: errors are warnings, not failures
#   - Supports dry-run mode
#
# Note: This script expects to be sourced by a script that has already loaded logger.sh
# If logger functions are not available, it will fall back to echo

# Ensure logger functions are available (fallback to echo if not)
if ! type log_info >/dev/null 2>&1; then
    # Fallback logger functions if logger.sh not sourced
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_warning() { echo "[WARNING] $*"; }
    log_error() { echo "[ERROR] $*"; }
fi

cleanup_local_docker_images_after_ecr_push() {
    local ecr_repo_name="${1:-}"
    local ecr_repo_uri="${2:-}"
    local image_tag="${3:-}"
    local dry_run="${4:-${DRY_RUN:-false}}"
    
    # Validate required parameters
    if [ -z "$ecr_repo_name" ] || [ -z "$ecr_repo_uri" ] || [ -z "$image_tag" ]; then
        log_warning "cleanup_local_docker_images_after_ecr_push: Missing required parameters"
        log_warning "  Required: repo_name, ecr_repo_uri, image_tag"
        log_warning "  Received: repo_name='$ecr_repo_name', ecr_repo_uri='$ecr_repo_uri', image_tag='$image_tag'"
        return 0  # Non-fatal, return success
    fi
    
    log_info "Cleaning up local Docker images after ECR push..."
    log_info "  Repository: $ecr_repo_name"
    log_info "  ECR URI: $ecr_repo_uri"
    log_info "  Tag: $image_tag"
    
    # Check if Docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        log_warning "Docker daemon is not running (skipping local image cleanup)"
        return 0  # Non-fatal
    fi
    
    # Verify ECR image exists (safety check)
    # This ensures we only remove local images that were successfully pushed
    local aws_profile="${AWS_PROFILE:-admin}"
    local aws_region="${AWS_REGION:-us-east-1}"
    
    log_info "Verifying image exists in ECR before cleanup..."
    if ! aws ecr describe-images \
        --profile "$aws_profile" \
        --repository-name "$ecr_repo_name" \
        --image-ids imageTag="$image_tag" \
        --region "$aws_region" >/dev/null 2>&1; then
        log_warning "ECR image verification failed - skipping cleanup for safety"
        log_warning "  Image may not have been pushed successfully or tag may be incorrect"
        return 0  # Non-fatal, safety first
    fi
    
    log_success "ECR image verified: $ecr_repo_uri:$image_tag"
    
    # Images to remove (specific tags, not pattern-based for safety)
    local images_to_remove=(
        "${ecr_repo_name}:${image_tag}"
        "${ecr_repo_uri}:${image_tag}"
        "${ecr_repo_uri}:latest"
    )
    
    if [ "$dry_run" = "true" ]; then
        log_info "[DRY-RUN] Would remove the following local Docker images:"
        for image in "${images_to_remove[@]}"; do
            log_info "  [DRY-RUN]   - $image"
        done
        return 0
    fi
    
    # Remove specific images
    local images_removed=0
    local images_failed=0
    
    for image in "${images_to_remove[@]}"; do
        # Check if image exists locally
        if docker images "$image" --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -q "^${image}$"; then
            log_info "  Removing local image: $image"
            
            # Get image ID for more reliable removal
            local image_id
            image_id=$(docker images "$image" --format "{{.ID}}" 2>/dev/null | head -1)
            
            if [ -n "$image_id" ] && [ "$image_id" != "None" ]; then
                if docker rmi -f "$image_id" >/dev/null 2>&1; then
                    images_removed=$((images_removed + 1))
                    log_success "    ✓ Removed: $image ($image_id)"
                else
                    images_failed=$((images_failed + 1))
                    log_warning "    ✗ Failed to remove: $image (may be in use or already removed)"
                fi
            else
                log_info "    ⊘ Image not found locally: $image (may have been removed already)"
            fi
        else
            log_info "    ⊘ Image not found locally: $image (may have been removed already)"
        fi
    done
    
    # Summary
    if [ $images_removed -gt 0 ]; then
        log_success "Local Docker images cleaned up ($images_removed image(s) removed)"
        if [ $images_failed -gt 0 ]; then
            log_warning "Some images could not be removed ($images_failed image(s) failed)"
        fi
    elif [ $images_failed -gt 0 ]; then
        log_warning "No images were removed ($images_failed image(s) failed)"
    else
        log_info "No local images found to remove (may have been cleaned up already)"
    fi
    
    return 0  # Always return success (non-fatal operation)
}

# Alternative function for pattern-based cleanup (used by teardown-resources.sh)
# This is more aggressive and removes all images matching patterns
cleanup_local_images_by_pattern() {
    local ecr_repo_name="${1:-fru-api}"
    local dry_run="${2:-${DRY_RUN:-false}}"
    
    log_info "Cleaning up local Docker images by pattern..."
    log_info "  Pattern: ${ecr_repo_name}:* and *.dkr.ecr.*.amazonaws.com/${ecr_repo_name}:*"
    
    # Check if Docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        log_warning "Docker daemon is not running (skipping local image cleanup)"
        return 0  # Non-fatal
    fi
    
    if [ "$dry_run" = "true" ]; then
        log_info "[DRY-RUN] Would clean up local Docker images:"
        log_info "[DRY-RUN]   - Remove images matching pattern: ${ecr_repo_name}:*"
        log_info "[DRY-RUN]   - Remove images matching ECR repository URI pattern"
        return 0
    fi
    
    local images_found=false
    local images_removed=0
    
    # Find images matching the ECR repository name pattern (fru-api:*)
    log_info "Searching for images matching pattern: ${ecr_repo_name}:*"
    local image_list
    image_list=$(docker images "${ecr_repo_name}" --format "{{.ID}} {{.Repository}}:{{.Tag}}" 2>/dev/null || echo "")
    
    if [ -n "$image_list" ]; then
        images_found=true
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
    
    # Also check for images with ECR repository URI pattern
    log_info "Searching for images matching ECR URI pattern (*.dkr.ecr.*.amazonaws.com/${ecr_repo_name}:*)..."
    local all_images
    all_images=$(docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" 2>/dev/null || echo "")
    
    if [ -n "$all_images" ]; then
        local ecr_images
        ecr_images=$(echo "$all_images" | grep -E "\.dkr\.ecr\..*\.amazonaws\.com/${ecr_repo_name}:" || echo "")
        
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
        if [ $images_removed -gt 0 ]; then
            log_success "Local Docker images cleaned up ($images_removed image(s) removed)"
        else
            log_warning "No images were removed (may be in use or already removed)"
        fi
    fi
    
    return 0  # Always return success (non-fatal operation)
}

