#!/bin/bash
# Common deployment phases for both ECS and EKS
# Usage: Source this file and call the phase functions
#
# These functions extract common logic from deploy_ecs_full() and deploy_eks_full()
# to reduce code duplication and improve maintainability.

# Source progress indicator if available
echo "[DEBUG] container-deploy-common.sh: Starting to source progress-indicator.sh at $(date)" >&2
SCRIPT_DIR_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_COMMON="${REPO_ROOT:-$(cd "$SCRIPT_DIR_COMMON/../../.." && pwd)}"
echo "[DEBUG] container-deploy-common.sh: SCRIPT_DIR_COMMON=$SCRIPT_DIR_COMMON, REPO_ROOT_COMMON=$REPO_ROOT_COMMON" >&2
if [ -f "$REPO_ROOT_COMMON/orchestration/common/feedback/progress-indicator.sh" ]; then
    echo "[DEBUG] container-deploy-common.sh: Found progress-indicator.sh, sourcing..." >&2
    source "$REPO_ROOT_COMMON/orchestration/common/feedback/progress-indicator.sh"
    echo "[DEBUG] container-deploy-common.sh: progress-indicator.sh sourced successfully" >&2
else
    echo "[DEBUG] container-deploy-common.sh: progress-indicator.sh not found at $REPO_ROOT_COMMON/orchestration/common/feedback/progress-indicator.sh" >&2
fi
echo "[DEBUG] container-deploy-common.sh: Finished sourcing, continuing..." >&2

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

# Phase 1.3: Check/build container image
# Parameters: step_num (current step), total_steps (for logging)
# Returns: New step_num (incremented by 1) via echo
# Usage: step_num=$(deploy_phase_check_image "$step_num" "$total_steps")
deploy_phase_check_image() {
    # Log immediately when function is called (before any other operations)
    echo "[DEBUG] deploy_phase_check_image: FUNCTION CALLED at $(date)" >&2
    
    local step_num="$1"
    local total_steps="$2"
    
    log_info "[DEBUG] deploy_phase_check_image: Starting at $(date)" >&2
    log_info "[DEBUG] deploy_phase_check_image: step_num=$step_num, total_steps=$total_steps" >&2
    
    perf_phase_start 1 "Environment Preparation" >&2
    perf_step_start 1 "1.3" "Checking container image availability" >&2
    local step_start_time=$(date +%s)
    log_step "Phase 1: Step 1.3 - Step ${step_num}/${total_steps}: Checking container image availability" >&2
    log_info "Phase 1: Resolving image tag → checking ECR for existing image → if missing, building and pushing (Docker + ECR). Output below." >&2
    
    log_info "[DEBUG] deploy_phase_check_image: About to start progress indicator..." >&2
    # Start progress indicator for image check/build
    if command -v progress_heartbeat_start >/dev/null 2>&1; then
        log_info "[DEBUG] deploy_phase_check_image: Starting heartbeat..." >&2
        progress_heartbeat_start "Checking/building container image" 10 >&2
        log_info "[DEBUG] deploy_phase_check_image: Heartbeat started" >&2
    else
        log_info "[DEBUG] deploy_phase_check_image: progress_heartbeat_start not available" >&2
    fi
    
    log_info "[DEBUG] deploy_phase_check_image: About to call check_or_build_image..." >&2
    # Call check_or_build_image function (defined in run.sh when this is sourced)
    # Redirect all output from check_or_build_image to stderr to prevent interfering with return value
    local image_check_result=0
    local check_start=$(date +%s)
    if ! check_or_build_image >&2; then
        image_check_result=1
    fi
    local check_elapsed=$(( $(date +%s) - check_start ))
    log_info "[DEBUG] deploy_phase_check_image: check_or_build_image completed in ${check_elapsed}s, result=$image_check_result" >&2
    
    # Stop progress indicator
    if command -v progress_heartbeat_stop >/dev/null 2>&1; then
        log_info "[DEBUG] deploy_phase_check_image: Stopping heartbeat..." >&2
        progress_heartbeat_stop >&2
    fi
    
    if [ "$image_check_result" -ne 0 ]; then
        local elapsed=$(( $(date +%s) - step_start_time ))
        log_error "Phase 1: Step 1.3 - Step ${step_num}/${total_steps} FAILED: Container image check/build failed (took $(format_elapsed_time $elapsed))"
        log_info "Reason: Unable to check ECR for existing image or build/push new image"
        log_info "Check AWS credentials, ECR permissions, and Docker availability"
        exit 1
    fi
    
    local elapsed=$(( $(date +%s) - step_start_time ))
    log_success "Phase 1: Step 1.3 - Step ${step_num}/${total_steps} PASSED: Container image ready (took $(format_elapsed_time $elapsed))" >&2
    
    # Return incremented step number (to stdout, separate from log output)
    echo $((step_num + 1))
}

