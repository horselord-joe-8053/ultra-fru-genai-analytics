#!/bin/bash
# Cleanup Docker images, containers, and volumes
# Usage: ./cleanup-docker.sh [--all] [--images] [--containers] [--volumes] [--cache]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"

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
    exit 1
fi

log_step "Docker Cleanup"

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
        log_info "Cancelled"
        exit 0
    fi
    
    log_info "Running docker system prune -a -f --volumes..."
    docker system prune -a -f --volumes
    log_success "Cleanup complete"
else
    if [ "$CLEAN_IMAGES" = true ]; then
        log_info "Removing dangling images..."
        local pruned=$(docker image prune -f 2>/dev/null | grep -oP 'Total reclaimed space: \K[0-9.]+[KMGT]?i?B?' || echo "0B")
        if [ "$pruned" != "0B" ]; then
            log_success "Cleaned up $pruned of dangling images"
        else
            log_info "No dangling images to clean"
        fi
    fi
    
    if [ "$CLEAN_CONTAINERS" = true ]; then
        log_info "Removing stopped containers..."
        docker container prune -f
        log_success "Stopped containers removed"
    fi
    
    if [ "$CLEAN_VOLUMES" = true ]; then
        log_warning "Removing unused volumes..."
        log_warning "This may remove database data if volumes are not in use!"
        read -p "Continue? (yes/no): " confirm
        if [ "$confirm" = "yes" ]; then
            docker volume prune -f
            log_success "Unused volumes removed"
        else
            log_info "Cancelled"
        fi
    fi
    
    if [ "$CLEAN_CACHE" = true ]; then
        log_info "Removing build cache..."
        docker builder prune -f
        log_success "Build cache removed"
    fi
fi

log_info "Current Docker disk usage after cleanup:"
docker system df

