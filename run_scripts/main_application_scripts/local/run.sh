#!/bin/bash
# Main orchestrator script for local development setup
# This script sets up and starts the entire local development environment
# Usage: ./run.sh [options...]
#
# Options:
#   --skip-frontend         → Skip frontend development server startup
#   --skip-data-load        → Skip loading data into database
#   --setup-data-lake       → Force setup of data-lake (Delta table) even if analytics disabled
#   --skip-data-lake        → Skip data-lake setup even if analytics scheduler is enabled
#
# Data-Lake Setup Behavior:
#   - Automatic: Setup if ENABLE_ANALYTICS_SCHEDULER=true in .env file
#   - Flags override automatic detection (--setup-data-lake or --skip-data-lake)
#   - Uses Docker Spark execution (Spark runs in Docker container)
#   - Runs in Phase 4: Step 4.1 if enabled
#
# Practical Examples:
#
#   # Basic setup (all defaults)
#   ./run.sh                               # Full setup including data-lake if analytics enabled
#
#     # With analytics enabled (in .env: ENABLE_ANALYTICS_SCHEDULER=true)
  #   ./run.sh                               # Delta-lake will be set up automatically in Phase 4: Step 4.1
#
#   # Without analytics (in .env: ENABLE_ANALYTICS_SCHEDULER=false or unset)
#   ./run.sh                               # Delta-lake setup will be skipped
#
#   # Force data-lake setup (even if analytics disabled)
#   ./run.sh --setup-data-lake             # Force setup of data-lake
#
#   # Skip data-lake setup (even if analytics enabled)
#   ./run.sh --skip-data-lake              # Skip data-lake setup
#
#   # Combine flags
#   ./run.sh --skip-frontend --setup-data-lake    # Skip frontend, but include data-lake
#   ./run.sh --skip-data-load --skip-data-lake    # Skip data load and data-lake
#
# See DATA_LAKE_USAGE_GUIDE.md for detailed data-lake scenarios.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../shared/logger.sh"
source "$SCRIPT_DIR/../../shared/load-env.sh"
load_env_file || true
log_info "[debug] REPO_ROOT resolved to: $REPO_ROOT (local/run.sh)"

# Parse command line arguments
SKIP_FRONTEND=false
SKIP_DATA_LOAD=false
SKIP_DATA_LAKE=false
SETUP_DATA_LAKE=false

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
        --setup-data-lake)
            SETUP_DATA_LAKE=true
            shift
            ;;
        --skip-data-lake)
            SKIP_DATA_LAKE=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            log_info "Usage: $0 [--skip-frontend] [--skip-data-load] [--setup-data-lake] [--skip-data-lake]"
            exit 1
            ;;
    esac
done

# Determine if data-lake setup is needed (consistent with AWS)
# Priority order:
#   1. Explicit flags (--skip-data-lake or --setup-data-lake) - highest priority
#   2. Environment variable (ENABLE_ANALYTICS_SCHEDULER) - auto-detection
#   3. Default: Skip (analytics scheduler disabled)
should_setup_data_lake() {
    # If explicitly skipped, don't setup
    if [ "$SKIP_DATA_LAKE" = "true" ]; then
        return 1
    fi
    
    # If explicitly requested, do it
    if [ "$SETUP_DATA_LAKE" = "true" ]; then
        return 0
    fi
    
    # Auto-detect: Check if analytics scheduler is enabled
    # Note: Environment variables are already loaded at script startup
    if [ "${ENABLE_ANALYTICS_SCHEDULER:-false}" = "true" ]; then
        return 0  # Analytics scheduler enabled, need Delta Lake
    fi
    
    # Default: Don't setup (analytics scheduler disabled)
    return 1
}