# Phase 2.2: Setup Terraform state bucket
# Parameters: step_num, total_steps, script_dir
# Returns: New step_num (incremented by 1) via echo
deploy_phase_setup_state_bucket() {
    local step_num="$1"
    local total_steps="$2"
    local script_dir="${3:-${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
    
    local step_start_time=$(date +%s)
    log_step "Phase 2: Step 2.2 - Step ${step_num}/${total_steps}: Setting up Terraform state bucket"
    
    # Start progress indicator
    if command -v progress_heartbeat_start >/dev/null 2>&1; then
        progress_heartbeat_start "Setting up Terraform state bucket" 10
    fi
    
    local bucket_setup_result=0
    if ! "$REPO_ROOT_COMMON/orchestration/terraform/setup-s3-bucket.sh"; then
        bucket_setup_result=1
    fi
    
    # Stop progress indicator
    if command -v progress_heartbeat_stop >/dev/null 2>&1; then
        progress_heartbeat_stop
    fi
    
    if [ "$bucket_setup_result" -ne 0 ]; then
        local elapsed=$(( $(date +%s) - step_start_time ))
        log_error "Phase 2: Step 2.2 - Step ${step_num}/${total_steps} FAILED: Terraform state bucket setup failed (took $(format_elapsed_time $elapsed))"
        log_info "Reason: Unable to create or configure S3 bucket for Terraform state"
        log_info "Check AWS credentials, S3 permissions, and TF_STATE_BUCKET in .env"
        exit 1
    fi
    
    local elapsed=$(( $(date +%s) - step_start_time ))
    log_success "Phase 2: Step 2.2 - Step ${step_num}/${total_steps} PASSED: Terraform state bucket ready (took $(format_elapsed_time $elapsed))"
    
    echo $((step_num + 1))
}

# Phase 2.3: Deploy infrastructure layer
# Parameters: step_num, total_steps, script_dir, environment
# Returns: New step_num (incremented by 1) via echo
deploy_phase_deploy_infrastructure() {
    local step_num="$1"
    local total_steps="$2"
    local script_dir="${3:-${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
    local environment="${4:-${ENVIRONMENT:-dev}}"
    
    local step_start_time=$(date +%s)
    log_step "Phase 2: Step 2.3 - Step ${step_num}/${total_steps}: Deploying infrastructure layer"
    
    # Start progress indicator for Terraform operations (can take a long time)
    if command -v progress_heartbeat_start >/dev/null 2>&1; then
        progress_heartbeat_start "Deploying infrastructure layer (Terraform)" 10
    fi
    
    local infra_deploy_result=0
    if ! "$REPO_ROOT_COMMON/orchestration/terraform/deploy.sh" "$environment" infrastructure; then
        infra_deploy_result=1
    fi
    
    # Stop progress indicator
    if command -v progress_heartbeat_stop >/dev/null 2>&1; then
        progress_heartbeat_stop
    fi
    
    if [ "$infra_deploy_result" -ne 0 ]; then
        local elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 2 "2.3" "FAILED" "Infrastructure deployment failed"
        log_error "Phase 2: Step 2.3 - Step ${step_num}/${total_steps} FAILED: Infrastructure deployment failed (took $(format_elapsed_time $elapsed))"
        log_info "Reason: Terraform plan or apply failed for infrastructure layer"
        log_info "Check Terraform configuration, AWS permissions, and plan output above"
        exit 1
    fi
    
    local elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 2 "2.3" "SUCCESS" "Infrastructure layer deployed"
    log_success "Phase 2: Step 2.3 - Step ${step_num}/${total_steps} PASSED: Infrastructure layer deployed (took $(format_elapsed_time $elapsed))"
    perf_phase_end 2
    
    echo $((step_num + 1))
}

