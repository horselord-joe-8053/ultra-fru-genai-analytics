#!/bin/bash
# Deploy local production simulation using Docker Compose
# Idempotent: docker compose up is safe to run multiple times

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"
source "$SCRIPT_DIR/../common/load-env.sh"

DOCKER_DIR="$REPO_ROOT/infra/docker"

deploy_services() {
    log_step "Deploying local production services"
    
    if [ ! -f "$REPO_ROOT/.env" ]; then
        log_error ".env file not found. Please run ../local/setup-env.sh first."
        exit 1
    fi
    
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
    
    # Load environment variables
    load_env_file
    
    log_info "Starting Docker Compose services in production mode..."
    docker compose --env-file "$REPO_ROOT/.env" up -d --build
    
    log_success "Services deployed"
    log_info "Waiting for services to be ready..."
    
    # Wait for services
    source "$SCRIPT_DIR/../common/wait-for-service.sh"
    wait_for_port "localhost" "5432" 30 2
    wait_for_service "http://localhost:5000/health" 30 2
    
    log_success "All services are ready!"
    log_info "  - Database: localhost:5432"
    log_info "  - API: http://localhost:5000"
    log_info ""
    log_info "To view logs: cd $DOCKER_DIR && docker compose logs -f"
    log_info "To stop services: cd $DOCKER_DIR && docker compose down"
}

main() {
    deploy_services
}

main "$@"

