#!/bin/bash
# Start frontend development server
# Idempotent: checks if port is already in use

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
source "$REPO_ROOT/lib/logger.sh"

FRONTEND_DIR="$REPO_ROOT/module_app_core/frontend"
FRONTEND_PORT=5173

start_frontend() {
    log_step "Starting frontend development server"
    
    if [ ! -d "$FRONTEND_DIR" ]; then
        log_error "Frontend directory not found at $FRONTEND_DIR"
        exit 1
    fi
    
    # Check if node_modules exists
    if [ ! -d "$FRONTEND_DIR/node_modules" ]; then
        log_error "Frontend dependencies not installed. Please run setup-frontend.sh first."
        exit 1
    fi
    
    # Check if port is already in use
    if lsof -Pi :$FRONTEND_PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
        log_warning "Port $FRONTEND_PORT is already in use"
        log_info "Frontend may already be running. If not, stop the process using port $FRONTEND_PORT"
        return 0
    fi
    
    cd "$FRONTEND_DIR"
    
    log_info "Starting Vite dev server on port $FRONTEND_PORT..."
    log_info "Frontend will be available at: http://localhost:$FRONTEND_PORT"
    log_info "Press Ctrl+C to stop the server"
    
    # Start the dev server (this will block)
    npm run dev
}

main() {
    start_frontend
}

main "$@"

