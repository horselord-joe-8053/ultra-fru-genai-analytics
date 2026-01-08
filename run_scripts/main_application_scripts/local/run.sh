#!/bin/bash
# Main orchestrator script for local development setup
# This script sets up and starts the entire local development environment
# Usage: ./run.sh [options...]
#
# Options:
#   --skip-frontend         → Skip frontend development server startup
#   --skip-data-load        → Skip loading data into database
#   --setup-spark           → Force setup of Spark locally (even if not needed)
#   --skip-spark            → Skip Spark setup (Spark runs in Docker anyway)
#   --setup-data-lake       → Force setup of data-lake (Delta table) even if analytics disabled
#   --skip-data-lake        → Skip data-lake setup even if analytics scheduler is enabled
#
# Data-Lake Setup Behavior:
#   - Automatic: Setup if ENABLE_ANALYTICS_SCHEDULER=true in .env file
#   - Flags override automatic detection (--setup-data-lake or --skip-data-lake)
#   - When called from this script, uses full-workflow mode (comprehensive setup)
#   - Runs in Step 7.5/8 if enabled (combined with optional Spark setup)
#
# Practical Examples:
#
#   # Basic setup (all defaults)
#   ./run.sh                               # Full setup including data-lake if analytics enabled
#
#   # With analytics enabled (in .env: ENABLE_ANALYTICS_SCHEDULER=true)
#   ./run.sh                               # Delta-lake will be set up automatically in Step 7.5
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
SETUP_SPARK=false
SKIP_SPARK=false
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
        --setup-spark)
            SETUP_SPARK=true
            shift
            ;;
        --skip-spark)
            SKIP_SPARK=true
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
            log_info "Usage: $0 [--skip-frontend] [--skip-data-load] [--setup-spark] [--skip-spark] [--setup-data-lake] [--skip-data-lake]"
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
    # Note: Environment variables are already loaded at script startup
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
    "$REPO_ROOT/run_scripts/main_application_scripts/common/check-dependencies.sh" || exit 1
    
    # Step 2: Setup .env file
    log_step "Step 2/8: Setting up environment file"
    "$SCRIPT_DIR/setup-env.sh" || exit 1
    
    # Step 3: Setup Python environment
    log_step "Step 3/8: Setting up Python environment"
    "$SCRIPT_DIR/setup-python.sh" || exit 1
    
    # Step 4: Setup frontend dependencies
    log_step "Step 4/8: Setting up frontend dependencies"
    "$SCRIPT_DIR/setup-frontend.sh" || exit 1
    
    # Step 5: Start Docker services
    # Use --force to ensure containers are recreated with latest .env variables
    log_step "Step 5/8: Starting Docker services"
    "$SCRIPT_DIR/start-services.sh" --force || exit 1
    
    # Step 6: Initialize database
    log_step "Step 6/8: Initializing database schema"
    "$REPO_ROOT/run_scripts/main_application_scripts/common/database/init_schema.sh" "local" || exit 1
    
    # Step 7: Load data (optional)
    if [ "$SKIP_DATA_LOAD" = false ]; then
        log_step "Step 7/8: Loading data into database"
        "$REPO_ROOT/run_scripts/main_application_scripts/common/database/load_data.sh" "local" || exit 1
    else
        log_info "Skipping data load (--skip-data-load flag set)"
    fi
    
    # Step 7.5: Setup Spark and data-lake (combined step)
    # This step combines:
    #   - Optional local Spark setup (for manual Spark job execution outside Docker)
    #   - Delta Lake setup (uses Docker Spark by default)
    # 
    # Spark setup (optional):
    #   - Only runs if --setup-spark flag is used or should_setup_spark() returns true
    #   - Local Spark is optional because Delta Lake setup uses Docker Spark
    #   - Use --setup-spark only if you want to run Spark jobs manually outside Docker
    #
    # Delta Lake setup (conditional):
    #   - Executes if ENABLE_ANALYTICS_SCHEDULER=true in .env → Setup automatically
    #   - Or if --setup-data-lake flag → Force setup
    #   - Or if --skip-data-lake flag → Force skip
    #   - Uses Docker Spark execution (EXECUTION_METHOD="docker")
    if should_setup_spark || should_setup_data_lake; then
        log_step "Step 7.5/8: Setting up Spark and data-lake"
        
        # Part 1: Optional local Spark setup (for manual usage)
        if should_setup_spark; then
            log_info "Setting up Spark environment locally (optional - for manual Spark job execution)"
            if "$REPO_ROOT/run_scripts/spark_delta-lake_scripts/common/spark/setup-spark.sh" "local"; then
                # Validate Spark setup
                if command -v spark-submit >/dev/null 2>&1; then
                    if spark-submit --version 2>&1 | grep -qE "version 4\.0"; then
                        log_success "Spark 4.0.1 is configured and ready (for manual usage)"
                    else
                        log_warning "Spark is configured but version check failed"
                    fi
                else
                    log_info "Spark setup completed (spark-submit not in PATH, but this is optional)"
                fi
            else
                log_warning "Spark setup had issues (this is optional - Delta Lake setup uses Docker Spark)"
            fi
        else
            log_info "Skipping local Spark setup (Spark runs in Docker container)"
            log_info "The fru_api container includes Spark 4.0.1, so local Spark is not needed for Delta Lake setup"
            log_info "Use --setup-spark only if you want to run Spark jobs manually outside Docker"
        fi
        
        # Part 2: Delta Lake setup (uses Docker Spark)
        if should_setup_data_lake; then
            log_info "Setting up data-lake (Delta table) using Docker Spark"
            if ! "$REPO_ROOT/run_scripts/spark_delta-lake_scripts/local/delta-lake/setup-and-verify.sh"; then
                log_warning "Delta-lake setup had issues (application may still work without Delta tables)"
                log_info "You can run data-lake setup separately: $REPO_ROOT/run_scripts/spark_delta-lake_scripts/local/delta-lake/setup-and-verify.sh"
            else
                log_success "Delta Lake setup completed successfully"
            fi
        else
            log_info "Skipping Delta Lake setup (ENABLE_ANALYTICS_SCHEDULER=false or --skip-data-lake flag)"
        fi
    else
        log_info "Skipping Spark and data-lake setup"
        log_info "  - Local Spark: Not needed (Spark runs in Docker container)"
        log_info "  - Delta Lake: Skipped (ENABLE_ANALYTICS_SCHEDULER=false or --skip-data-lake flag)"
    fi 
    # Summary
    # Note: Environment variables (including LOCAL_SERVER_PORT) are already loaded at script startup
    log_success "Local development environment is ready!"
    echo ""
    log_info "Services running:"
    log_info "  - Database: localhost:5432"
    local server_port="${LOCAL_SERVER_PORT:-5000}"
    log_info "  - API: http://localhost:${server_port}"
    echo ""
    
    # Step 8: Start frontend in background (optional)
    if [ "$SKIP_FRONTEND" = false ]; then
        log_step "Step 8/8: Starting frontend development server"
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

