#!/bin/bash
# Main orchestrator script for local development setup
# This script sets up and starts the entire local development environment
# Usage: ./run.sh [options...]
#
# Options:
#   --container-type        → Container orchestrator type: kube (Kubernetes) or nonkube (Docker Compose, default)
#   --skip-frontend         → Skip frontend development server startup
#   --skip-data-load        → Skip loading data into database
#   --skip-data-lake        → Skip data-lake setup even if analytics scheduler is enabled
#   --preempt               → Destroy all local resources before setup (complete teardown and fresh rebuild)
#                             Executes Phase 0: Step 0.3 - calls teardown-resources-all.sh to:
#                             - Stop Docker services and frontend dev server (nonkube) or Kubernetes resources (kube)
#                             - Remove Delta tables
#                             - Clean up Docker resources (containers, volumes, images)
#                             Database is preserved by default (use --reset-db in teardown script for full reset)
#
# Data-Lake Setup Behavior:
#   - Automatic: Setup if ENABLE_ANALYTICS_SCHEDULER=true in .env file
#   - Use --skip-data-lake to override and skip setup even if analytics enabled
#   - Uses Docker Spark execution (Spark runs in Docker container)
#   - Runs in Phase 4: Step 4.1 if enabled

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/orchestration/shared/logger.sh"
source "$REPO_ROOT/orchestration/shared/performance-tracker.sh"
source "$REPO_ROOT/orchestration/shared/load-env.sh"
load_env_file || true
log_info "[debug] REPO_ROOT resolved to: $REPO_ROOT (local/run.sh)"

# Parse command line arguments
CONTAINER_TYPE="nonkube"  # Default: Docker Compose
SKIP_FRONTEND=false
SKIP_DATA_LOAD=false
SKIP_DATA_LAKE=false
PREEMPT=false
FORCE_REFRESH_DATA=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --container-type)
            if [ $# -ge 2 ]; then
                CONTAINER_TYPE="$2"
                if [[ "$CONTAINER_TYPE" != "kube" && "$CONTAINER_TYPE" != "nonkube" ]]; then
                    log_error "Invalid container type: $CONTAINER_TYPE (must be kube or nonkube)"
                    exit 1
                fi
                shift 2
            else
                log_error "--container-type requires a value (kube or nonkube)"
                exit 1
            fi
            ;;
        --skip-frontend)
            SKIP_FRONTEND=true
            shift
            ;;
        --skip-data-load)
            SKIP_DATA_LOAD=true
            shift
            ;;
        --skip-data-lake)
            SKIP_DATA_LAKE=true
            shift
            ;;
        --preempt)
            PREEMPT=true
            # When preempting, also force refresh data to ensure a clean local state
            FORCE_REFRESH_DATA=true
            shift
            ;;
        --force-refresh-data)
            FORCE_REFRESH_DATA=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            log_info "Usage: $0 [--container-type kube|nonkube] [--skip-frontend] [--skip-data-load] [--skip-data-lake] [--preempt] [--force-refresh-data]"
            exit 1
            ;;
    esac
done

# Export flags for sub-scripts
export FORCE_REFRESH_DATA CONTAINER_TYPE PREEMPT

# Determine if data-lake setup is needed (consistent with AWS)
# Priority order:
#   1. Explicit flag (--skip-data-lake) - highest priority, overrides auto-detection
#   2. Environment variable (ENABLE_ANALYTICS_SCHEDULER) - auto-detection
#   3. Default: Skip (analytics scheduler disabled)
should_setup_data_lake() {
    # If explicitly skipped, don't setup
    if [ "$SKIP_DATA_LAKE" = "true" ]; then
        return 1
    fi
    
    # Auto-detect: Check if analytics scheduler is enabled
    # Note: Environment variables are already loaded at script startup
    if [ "${ENABLE_ANALYTICS_SCHEDULER:-false}" = "true" ]; then
        return 0  # Analytics scheduler enabled, need Delta Lake
    fi
    
    # Default: Don't setup (analytics scheduler disabled)
    return 1
}


# Helper function to format elapsed time
format_elapsed_time() {
    local seconds=$1
    if [ "$seconds" -lt 60 ]; then
        echo "${seconds}s"
    elif [ "$seconds" -lt 3600 ]; then
        local mins=$((seconds / 60))
        local secs=$((seconds % 60))
        echo "${mins}m ${secs}s"
    else
        local hours=$((seconds / 3600))
        local mins=$(((seconds % 3600) / 60))
        local secs=$((seconds % 60))
        echo "${hours}h ${mins}m ${secs}s"
    fi
}

