#!/bin/bash
# Build frontend for production
# Idempotent: npm run build is safe to run multiple times

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"

FRONTEND_DIR="$REPO_ROOT/frontend"

build_frontend() {
    log_step "Building frontend for production"
    
    if [ ! -d "$FRONTEND_DIR" ]; then
        log_error "Frontend directory not found at $FRONTEND_DIR"
        exit 1
    fi
    
    # Check if node_modules exists
    if [ ! -d "$FRONTEND_DIR/node_modules" ]; then
        log_error "Frontend dependencies not installed. Please run ../local/setup-frontend.sh first."
        exit 1
    fi
    
    cd "$FRONTEND_DIR"
    
    log_info "Building frontend (this may take a minute)..."
    npm run build
    
    if [ -d "dist" ]; then
        log_success "Frontend built successfully"
        log_info "Build output: $FRONTEND_DIR/dist"
    else
        log_error "Build failed - dist directory not found"
        exit 1
    fi
}

main() {
    build_frontend
}

main "$@"

