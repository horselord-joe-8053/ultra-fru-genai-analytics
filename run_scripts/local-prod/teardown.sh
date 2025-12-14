#!/bin/bash
# Teardown local production simulation
# Idempotent: docker compose down is safe to run multiple times
# Usage: ./teardown.sh [--volumes] [--images]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"

DOCKER_DIR="$REPO_ROOT/infra/docker"

# Parse command line arguments
REMOVE_VOLUMES=false
REMOVE_IMAGES=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --volumes)
            REMOVE_VOLUMES=true
            shift
            ;;
        --images)
            REMOVE_IMAGES=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            log_info "Usage: $0 [--volumes] [--images]"
            exit 1
            ;;
    esac
done

teardown_services() {
    log_step "Teardown local production services"
    
    if [ ! -d "$DOCKER_DIR" ]; then
        log_error "Docker directory not found at $DOCKER_DIR"
        exit 1
    fi
    
    # Check if Docker is running
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker is not running. Please start Docker Desktop and try again."
        exit 1
    fi
    
    cd "$DOCKER_DIR"
    
    # Build docker compose command
    COMPOSE_CMD="docker compose down"
    
    if [ "$REMOVE_VOLUMES" = true ]; then
        COMPOSE_CMD="$COMPOSE_CMD -v"
        log_warning "Will remove volumes (including database data)"
    fi
    
    if [ "$REMOVE_IMAGES" = true ]; then
        COMPOSE_CMD="$COMPOSE_CMD --rmi all"
        log_warning "Will remove images"
    fi
    
    # Check if services are running
    if docker compose ps --quiet >/dev/null 2>&1; then
        log_info "Stopping and removing containers..."
        $COMPOSE_CMD
        log_success "Services stopped and removed"
    else
        log_info "No running containers found (already stopped or never started)"
        # Still run down to clean up any remaining resources
        $COMPOSE_CMD 2>/dev/null || true
    fi
    
    log_success "Teardown complete!"
    log_info ""
    
    if [ "$REMOVE_VOLUMES" = true ]; then
        log_info "Volumes removed (database data deleted)"
    else
        log_info "Volumes preserved (database data kept)"
        log_info "To remove volumes: $0 --volumes"
    fi
    
    if [ "$REMOVE_IMAGES" = true ]; then
        log_info "Images removed"
    else
        log_info "Images preserved"
        log_info "To remove images: $0 --images"
    fi
}

main() {
    teardown_services
}

main "$@"

