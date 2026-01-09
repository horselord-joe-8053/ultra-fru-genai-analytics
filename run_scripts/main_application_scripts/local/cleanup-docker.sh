#!/bin/bash
# Cleanup Docker images, containers, and volumes
# Usage: ./cleanup-docker.sh [--all] [--images] [--containers] [--volumes] [--cache]
#
# This script helps clean up Docker resources for local development:
# - Stopped containers
# - Dangling images
# - Unused volumes
# - Build cache
#
# Safety: By default, shows current usage and prompts for confirmation
#         Use --all to clean everything (with confirmation prompt)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"

CLEAN_ALL=false
CLEAN_IMAGES=false
CLEAN_CONTAINERS=false
CLEAN_VOLUMES=false
CLEAN_CACHE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            CLEAN_ALL=true
            shift
            ;;
        --images)
            CLEAN_IMAGES=true
            shift
            ;;
        --containers)
            CLEAN_CONTAINERS=true
            shift
            ;;
        --volumes)
            CLEAN_VOLUMES=true
            shift
            ;;
        --cache)
            CLEAN_CACHE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--all] [--images] [--containers] [--volumes] [--cache]"
            exit 1
            ;;
    esac
done

# If no specific option, show current usage and prompt
if [ "$CLEAN_ALL" = false ] && [ "$CLEAN_IMAGES" = false ] && [ "$CLEAN_CONTAINERS" = false ] && [ "$CLEAN_VOLUMES" = false ] && [ "$CLEAN_CACHE" = false ]; then
    log_info "Current Docker disk usage:"
    docker system df
    echo ""
    log_info "Usage: $0 [--all] [--images] [--containers] [--volumes] [--cache]"
    log_info "  --all       : Clean everything (images, containers, volumes, cache)"
    log_info "  --images    : Remove dangling images"
    log_info "  --containers: Remove stopped containers"
    log_info "  --volumes   : Remove unused volumes"
    log_info "  --cache     : Remove build cache"
    exit 0
fi

# Ensure Docker is running
if ! docker info >/dev/null 2>&1; then
    log_error "Docker daemon is not running"
    log_info "Start Docker Desktop or Docker daemon and try again"
    exit 1
fi

log_step "Docker Cleanup"

cleanup_success=true

if [ "$CLEAN_ALL" = true ]; then
    log_info "Cleaning all unused Docker resources..."
    log_warning "This will remove:"
    log_warning "  - All stopped containers"
    log_warning "  - All unused images (not just dangling)"
    log_warning "  - All unused volumes"
    log_warning "  - All build cache"
    echo ""
    read -p "Are you sure? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Cleanup cancelled by user"
        exit 0
    fi
    
    log_info "Running docker system prune -a -f --volumes..."
    if docker system prune -a -f --volumes; then
        log_success "Docker cleanup completed successfully"
    else
        log_error "Docker cleanup failed"
        cleanup_success=false
    fi
else
    if [ "$CLEAN_IMAGES" = true ]; then
        log_info "Removing dangling images..."
        pruned=$(docker image prune -f 2>/dev/null | grep -oE 'Total reclaimed space: [0-9.]+[KMGT]?i?B?' | grep -oE '[0-9.]+[KMGT]?i?B?' || echo "0B")
        if [ "$pruned" != "0B" ]; then
            log_success "Cleaned up $pruned of dangling images"
        else
            log_info "No dangling images to clean"
        fi
    fi
    
    if [ "$CLEAN_CONTAINERS" = true ]; then
        log_info "Removing stopped containers..."
        if docker container prune -f; then
            log_success "Stopped containers removed"
        else
            log_warning "Failed to remove some stopped containers"
            cleanup_success=false
        fi
    fi
    
    if [ "$CLEAN_VOLUMES" = true ]; then
        log_warning "Removing unused volumes..."
        log_warning "This may remove database data if volumes are not in use!"
        read -p "Continue? (yes/no): " confirm
        if [ "$confirm" = "yes" ]; then
            if docker volume prune -f; then
                log_success "Unused volumes removed"
            else
                log_warning "Failed to remove some unused volumes"
                cleanup_success=false
            fi
        else
            log_info "Volume cleanup cancelled by user"
        fi
    fi
    
    if [ "$CLEAN_CACHE" = true ]; then
        log_info "Removing build cache..."
        if docker builder prune -f; then
            log_success "Build cache removed"
        else
            log_warning "Failed to remove some build cache"
            cleanup_success=false
        fi
    fi
fi

echo ""
log_info "Current Docker disk usage after cleanup:"
docker system df

if [ "$cleanup_success" = "true" ]; then
    exit 0
else
    log_warning "Some cleanup operations had issues"
    exit 1
fi

