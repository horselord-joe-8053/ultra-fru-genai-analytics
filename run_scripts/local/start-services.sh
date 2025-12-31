#!/bin/bash
# Start Docker services (Postgres + pgvector + API)
# Idempotent: docker compose up -d is safe to run multiple times

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"
source "$SCRIPT_DIR/../common/load-env.sh"

DOCKER_DIR="$REPO_ROOT/infra/docker"

BUILD_API=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-api)
            BUILD_API=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            shift
            ;;
    esac
done

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
    
    # Ensure Docker daemon is running
    source "$SCRIPT_DIR/../common/docker_run.sh"
    if ! ensure_docker_running; then
        log_error "Failed to start Docker daemon"
        exit 1
    fi
    
    log_info "Starting Docker Compose services..."
    if $BUILD_API; then
        log_info "Rebuilding API image..."
        docker compose --env-file "$REPO_ROOT/.env" build api
    fi
    docker compose --env-file "$REPO_ROOT/.env" up -d
    
    log_success "Docker services started"
    log_info "Waiting for services to be ready..."
    
    # Load .env to get LOCAL_SERVER_PORT
    load_env_file || true
    
    # Wait for database to be ready (database is exposed on port 55432 on host)
    source "$SCRIPT_DIR/../common/wait-for-service.sh"
    wait_for_port "localhost" "55432" 30 2
    
    # Wait for API health check (use LOCAL_SERVER_PORT from .env, default 5000)
    local server_port="${LOCAL_SERVER_PORT:-5000}"
    wait_for_service "http://localhost:${server_port}/health" 30 2
    
    log_success "All services are ready!"
    log_info "  - Database: localhost:55432"
    log_info "  - API: http://localhost:${server_port}"
}

main() {
    start_services
}

main "$@"