# Phase 3: Setup database (ECS only - EKS uses Kubernetes manifests)
# Parameters: step_num, total_steps, script_dir, environment, force_refresh_data, dry_run
# Returns: New step_num (incremented by 2: 3.3 and 3.4) via echo
deploy_phase_setup_database() {
    local step_num="$1"
    local total_steps="$2"
    local script_dir="${3:-${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
    local environment="${4:-${ENVIRONMENT:-dev}}"
    local force_refresh_data="${5:-${FORCE_REFRESH_DATA:-false}}"
    local dry_run="${6:-${DRY_RUN:-false}}"
    
    perf_phase_start 3 "Database Setup"
    
    if [ "$dry_run" != "true" ]; then
        perf_step_start 3 "3.3" "Setting up database (pgvector, schema, data)"
        local step_start_time=$(date +%s)
        log_step "Phase 3: Step 3.3 - Step ${step_num}/${total_steps}: Setting up database (pgvector, schema, data)"
        
        local repo_root="${REPO_ROOT:-$REPO_ROOT_COMMON}"
        local db_setup_cmd="$repo_root/module_infra_db/aws/setup-database.sh $environment"
        if [ "$force_refresh_data" = "true" ]; then
            db_setup_cmd="$db_setup_cmd --force-refresh-data"
        fi
        
        if $db_setup_cmd; then
            local elapsed=$(( $(date +%s) - step_start_time ))
            perf_step_end 3 "3.3" "SUCCESS" "Database setup completed"
            log_success "Phase 3: Step 3.3 - Step ${step_num}/${total_steps} PASSED: Database setup completed (took $(format_elapsed_time $elapsed))"
        else
            local elapsed=$(( $(date +%s) - step_start_time ))
            perf_step_end 3 "3.3" "FAILED" "Database setup had issues"
            log_warning "Phase 3: Step 3.3 - Step ${step_num}/${total_steps} had issues (may already be set up) (took $(format_elapsed_time $elapsed))"
        fi
        step_num=$((step_num + 1))
        
        # Step 3.4: Validate infrastructure outputs
        perf_step_start 3 "3.4" "Validating infrastructure outputs"
        step_start_time=$(date +%s)
        log_step "Phase 3: Step 3.4 - Step ${step_num}/${total_steps}: Validating infrastructure outputs"
        
        if ! "$repo_root/module_infra_db/aws/validate-infra-outputs.sh" "$environment"; then
            local elapsed=$(( $(date +%s) - step_start_time ))
            perf_step_end 3 "3.4" "FAILED" "Infrastructure outputs validation failed"
            log_error "Phase 3: Step 3.4 - Step ${step_num}/${total_steps} FAILED: Infrastructure outputs validation failed (took $(format_elapsed_time $elapsed))"
            log_info "Reason: Required infrastructure outputs are missing"
            log_info "Fix infrastructure deployment issues before deploying application layer"
            exit 1
        fi
        
        local elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 3 "3.4" "SUCCESS" "Infrastructure outputs validated"
        log_success "Phase 3: Step 3.4 - Step ${step_num}/${total_steps} PASSED: Infrastructure outputs validated (took $(format_elapsed_time $elapsed))"
        step_num=$((step_num + 1))
    else
        perf_step_start 3 "3.3" "Setting up database (pgvector, schema, data)"
        perf_step_end 3 "3.3" "SKIPPED" "Database setup skipped (DRY-RUN)"
        log_info "[DRY-RUN] Skipping database setup"
    fi
    
    perf_phase_end 3
    
    echo "$step_num"
}

