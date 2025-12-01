#!/bin/bash
# Build Docker images for local production simulation
# Idempotent: uses Docker layer caching

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"

DOCKER_DIR="$REPO_ROOT/infra/docker"

build_images() {
    log_step "Building Docker images"
    
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
    
    log_info "Building Docker images (this may take a few minutes)..."
    docker compose build
    
    log_success "Docker images built successfully"
}

main() {
    build_images
}

main "$@"

