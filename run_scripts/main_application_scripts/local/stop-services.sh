#!/bin/bash
# Stop all Docker services
# Idempotent: safe to run even if services are already stopped

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/orchestration/shared/logger.sh"

DOCKER_DIR="$REPO_ROOT/module_infra_nonkube/local"

stop_services() {
    log_step "Stopping Docker services"
    
    if [ ! -d "$DOCKER_DIR" ]; then
        log_error "Docker directory not found at $DOCKER_DIR"
        exit 1
    fi
    
    cd "$DOCKER_DIR"
    
    log_info "Stopping Docker Compose services..."
    docker compose down
    
    log_success "Docker services stopped"
}

main() {
    stop_services
}

main "$@"