# Phase 4/5: Setup data lake (optional, conditional)
# Parameters: step_num, total_steps, repo_root, environment, preempt, force_refresh_data, dry_run, enable_analytics_scheduler, skip_data_lake
# Returns: New step_num (incremented by 1 if setup runs, unchanged if skipped) via echo
deploy_phase_setup_data_lake() {
    local step_num="$1"
    local total_steps="$2"
    local repo_root="${3:-${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)}}"
    local environment="${4:-${ENVIRONMENT:-dev}}"
    local preempt="${5:-${PREEMPT:-false}}"
    local force_refresh_data="${6:-${FORCE_REFRESH_DATA:-false}}"
    local dry_run="${7:-${DRY_RUN:-false}}"
    local enable_analytics_scheduler="${8:-${ENABLE_ANALYTICS_SCHEDULER:-false}}"
    local skip_data_lake="${9:-${SKIP_DATA_LAKE:-false}}"
    
    # Determine if data-lake setup is needed
    local should_setup=false
    if [ "$skip_data_lake" != "true" ] && [ "$enable_analytics_scheduler" = "true" ]; then
        should_setup=true
    fi
    
    perf_phase_start 5 "Data Lake Setup"
    
    if [ "$should_setup" = true ]; then
        perf_step_start 5 "5.1" "Setting up data-lake (S3 + Delta table)"
        local step_start_time=$(date +%s)
        log_step "Phase 5: Step 5.1 - Step ${step_num}/${total_steps}: Setting up data-lake (S3 + Delta table)"
        
        if [ "$dry_run" = "true" ]; then
            log_info "[DRY-RUN] Would run: $repo_root/module_infra_spark/aws/delta-lake/setup-and-verify.sh"
            if [ "$preempt" = "true" ]; then
                log_info "[DRY-RUN] Would pass --preempt flag to teardown Delta tables first"
            fi
        else
            export ENVIRONMENT="$environment"
            export DRY_RUN="$dry_run"
            local setup_cmd="$repo_root/module_infra_spark/aws/delta-lake/setup-and-verify.sh"
            if [ "$preempt" = "true" ]; then
                setup_cmd="$setup_cmd --preempt"
            fi
            if [ "$force_refresh_data" = "true" ]; then
                setup_cmd="$setup_cmd --force-refresh-data"
            fi
            
            if ! $setup_cmd; then
                local elapsed=$(( $(date +%s) - step_start_time ))
                # If analytics scheduler is enabled, Delta table is REQUIRED - fail fast
                if [ "$enable_analytics_scheduler" = "true" ]; then
                    perf_step_end 5 "5.1" "FAILED" "Delta-lake setup failed"
                    log_error "Phase 5: Step 5.1 - Step ${step_num}/${total_steps} FAILED: Delta-lake setup failed (took $(format_elapsed_time $elapsed))"
                    log_error "Reason: Delta table creation failed, but ENABLE_ANALYTICS_SCHEDULER=true requires Delta tables"
                    log_error "Analytics scheduler will not work without Delta tables - deployment cannot proceed"
                    log_info "Fix Delta table setup issues before continuing, or set ENABLE_ANALYTICS_SCHEDULER=false to skip"
                    log_info "You can run data-lake setup separately: $repo_root/module_infra_spark/aws/delta-lake/setup-and-verify.sh"
                    exit 1
                else
                    perf_step_end 5 "5.1" "FAILED" "Delta-lake setup had issues"
                    log_warning "Phase 5: Step 5.1 - Step ${step_num}/${total_steps} had issues (application may still work without Delta tables) (took $(format_elapsed_time $elapsed))"
                    log_info "You can run data-lake setup separately: $repo_root/module_infra_spark/aws/delta-lake/setup-and-verify.sh"
                fi
            else
                local elapsed=$(( $(date +%s) - step_start_time ))
                perf_step_end 5 "5.1" "SUCCESS" "Delta-lake ready"
                log_success "Phase 5: Step 5.1 - Step ${step_num}/${total_steps} PASSED: Delta-lake ready (took $(format_elapsed_time $elapsed))"
            fi
            step_num=$((step_num + 1))
        fi
    else
        perf_step_start 5 "5.1" "Setting up data-lake (S3 + Delta table)"
        perf_step_end 5 "5.1" "SKIPPED" "Data-lake setup skipped"
        log_info "Skipping data-lake setup (ENABLE_ANALYTICS_SCHEDULER=false or --skip-data-lake flag)"
    fi
    
    perf_phase_end 5
    
    echo "$step_num"
}

# Phase 5/6: Deploy frontend
# Parameters: step_num, total_steps, script_dir, environment
# Returns: New step_num (incremented by 1) via echo
deploy_phase_deploy_frontend() {
    local step_num="$1"
    local total_steps="$2"
    local script_dir="${3:-${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
    local environment="${4:-${ENVIRONMENT:-dev}}"
    
    perf_phase_start 6 "Frontend Deployment"
    perf_step_start 6 "6.1" "Deploying frontend to S3"
    local step_start_time=$(date +%s)
    log_step "Phase 6: Step 6.1 - Step ${step_num}/${total_steps}: Deploying frontend to S3"
    
    export ENVIRONMENT="$environment"
    if ! "$REPO_ROOT_COMMON/module_infra_basic/aws/deploy-frontend.sh"; then
        local elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 6 "6.1" "FAILED" "Frontend deployment failed"
        log_error "Phase 6: Step 6.1 - Step ${step_num}/${total_steps} FAILED: Frontend deployment failed (took $(format_elapsed_time $elapsed))"
        log_info "Reason: Failed to build frontend or sync to S3"
        log_info "Check frontend build, AWS credentials, S3 permissions, and Terraform outputs"
        exit 1
    fi
    
    local elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 6 "6.1" "SUCCESS" "Frontend deployed to S3"
    log_success "Phase 6: Step 6.1 - Step ${step_num}/${total_steps} PASSED: Frontend deployed to S3 (took $(format_elapsed_time $elapsed))"
    perf_phase_end 6
    
    echo $((step_num + 1))
}

