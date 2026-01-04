#!/bin/bash
# Main orchestrator script for local development setup
# This script sets up and starts the entire local development environment
# Usage: ./run.sh [--skip-frontend] [--skip-data-load] [--setup-spark] [--skip-spark]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"

# Parse command line arguments
SKIP_FRONTEND=false
SKIP_DATA_LOAD=false
SETUP_SPARK=false
SKIP_SPARK=false

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
        --setup-spark)
            SETUP_SPARK=true
            shift
            ;;
        --skip-spark)
            SKIP_SPARK=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            log_info "Usage: $0 [--skip-frontend] [--skip-data-load] [--setup-spark] [--skip-spark]"
            exit 1
            ;;
    esac
done

# Auto-detect if Spark setup is needed
should_setup_spark() {
    # If explicitly requested, do it
    if [ "$SETUP_SPARK" = true ]; then
        return 0
    fi
    
    # If explicitly skipped, don't do it
    if [ "$SKIP_SPARK" = true ]; then
        return 1
    fi
    
    # Auto-detect: Check if analytics scheduler is enabled
    source "$SCRIPT_DIR/../common/load-env.sh"
    load_env_file || true
    
    if [ "${ENABLE_ANALYTICS_SCHEDULER:-false}" = "true" ]; then
        # Scheduler is enabled, but Spark runs in Docker, so local setup is optional
        # Only suggest it if Delta table exists (user might want to run Spark locally)
        if [ -d "$REPO_ROOT/data/delta/fru_sales" ]; then
            return 0  # Delta table exists, user might want local Spark
        fi
    fi
    
    # Default: Don't setup Spark (it's optional, runs in Docker)
    return 1
}

# Main setup function
main() {
    log_step "Starting local development environment setup"
    
    # Step 1: Check prerequisites
    log_step "Step 1/8: Checking prerequisites"
    "$SCRIPT_DIR/../common/check-dependencies.sh" || exit 1
    
    # Step 2: Setup .env file
    log_step "Step 2/8: Setting up environment file"
    "$SCRIPT_DIR/setup-env.sh" || exit 1
    
    # Step 3: Setup Python environment
    log_step "Step 3/8: Setting up Python environment"
    "$SCRIPT_DIR/setup-python.sh" || exit 1
    
    # Step 3.5: Setup Spark environment (optional)
    if should_setup_spark; then
        log_step "Step 3.5/8: Setting up Spark environment (optional)"
        if "$SCRIPT_DIR/../common/spark/setup-spark.sh" "local"; then
            # Validate Spark setup
            if command -v spark-submit >/dev/null 2>&1; then
                if spark-submit --version 2>&1 | grep -qE "version 4\.0"; then
                    log_success "Spark 4.0.1 is configured and ready"
                else
                    log_warning "Spark is configured but version check failed"
                fi
            else
                log_info "Spark setup completed (spark-submit not in PATH, but this is optional)"
            fi
        else
            log_warning "Spark setup had issues (this is optional - Spark runs in Docker)"
        fi
    else
        log_info "Skipping Spark setup (Spark is already installed in the Docker container)"
        log_info "The fru_api container includes Spark 4.0.1, so local Spark is not needed"
        log_info "Use --setup-spark only if you want to run Spark jobs manually outside Docker"
    fi
    
    # Step 4: Setup frontend dependencies
    log_step "Step 4/8: Setting up frontend dependencies"
    "$SCRIPT_DIR/setup-frontend.sh" || exit 1
    
    # Step 5: Start Docker services
    # Use --force to ensure containers are recreated with latest .env variables
    log_step "Step 5/8: Starting Docker services"
    "$SCRIPT_DIR/start-services.sh" --force || exit 1
    
    # Step 6: Initialize database
    log_step "Step 6/8: Initializing database schema"
    "$SCRIPT_DIR/../common/database/init_schema.sh" "local" || exit 1
    
    # Step 7: Load data (optional)
    if [ "$SKIP_DATA_LOAD" = false ]; then
        log_step "Step 7/8: Loading data into database"
        "$SCRIPT_DIR/../common/database/load_data.sh" "local" || exit 1
    else
        log_info "Skipping data load (--skip-data-load flag set)"
    fi
    
    # Load .env to get LOCAL_SERVER_PORT
    source "$SCRIPT_DIR/../common/load-env.sh"
    load_env_file || true
    
    # Summary
    log_success "Local development environment is ready!"
    echo ""
    log_info "Services running:"
    log_info "  - Database: localhost:5432"
    local server_port="${LOCAL_SERVER_PORT:-5000}"
    log_info "  - API: http://localhost:${server_port}"
    echo ""
    
    # Start frontend in background (optional)
    if [ "$SKIP_FRONTEND" = false ]; then
        log_info "Starting frontend development server in background..."
        
        # Check if frontend is already running and kill it
        EXISTING_PID=$(lsof -Pi :5173 -sTCP:LISTEN -t 2>/dev/null || echo "")
        if [ -n "$EXISTING_PID" ]; then
            log_info "Found existing frontend process on port 5173 (PID: $EXISTING_PID)"
            log_info "Stopping existing frontend process..."
            kill "$EXISTING_PID" 2>/dev/null || true
            # Wait a moment for process to terminate
            sleep 2
            # Force kill if still running
            if kill -0 "$EXISTING_PID" 2>/dev/null; then
                log_warning "Process still running, force killing..."
                kill -9 "$EXISTING_PID" 2>/dev/null || true
                sleep 1
            fi
            log_success "Existing frontend process stopped"
        fi
        
        # Start frontend in background
        cd "$REPO_ROOT/frontend"
        nohup npm run dev > /tmp/frontend.log 2>&1 &
        FRONTEND_PID=$!
        log_info "Frontend starting in background (PID: $FRONTEND_PID)"
        log_info "Frontend will be available at: http://localhost:5173"
        log_info "Frontend logs: tail -f /tmp/frontend.log"
        log_info "To stop frontend: kill $FRONTEND_PID"
        
        # Wait a moment for frontend to start
        log_info "Waiting for frontend to start..."
        sleep 5
        echo ""
    else
        log_info "To start the frontend, run:"
        log_info "  cd $REPO_ROOT/frontend && npm run dev"
        echo ""
        log_info "Or run: ./run_scripts/local/start-frontend.sh"
    fi
    
    # Run verification and show manual test hints (after frontend starts)
    echo ""
    "$SCRIPT_DIR/verification/auto_verify_and_manual_hint.sh" "false"
}

# Run main function
main "$@"