# Main setup function
# Handles Phase 0-6: Prerequisites → Environment Preparation → Infrastructure Setup → Database Setup → Data Lake → Application Deployment → Verification
main() {
    log_step "Starting local development environment setup"
    
    # ============================================================================
    # Phase 0: Prerequisites and Setup
    # ============================================================================
    log_step "Phase 0: Step 0.1/9: Checking prerequisites"
    "$REPO_ROOT/run_scripts/main_application_scripts/common/check-dependencies.sh" || exit 1
    
    log_step "Phase 0: Step 0.2/9: Setting up environment file"
    "$SCRIPT_DIR/setup-env.sh" || exit 1
    
    # ============================================================================
    # Phase 1: Environment Preparation
    # ============================================================================
    log_step "Phase 1: Step 1.1/9: Setting up Python environment"
    "$SCRIPT_DIR/setup-python.sh" || exit 1
    
    log_step "Phase 1: Step 1.2/9: Setting up frontend dependencies"
    "$SCRIPT_DIR/setup-frontend.sh" || exit 1
    
    # ============================================================================
    # (Phase 1: Step 1.3 is for AWS deployments only)
    # ============================================================================
    
    # ============================================================================
    # Phase 2: Infrastructure Setup
    # ============================================================================
    log_step "Phase 2: Step 2.1/9: Starting Docker services"
    # Use --force to ensure containers are recreated with latest .env variables
    "$SCRIPT_DIR/start-services.sh" --force || exit 1
    
    # ============================================================================
    # (Phase 2: Steps 2.2, 2.3 are for AWS deployments only)
    # ============================================================================
    
    # ============================================================================
    # Phase 3: Database Setup
    # ============================================================================
    log_step "Phase 3: Step 3.1/9: Initializing database schema"
    "$REPO_ROOT/run_scripts/main_application_scripts/common/database/init_schema.sh" "local" || exit 1
    
    # Phase 3: Database Setup - Step 3.2: Load data into database (optional)
    if [ "$SKIP_DATA_LOAD" = false ]; then
        log_step "Phase 3: Step 3.2/9: Loading data into database"
        "$REPO_ROOT/run_scripts/main_application_scripts/common/database/load_data.sh" "local" || exit 1
    else
        log_info "Skipping data load (--skip-data-load flag set)"
    fi
    
    # ============================================================================
    # (Phase 3: Steps 3.3, 3.4 are for AWS deployments only)
    # ============================================================================
    
    # ============================================================================
    # Phase 4: Data Lake Setup
    # ============================================================================
    # Step 4.1: Setup data-lake [CONDITIONAL]
    # Delta Lake setup: ENABLE_ANALYTICS_SCHEDULER=true → auto-setup, or use --setup-data-lake/--skip-data-lake flags
    # Uses Docker Spark execution (Spark runs inside fru_api container)
    if should_setup_data_lake; then
        log_step "Phase 4: Step 4.1/9: Setting up data-lake (Delta table using Docker Spark)"
        log_info "Spark runs inside the Docker container (no local Spark installation needed)"
        if ! "$REPO_ROOT/run_scripts/spark_delta-lake_scripts/local/delta-lake/setup-and-verify.sh"; then
            log_warning "Delta-lake setup had issues (application may still work without Delta tables)"
            log_info "You can run data-lake setup separately: $REPO_ROOT/run_scripts/spark_delta-lake_scripts/local/delta-lake/setup-and-verify.sh"
        else
            log_success "Delta Lake setup completed successfully"
        fi
    else
        log_info "Skipping Delta Lake setup (ENABLE_ANALYTICS_SCHEDULER=false or --skip-data-lake flag)"
    fi
    
    # ============================================================================
    # Phase 5: Application Deployment
    # ============================================================================
    # Step 5.2: Start frontend dev server (optional)
    
    # ============================================================================
    # (Phase 5: Step 5.1 is for AWS deployments only)
    # ============================================================================
    
    if [ "$SKIP_FRONTEND" = false ]; then
        log_step "Phase 5: Step 5.2/9: Starting frontend development server"
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
    
    # ============================================================================
    # (Phase 5: Steps 5.1, 5.3 are for AWS deployments only)
    # ============================================================================
    
    # ============================================================================
    # Phase 6: Validation and Verification
    # ============================================================================
    # Step 6.1: Post-deployment verification
    # Note: Environment variables (including LOCAL_SERVER_PORT) are already loaded at script startup
    log_success "Local development environment is ready!"
    echo ""
    log_info "Services running:"
    log_info "  - Database: localhost:5432"
    local server_port="${LOCAL_SERVER_PORT:-5000}"
    log_info "  - API: http://localhost:${server_port}"
    echo ""
    
    log_step "Phase 6: Step 6.1/9: Running verification and generating test instructions"
    echo ""
    "$SCRIPT_DIR/verification/auto_verify_and_manual_hint.sh" "false"
}

# Run main function
main "$@"

