#!/bin/bash
# Start Docker services (Postgres + pgvector + API)
# Idempotent: docker compose up -d is safe to run multiple times

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"
source "$SCRIPT_DIR/../common/load-env.sh"

DOCKER_DIR="$REPO_ROOT/infra/docker"

start_services() {
    log_step "Starting Docker services"
    
    if [ ! -f "$REPO_ROOT/.env" ]; then
        log_error ".env file not found. Please run setup-env.sh first."
        exit 1
    fi
    
    if [ ! -d "$DOCKER_DIR" ]; then
        log_error "Docker directory not found at $DOCKER_DIR"
        exit 1
    fi
    
    cd "$DOCKER_DIR"
    
    # Check if Docker is running
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker is not running. Please start Docker Desktop and try again."
        exit 1
    fi
    
    log_info "Starting Docker Compose services..."
    docker compose --env-file "$REPO_ROOT/.env" up -d
    
    log_success "Docker services started"
    log_info "Waiting for services to be ready..."
    
    # Wait for database to be ready
    source "$SCRIPT_DIR/../common/wait-for-service.sh"
    wait_for_port "localhost" "5432" 30 2
    
    # Wait for API health check
    wait_for_service "http://localhost:5000/health" 30 2
    
    log_success "All services are ready!"
    log_info "  - Database: localhost:5432"
    log_info "  - API: http://localhost:5000"
}

main() {
    start_services
}

main "$@"