# Main setup function
# Handles Phase 0-6: Prerequisites → Preempt Teardown (optional) → Environment Preparation → Infrastructure Setup → Database Setup → Data Lake → Application Deployment → Verification
main() {
    # Record script start time
    local script_start_time=$(date +%s)
    log_step "Starting local development environment setup"
    
    # Initialize performance tracking
    perf_init
    
    # Calculate total steps (base: 10, +1 if preempt)
    local total_steps=10
    local current_step=1
    
    if [ "$PREEMPT" = "true" ]; then
        total_steps=$((total_steps + 1))  # Add preempt step
    fi
    
    # ============================================================================
    # Phase 0: Prerequisites and Setup
    # ============================================================================
    perf_phase_start 0 "Prerequisites and Setup"
    perf_step_start 0 "0.1" "Checking and installing prerequisites"
    local step_start_time=$(date +%s)
    log_step "Phase 0: Step 0.1 - Step ${current_step}/${total_steps}: Checking and installing prerequisites"
    if ! "$REPO_ROOT/run_scripts/main_application_scripts/common/prerequisites/check-and-install.sh" "local"; then
        local elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 0 "0.1" "FAILED" "Prerequisites check/installation failed"
        log_error "Phase 0: Step 0.1 - Step ${current_step}/${total_steps} FAILED: Prerequisites check/installation failed (took $(format_elapsed_time $elapsed))"
        exit 1
    fi
    local elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 0 "0.1" "SUCCESS" "Prerequisites check/installation completed"
    log_success "Phase 0: Step 0.1 - Step ${current_step}/${total_steps} PASSED: Prerequisites check/installation completed (took $(format_elapsed_time $elapsed))"
    current_step=$((current_step + 1))
    echo ""
    
    perf_step_start 0 "0.2" "Setting up environment file"
    step_start_time=$(date +%s)
    log_step "Phase 0: Step 0.2 - Step ${current_step}/${total_steps}: Setting up environment file"
    if ! "$SCRIPT_DIR/setup-env.sh"; then
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 0 "0.2" "FAILED" "Environment file setup failed"
        log_error "Phase 0: Step 0.2 - Step ${current_step}/${total_steps} FAILED: Environment file setup failed (took $(format_elapsed_time $elapsed))"
        exit 1
    fi
    elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 0 "0.2" "SUCCESS" "Environment file ready"
    log_success "Phase 0: Step 0.2 - Step ${current_step}/${total_steps} PASSED: Environment file ready (took $(format_elapsed_time $elapsed))"
    current_step=$((current_step + 1))
    echo ""
    
    # ============================================================================
    # Phase 0: Step 0.3 - Preempt: Destroy existing local resources before setup (if requested)
    # ============================================================================
    # If preempt is enabled, execute preempt teardown
    if [ "$PREEMPT" = "true" ]; then
        perf_step_start 0 "0.3" "Destroying existing local resources (PREEMPT)"
        step_start_time=$(date +%s)
        log_step "Phase 0: Step 0.3 - Step ${current_step}/${total_steps}: Destroying existing local resources (PREEMPT MODE)"
        log_warning "════════════════════════════════════════════════════════════════"
        log_warning "PREEMPT MODE: Complete Local Environment Destruction"
        log_warning "════════════════════════════════════════════════════════════════"
        log_info "This will DESTROY ALL local resources"
        log_info "Steps that will be performed:"
        log_info "  1. Stop Docker services and frontend dev server"
        log_info "  2. Remove Delta tables"
        log_info "  3. Clean up Docker resources"
        log_info ""
        if [ "${DRY_RUN:-false}" = "true" ]; then
            log_info "Mode: DRY-RUN (preview only, no actual destruction)"
        else
            log_warning "Mode: ACTUAL DESTRUCTION (all resources will be permanently deleted!)"
        fi
        echo ""
        
        local teardown_cmd="$SCRIPT_DIR/shared/resources_cleanup/teardown-resources-all.sh --container-type $CONTAINER_TYPE"
        if [ "${DRY_RUN:-false}" = "true" ]; then
            teardown_cmd="$teardown_cmd --clean-all --dry-run"
        else
            teardown_cmd="$teardown_cmd --clean-all --force"
        fi
        # Note: --clean-all ensures a full reset of local resources for preempt runs
        # (database data, Docker volumes, images, and build cache)
        
        if $teardown_cmd; then
            elapsed=$(( $(date +%s) - step_start_time ))
            perf_step_end 0 "0.3" "SUCCESS" "Local environment destruction completed"
            log_success "════════════════════════════════════════════════════════════════"
            log_success "Phase 0: Step 0.3 - Step ${current_step}/${total_steps} PASSED: Local environment destruction completed (took $(format_elapsed_time $elapsed))"
            log_success "════════════════════════════════════════════════════════════════"
            log_info "Preempt destruction summary:"
            log_info "  - All services stopped"
            log_info "  - All Delta tables removed"
            log_info "  - Docker resources cleaned up"
            log_info ""
            log_info "System is now ready for fresh setup"
            echo ""
            current_step=$((current_step + 1))
        else
            elapsed=$(( $(date +%s) - step_start_time ))
            perf_step_end 0 "0.3" "FAILED" "Preempt destruction failed"
            log_error "Phase 0: Step 0.3 - Step ${current_step}/${total_steps} FAILED: Preempt destruction failed (took $(format_elapsed_time $elapsed))"
            log_info "Check the destruction output above for details"
            exit 1
        fi
    fi
    perf_phase_end 0
    
    # ============================================================================
    # Phase 1: Environment Preparation
    # ============================================================================
    perf_phase_start 1 "Environment Preparation"
    perf_step_start 1 "1.1" "Setting up Python environment"
    step_start_time=$(date +%s)
    log_step "Phase 1: Step 1.1 - Step ${current_step}/${total_steps}: Setting up Python environment"
    if ! "$SCRIPT_DIR/setup-python.sh"; then
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 1 "1.1" "FAILED" "Python environment setup failed"
        log_error "Phase 1: Step 1.1 - Step ${current_step}/${total_steps} FAILED: Python environment setup failed (took $(format_elapsed_time $elapsed))"
        exit 1
    fi
    elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 1 "1.1" "SUCCESS" "Python environment ready"
    log_success "Phase 1: Step 1.1 - Step ${current_step}/${total_steps} PASSED: Python environment ready (took $(format_elapsed_time $elapsed))"
    current_step=$((current_step + 1))
    echo ""
    
    perf_step_start 1 "1.2" "Setting up frontend dependencies"
    step_start_time=$(date +%s)
    log_step "Phase 1: Step 1.2 - Step ${current_step}/${total_steps}: Setting up frontend dependencies"
    if ! "$SCRIPT_DIR/setup-frontend.sh"; then
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 1 "1.2" "FAILED" "Frontend dependencies setup failed"
        log_error "Phase 1: Step 1.2 - Step ${current_step}/${total_steps} FAILED: Frontend dependencies setup failed (took $(format_elapsed_time $elapsed))"
        exit 1
    fi
    elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 1 "1.2" "SUCCESS" "Frontend dependencies ready"
    log_success "Phase 1: Step 1.2 - Step ${current_step}/${total_steps} PASSED: Frontend dependencies ready (took $(format_elapsed_time $elapsed))"
    current_step=$((current_step + 1))
    echo ""
    perf_phase_end 1
    
    # ============================================================================
    # (Phase 1: Step 1.3 is for AWS deployments only)
    # ============================================================================
    
    # ============================================================================
    # Phase 2: Infrastructure Setup
    # ============================================================================
    perf_phase_start 2 "Infrastructure Setup"
    
    if [ "$CONTAINER_TYPE" = "kube" ]; then
        # Kubernetes path: Setup local K8s cluster and deploy
        perf_step_start 2 "2.1" "Setting up local Kubernetes cluster"
        step_start_time=$(date +%s)
        log_step "Phase 2: Step 2.1 - Step ${current_step}/${total_steps}: Setting up local Kubernetes cluster"
        
        # Default to minikube if not specified
        K8S_TYPE="${K8S_TYPE:-minikube}"
        export K8S_TYPE
        
        if ! "$REPO_ROOT/module_infra_kube/local/setup.sh" "$K8S_TYPE"; then
            elapsed=$(( $(date +%s) - step_start_time ))
            perf_step_end 2 "2.1" "FAILED" "Kubernetes cluster setup failed"
            log_error "Phase 2: Step 2.1 - Step ${current_step}/${total_steps} FAILED: Kubernetes cluster setup failed (took $(format_elapsed_time $elapsed))"
            exit 1
        fi
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 2 "2.1" "SUCCESS" "Kubernetes cluster ready"
        log_success "Phase 2: Step 2.1 - Step ${current_step}/${total_steps} PASSED: Kubernetes cluster ready (took $(format_elapsed_time $elapsed))"
        current_step=$((current_step + 1))
        echo ""
        
        perf_step_start 2 "2.2" "Installing NGINX Ingress Controller"
        step_start_time=$(date +%s)
        log_step "Phase 2: Step 2.2 - Step ${current_step}/${total_steps}: Installing NGINX Ingress Controller"
        if ! "$REPO_ROOT/module_infra_kube/local/install-ingress.sh" "$K8S_TYPE"; then
            elapsed=$(( $(date +%s) - step_start_time ))
            perf_step_end 2 "2.2" "FAILED" "Ingress installation failed"
            log_error "Phase 2: Step 2.2 - Step ${current_step}/${total_steps} FAILED: Ingress installation failed (took $(format_elapsed_time $elapsed))"
            exit 1
        fi
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 2 "2.2" "SUCCESS" "Ingress controller installed"
        log_success "Phase 2: Step 2.2 - Step ${current_step}/${total_steps} PASSED: Ingress controller installed (took $(format_elapsed_time $elapsed))"
        current_step=$((current_step + 1))
        echo ""
        
        # Kubernetes deployment will happen in Phase 5
    else
        # Docker Compose path (nonkube - default)
        perf_step_start 2 "2.1" "Starting Docker services"
        step_start_time=$(date +%s)
        log_step "Phase 2: Step 2.1 - Step ${current_step}/${total_steps}: Starting Docker services"
        # Use --force to ensure containers are recreated with latest .env variables
        # In PREEMPT mode, also pass --build-api to force image rebuild after teardown.
        local start_cmd="$SCRIPT_DIR/start-services.sh --force"
        if [ "$PREEMPT" = "true" ]; then
            log_info "PREEMPT mode: Forcing API image rebuild via start-services.sh --build-api"
            start_cmd="$start_cmd --build-api"
        fi
        if ! $start_cmd; then
            elapsed=$(( $(date +%s) - step_start_time ))
            perf_step_end 2 "2.1" "FAILED" "Docker services startup failed"
            log_error "Phase 2: Step 2.1 - Step ${current_step}/${total_steps} FAILED: Docker services startup failed (took $(format_elapsed_time $elapsed))"
            exit 1
        fi
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 2 "2.1" "SUCCESS" "Docker services running"
        log_success "Phase 2: Step 2.1 - Step ${current_step}/${total_steps} PASSED: Docker services running (took $(format_elapsed_time $elapsed))"
        current_step=$((current_step + 1))
        echo ""
    fi
    perf_phase_end 2
    
    # ============================================================================
    # (Phase 2: Steps 2.2, 2.3 are for AWS deployments only)
    # ============================================================================
    
    # ============================================================================
    # Phase 3: Database Setup
    # ============================================================================
    perf_phase_start 3 "Database Setup"
    perf_step_start 3 "3.1" "Initializing database schema"
    step_start_time=$(date +%s)
    log_step "Phase 3: Step 3.1 - Step ${current_step}/${total_steps}: Initializing database schema"
    local schema_cmd="$REPO_ROOT/module_infra_db/common/database/init_schema.sh local"
    if [ "$FORCE_REFRESH_DATA" = "true" ]; then
        schema_cmd="$schema_cmd --force-refresh-data"
    fi
    if ! $schema_cmd; then
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 3 "3.1" "FAILED" "Database schema initialization failed"
        log_error "Phase 3: Step 3.1 - Step ${current_step}/${total_steps} FAILED: Database schema initialization failed (took $(format_elapsed_time $elapsed))"
        exit 1
    fi
    elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 3 "3.1" "SUCCESS" "Database schema initialized"
    log_success "Phase 3: Step 3.1 - Step ${current_step}/${total_steps} PASSED: Database schema initialized (took $(format_elapsed_time $elapsed))"
    current_step=$((current_step + 1))
    echo ""
    
    # Phase 3: Database Setup - Step 3.2: Load data into database (optional)
    if [ "$SKIP_DATA_LOAD" = false ]; then
        perf_step_start 3 "3.2" "Loading data into database"
        step_start_time=$(date +%s)
        log_step "Phase 3: Step 3.2 - Step ${current_step}/${total_steps}: Loading data into database"
        local load_cmd="$REPO_ROOT/module_infra_db/common/database/load_data.sh local"
        if [ "$FORCE_REFRESH_DATA" = "true" ]; then
            load_cmd="$load_cmd --force-refresh-data"
        fi
        if ! $load_cmd; then
            elapsed=$(( $(date +%s) - step_start_time ))
            perf_step_end 3 "3.2" "FAILED" "Data load failed"
            log_error "Phase 3: Step 3.2 - Step ${current_step}/${total_steps} FAILED: Data load failed (took $(format_elapsed_time $elapsed))"
            exit 1
        fi
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 3 "3.2" "SUCCESS" "Data loaded into database"
        log_success "Phase 3: Step 3.2 - Step ${current_step}/${total_steps} PASSED: Data loaded into database (took $(format_elapsed_time $elapsed))"
        current_step=$((current_step + 1))
        echo ""
    else
        perf_step_start 3 "3.2" "Loading data into database"
        perf_step_end 3 "3.2" "SKIPPED" "Data load skipped (--skip-data-load flag)"
        log_info "Skipping data load (--skip-data-load flag set)"
    fi
    perf_phase_end 3
    
    # ============================================================================
    # (Phase 3: Steps 3.3, 3.4 are for AWS deployments only)
    # ============================================================================
    
    # ============================================================================
    # Phase 4: Data Lake Setup
    # ============================================================================
    perf_phase_start 4 "Data Lake Setup"
    # Step 4.1: Setup data-lake [CONDITIONAL]
    # Delta Lake setup: ENABLE_ANALYTICS_SCHEDULER=true → auto-setup, or use --skip-data-lake to override
    # Uses Docker Spark execution (Spark runs inside fru_api container)
    if should_setup_data_lake; then
        perf_step_start 4 "4.1" "Setting up data-lake (Delta table using Docker Spark)"
        step_start_time=$(date +%s)
        log_step "Phase 4: Step 4.1 - Step ${current_step}/${total_steps}: Setting up data-lake (Delta table using Docker Spark)"
        log_info "Spark runs inside the Docker container (no local Spark installation needed)"
        local setup_cmd="$REPO_ROOT/module_infra_spark/local/delta-lake/setup-and-verify.sh"
        # Note: --preempt flag is already handled in Phase 0: Step 0.3 (teardown-resources-all.sh)
        # Delta tables were already removed if --preempt was set, so no need to pass it again
        if [ "$FORCE_REFRESH_DATA" = "true" ]; then
            setup_cmd="$setup_cmd --force-refresh-data"
        fi
        if ! $setup_cmd; then
            elapsed=$(( $(date +%s) - step_start_time ))
            perf_step_end 4 "4.1" "FAILED" "Data-lake setup had issues"
            log_warning "Phase 4: Step 4.1 - Step ${current_step}/${total_steps} had issues (application may still work without Delta tables) (took $(format_elapsed_time $elapsed))"
            log_info "You can run data-lake setup separately: $REPO_ROOT/module_infra_spark/local/delta-lake/setup-and-verify.sh"
        else
            elapsed=$(( $(date +%s) - step_start_time ))
            perf_step_end 4 "4.1" "SUCCESS" "Delta-lake ready"
            log_success "Phase 4: Step 4.1 - Step ${current_step}/${total_steps} PASSED: Delta-lake ready (took $(format_elapsed_time $elapsed))"
        fi
        current_step=$((current_step + 1))
        echo ""
    else
        perf_step_start 4 "4.1" "Setting up data-lake (Delta table using Docker Spark)"
        perf_step_end 4 "4.1" "SKIPPED" "Delta Lake setup skipped"
        log_info "Skipping Delta Lake setup (ENABLE_ANALYTICS_SCHEDULER=false or --skip-data-lake flag)"
    fi
    perf_phase_end 4
    
    # ============================================================================
    # Phase 5: Application Deployment
    # ============================================================================
    perf_phase_start 5 "Application Deployment"
    # ============================================================================
    # (Phase 5: Steps 5.1, 5.3 are for AWS deployments only)
    # ============================================================================
    
    if [ "$CONTAINER_TYPE" = "kube" ]; then
        # Step 5.1: Deploy application to Kubernetes
        perf_step_start 5 "5.1" "Deploying application to Kubernetes"
        step_start_time=$(date +%s)
        log_step "Phase 5: Step 5.1 - Step ${current_step}/${total_steps}: Deploying application to Kubernetes"
        
        if ! "$SCRIPT_DIR/deploy.sh" "${K8S_TYPE:-minikube}"; then
            elapsed=$(( $(date +%s) - step_start_time ))
            perf_step_end 5 "5.1" "FAILED" "Kubernetes deployment failed"
            log_error "Phase 5: Step 5.1 - Step ${current_step}/${total_steps} FAILED: Kubernetes deployment failed (took $(format_elapsed_time $elapsed))"
            exit 1
        fi
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 5 "5.1" "SUCCESS" "Application deployed to Kubernetes"
        log_success "Phase 5: Step 5.1 - Step ${current_step}/${total_steps} PASSED: Application deployed to Kubernetes (took $(format_elapsed_time $elapsed))"
        current_step=$((current_step + 1))
        echo ""
    fi
    
    # Step 5.2: Start frontend dev server (optional)
    # Note: For kube, frontend may be served via Ingress, but dev server can still run for hot-reload
    if [ "$SKIP_FRONTEND" = false ]; then
        perf_step_start 5 "5.2" "Starting frontend development server"
        step_start_time=$(date +%s)
        log_step "Phase 5: Step 5.2 - Step ${current_step}/${total_steps}: Starting frontend development server"
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
        cd "$REPO_ROOT/module_app_core/frontend"
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
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 5 "5.2" "SUCCESS" "Frontend development server started"
        log_success "Phase 5: Step 5.2 - Step ${current_step}/${total_steps} PASSED: Frontend development server started (took $(format_elapsed_time $elapsed))"
        current_step=$((current_step + 1))
        echo ""
    else
        perf_step_start 5 "5.2" "Starting frontend development server"
        perf_step_end 5 "5.2" "SKIPPED" "Frontend startup skipped (--skip-frontend flag)"
        log_info "To start the frontend, run:"
        log_info "  cd $REPO_ROOT/module_app_core/frontend && npm run dev"
        echo ""
        log_info "Or run: ./run_scripts/local/start-frontend.sh"
    fi
    perf_phase_end 5
    
    # ============================================================================
    # Phase 6: Validation and Verification
    # ============================================================================
    perf_phase_start 6 "Validation and Verification"
    # Step 6.1: Post-deployment verification
    perf_step_start 6 "6.1" "Verifying deployment and generating test instructions"
    step_start_time=$(date +%s)
    log_step "Phase 6: Step 6.1 - Step ${current_step}/${total_steps}: Verifying deployment and generating test instructions"
    echo ""
    if "$SCRIPT_DIR/verification/auto_verify_and_manual_hint.sh" "false"; then
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 6 "6.1" "SUCCESS" "Verification completed"
        log_success "Phase 6: Step 6.1 - Step ${current_step}/${total_steps} PASSED: Verification completed (took $(format_elapsed_time $elapsed))"
    else
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 6 "6.1" "FAILED" "Verification had issues"
        log_warning "Phase 6: Step 6.1 - Step ${current_step}/${total_steps} had issues (deployment may still be successful) (took $(format_elapsed_time $elapsed))"
        log_info "Check the verification output above for details"
    fi
    current_step=$((current_step + 1))
    echo ""
    perf_phase_end 6
    
    # Remove trap before printing summary (to avoid duplicate output)
    trap - EXIT
    
    # Log total script execution time and print performance summary
    local total_elapsed=$(( $(date +%s) - script_start_time ))
    echo ""
    log_success "═══════════════════════════════════════════════════════════════════════════════"
    log_success "Local development environment setup completed successfully!"
    log_success "Total execution time: $(format_elapsed_time $total_elapsed)"
    log_success "═══════════════════════════════════════════════════════════════════════════════"
    
    # Print performance summary and statistics
    perf_print_summary
    perf_print_statistics
}

# Run main function
main "$@"

