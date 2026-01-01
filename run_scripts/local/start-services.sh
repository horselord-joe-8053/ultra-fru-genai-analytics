#!/bin/bash
# Start Docker services (Postgres + pgvector + API)
# Idempotent: Checks if services are running before starting

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"
source "$SCRIPT_DIR/../common/load-env.sh"

DOCKER_DIR="$REPO_ROOT/infra/docker"

BUILD_API=false
FORCE_START=false
SKIP_CHECK=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-api)
            BUILD_API=true
            shift
            ;;
        --force)
            FORCE_START=true
            shift
            ;;
        --skip-check)
            SKIP_CHECK=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            shift
            ;;
    esac
done

# Check if Docker services are already running
check_services_running() {
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qE "^fru_db$|^fru_api$"; then
        # Check if both services are running
        local db_running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^fru_db$" || echo "0")
        local api_running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^fru_api$" || echo "0")
        
        if [ "$db_running" -eq 1 ] && [ "$api_running" -eq 1 ]; then
            return 0  # Both services running
        fi
    fi
    return 1  # Services not running
}

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
    
    # Idempotency check: Skip if services are already running (unless --force)
    if [ "$SKIP_CHECK" = false ] && [ "$FORCE_START" = false ]; then
        if check_services_running; then
            log_info "Docker services are already running (fru_db, fru_api)"
            log_info "Skipping startup. Use --force to restart anyway."
            
            # Still wait for health checks to ensure they're ready
            load_env_file || true
            source "$SCRIPT_DIR/../common/wait-for-service.sh"
            wait_for_port "localhost" "55432" 10 1 || true
            local server_port="${LOCAL_SERVER_PORT:-5000}"
            wait_for_service "http://localhost:${server_port}/health" 10 1 || true
            
            log_success "Services are ready!"
            return 0
        fi
    fi
    
    log_info "Starting Docker Compose services..."
    if $BUILD_API; then
        log_info "Rebuilding API image..."
        docker compose --env-file "$REPO_ROOT/.env" build api
        
        # Clean up dangling images after build to prevent accumulation
        log_info "Cleaning up dangling images..."
        local pruned=$(docker image prune -f 2>/dev/null | grep -oP 'Total reclaimed space: \K[0-9.]+[KMGT]?i?B?' || echo "0B")
        if [ "$pruned" != "0B" ]; then
            log_info "Cleaned up $pruned of dangling images"
        fi
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

