#!/bin/bash
# Setup frontend dependencies (npm install)
# Idempotent: npm install is safe to run multiple times

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"

FRONTEND_DIR="$REPO_ROOT/frontend"

setup_frontend() {
    log_step "Setting up frontend dependencies"
    
    if [ ! -d "$FRONTEND_DIR" ]; then
        log_error "Frontend directory not found at $FRONTEND_DIR"
        exit 1
    fi
    
    cd "$FRONTEND_DIR"
    
    # Check if node_modules exists (quick check)
    if [ -d "node_modules" ] && [ -f "package-lock.json" ]; then
        log_info "node_modules exists, checking if dependencies are up to date..."
        # npm ci would be more strict, but npm install is more forgiving
        npm install --silent
        log_success "Frontend dependencies are up to date"
    else
        log_info "Installing frontend dependencies..."
        npm install
        log_success "Frontend dependencies installed"
    fi
}

main() {
    setup_frontend
}

main "$@"

