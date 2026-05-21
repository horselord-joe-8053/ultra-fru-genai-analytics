#!/bin/bash
# Delete local Docker images: all images by default, or filter by repo with --repo
# This script safely removes local Docker images.
#
# Usage:
#   ./util_sh/delete-docker-images.sh [--repo REPO_NAME] [--dry-run]
#
# Examples:
#   ./util_sh/delete-docker-images.sh              # Delete ALL local images
#   ./util_sh/delete-docker-images.sh --repo fru-api  # Delete only fru-api:* images
#   ./util_sh/delete-docker-images.sh --dry-run       # Dry-run for all images
#   ./util_sh/delete-docker-images.sh --repo fru-api --dry-run

set -e

REPO_NAME=""
DRY_RUN=false

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)
            REPO_NAME="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--repo REPO_NAME] [--dry-run] [--help]"
            echo "  --repo REPO_NAME  Filter deletion to specific repo (e.g., fru-api)"
            echo "                   If omitted, deletes ALL local Docker images"
            echo "  --dry-run        Show what would be deleted without actually deleting"
            echo "  --help           Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                          # Delete all local images"
            echo "  $0 --repo fru-api           # Delete only fru-api images"
            echo "  $0 --dry-run                # Preview all images to delete"
            echo "  $0 --repo fru-api --dry-run # Preview fru-api images to delete"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Ensure logger functions are available (fallback to echo if not)
if ! type log_info >/dev/null 2>&1; then
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_warning() { echo "[WARNING] $*"; }
    log_error() { echo "[ERROR] $*"; }
fi

delete_local_images_by_pattern() {
    local repo_name="$1"
    local dry_run="$2"
    
    log_info "Cleaning up local Docker images by pattern..."
    if [ -z "$repo_name" ]; then
        log_info "  Pattern: ALL local Docker images"
    else
        log_info "  Pattern: ${repo_name}:* and *.dkr.ecr.*.amazonaws.com/${repo_name}:*"
    fi
    
    # Check if Docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        log_warning "Docker daemon is not running (skipping local image cleanup)"
        return 0
    fi
    
    if [ "$dry_run" = "true" ]; then
        log_info "[DRY-RUN] Would clean up local Docker images:"
        if [ -z "$repo_name" ]; then
            log_info "[DRY-RUN]   - Remove ALL local images"
        else
            log_info "[DRY-RUN]   - Remove images matching pattern: ${repo_name}:*"
            log_info "[DRY-RUN]   - Remove images matching ECR repository URI pattern"
        fi
        return 0
    fi
    
    local images_found=false
    local images_removed=0
    
    if [ -z "$repo_name" ]; then
        # Delete ALL local Docker images
        log_info "Searching for all local Docker images..."
        local all_images
        all_images=$(docker images --format "{{.ID}} {{.Repository}}:{{.Tag}}" 2>/dev/null || echo "")
        
        if [ -n "$all_images" ]; then
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
            done <<< "$all_images"
        fi
    else
        # Delete images matching specific repo pattern
        # Find images matching the ECR repository name pattern (fru-api:*)
        log_info "Searching for images matching pattern: ${repo_name}:*"
        local image_list
        image_list=$(docker images "${repo_name}" --format "{{.ID}} {{.Repository}}:{{.Tag}}" 2>/dev/null || echo "")
        
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
        log_info "Searching for images matching ECR URI pattern (*.dkr.ecr.*.amazonaws.com/${repo_name}:*)..."
        local all_images
        all_images=$(docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" 2>/dev/null || echo "")
        
        if [ -n "$all_images" ]; then
            local ecr_images
            ecr_images=$(echo "$all_images" | grep -E "\.dkr\.ecr\..*\.amazonaws\.com/${repo_name}:" || echo "")
            
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
    fi
    
    if [ "$images_found" = false ]; then
        if [ -z "$repo_name" ]; then
            log_info "No local Docker images found"
        else
            log_info "No local Docker images found matching ECR repository pattern"
        fi
        log_info "Images may have been cleaned up already or never built locally"
    else
        if [ $images_removed -gt 0 ]; then
            log_success "Local Docker images cleaned up ($images_removed image(s) removed)"
        else
            log_warning "No images were removed (may be in use or already removed)"
        fi
    fi
    
    return 0
}

# Main entry point
delete_local_images_by_pattern "$REPO_NAME" "$DRY_RUN"
