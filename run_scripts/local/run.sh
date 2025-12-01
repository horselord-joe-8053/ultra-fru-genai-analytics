#!/bin/bash
# Main orchestrator script for local development setup
# This script sets up and starts the entire local development environment
# Usage: ./run.sh [--skip-frontend] [--skip-data-load]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"

# Parse command line arguments
SKIP_FRONTEND=false
SKIP_DATA_LOAD=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-frontend)
            SKIP_FRONTEND=true
            shift
            ;;
        --skip-data-load)
            SKIP_DATA_LOAD=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            log_info "Usage: $0 [--skip-frontend] [--skip-data-load]"
            exit 1
            ;;
    esac
done

# Main setup function
main() {
    log_step "Starting local development environment setup"
    
    # Step 1: Check prerequisites
    log_step "Step 1/7: Checking prerequisites"
    "$SCRIPT_DIR/../common/check-dependencies.sh" || exit 1
    
    # Step 2: Setup .env file
    log_step "Step 2/7: Setting up environment file"
    "$SCRIPT_DIR/setup-env.sh" || exit 1
    
    # Step 3: Setup Python environment
    log_step "Step 3/7: Setting up Python environment"
    "$SCRIPT_DIR/setup-python.sh" || exit 1
    
    # Step 4: Setup frontend dependencies
    log_step "Step 4/7: Setting up frontend dependencies"
    "$SCRIPT_DIR/setup-frontend.sh" || exit 1
    
    # Step 5: Start Docker services
    log_step "Step 5/7: Starting Docker services"
    "$SCRIPT_DIR/start-services.sh" || exit 1
    
    # Step 6: Initialize database
    log_step "Step 6/7: Initializing database schema"
    "$SCRIPT_DIR/init-db.sh" || exit 1
    
    # Step 7: Load data (optional)
    if [ "$SKIP_DATA_LOAD" = false ]; then
        log_step "Step 7/7: Loading data into database"
        "$SCRIPT_DIR/load-data.sh" || exit 1
    else
        log_info "Skipping data load (--skip-data-load flag set)"
    fi
    
    # Summary
    log_success "Local development environment is ready!"
    echo ""
    log_info "Services running:"
    log_info "  - Database: localhost:5432"
    log_info "  - API: http://localhost:5000"
    echo ""
    
    # Start frontend (optional)
    if [ "$SKIP_FRONTEND" = false ]; then
        log_info "Starting frontend development server..."
        log_info "Press Ctrl+C to stop the frontend server"
        echo ""
        "$SCRIPT_DIR/start-frontend.sh"
    else
        log_info "To start the frontend, run:"
        log_info "  cd $REPO_ROOT/frontend && npm run dev"
        echo ""
        log_info "Or run: ./run_scripts/local/start-frontend.sh"
    fi
}

# Run main function
main "$@"

