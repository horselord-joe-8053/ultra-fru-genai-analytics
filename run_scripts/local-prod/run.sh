#!/bin/bash
# Main orchestrator script for local production simulation
# This script builds and deploys the entire application using Docker
# Usage: ./run.sh [--skip-build] [--skip-frontend]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"

# Parse command line arguments
SKIP_BUILD=false
SKIP_FRONTEND=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-frontend)
            SKIP_FRONTEND=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            log_info "Usage: $0 [--skip-build] [--skip-frontend]"
            exit 1
            ;;
    esac
done

# Main deployment function
main() {
    log_step "Starting local production simulation deployment"
    
    # Step 1: Check prerequisites
    log_step "Step 1/5: Checking prerequisites"
    "$SCRIPT_DIR/../common/check-dependencies.sh" || exit 1
    
    # Step 2: Setup .env file (if needed)
    if [ ! -f "$REPO_ROOT/.env" ]; then
        log_step "Step 2/5: Setting up environment file"
        "$SCRIPT_DIR/../local/setup-env.sh" || exit 1
    else
        log_info "Step 2/5: .env file already exists, skipping"
    fi
    
    # Step 3: Build Docker images (optional)
    if [ "$SKIP_BUILD" = false ]; then
        log_step "Step 3/5: Building Docker images"
        "$SCRIPT_DIR/build-images.sh" || exit 1
    else
        log_info "Step 3/5: Skipping Docker image build (--skip-build flag set)"
    fi
    
    # Step 4: Build frontend (optional)
    if [ "$SKIP_FRONTEND" = false ]; then
        log_step "Step 4/5: Building frontend"
        # First ensure dependencies are installed
        if [ ! -d "$REPO_ROOT/frontend/node_modules" ]; then
            "$SCRIPT_DIR/../local/setup-frontend.sh" || exit 1
        fi
        "$SCRIPT_DIR/build-frontend.sh" || exit 1
    else
        log_info "Step 4/5: Skipping frontend build (--skip-frontend flag set)"
    fi
    
    # Step 5: Deploy services
    log_step "Step 5/5: Deploying services"
    "$SCRIPT_DIR/deploy.sh" || exit 1
    
    # Summary
    log_success "Local production simulation is deployed!"
    echo ""
    log_info "Services running:"
    log_info "  - Database: localhost:5432"
    log_info "  - API: http://localhost:5000"
    if [ "$SKIP_FRONTEND" = false ]; then
        log_info "  - Frontend: Built in $REPO_ROOT/frontend/dist"
    fi
    echo ""
    
    # Run verification
    "$SCRIPT_DIR/post_run_verify.sh"
    
    # Show manual test hints
    echo ""
    "$SCRIPT_DIR/manual_test_hint.sh" "false"
}

# Run main function
main "$@"

