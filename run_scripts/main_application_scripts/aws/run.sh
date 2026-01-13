#!/bin/bash
# Main AWS deployment orchestrator
# Orchestrates end-to-end deployment workflows for ECS, EKS, and Terraform
# Usage: ./run.sh [workflow] [environment] [options...]
#
# Default: ecs-full dev (complete ECS deployment to dev environment)
#
# Workflows:
#   ecs-full        → Complete ECS deployment (build image → setup infra → deploy app + verification)
#   eks-full        → Complete EKS deployment (build image → setup infra → deploy app + verification)
#   infrastructure  → Infrastructure only (via terraform/deploy.sh infrastructure: VPC, networking, DB, S3, ECS/EKS infra; no app rollout)
#
# Environment:
#   dev             → Development environment (default)
#   prod            → Production environment
#   If omitted, defaults to 'dev'
#
# Options:
#   --dry-run                → Preview changes without modifying AWS resources
#   --skip-data-lake         → Skip data-lake setup even if analytics scheduler is enabled
#   --preempt                → Destroy all AWS infrastructure before deployment (complete teardown and fresh rebuild)
#                              Executes Phase 0: Step 0.5 - calls teardown-resources.sh to:
#                              - Stop ECS/EKS services (scale to 0)
#                              - Empty S3 buckets
#                              - Destroy Terraform infrastructure
#                              - Clean up orphaned resources
#
# Data-Lake Setup Behavior:
#   - Automatic: Setup if ENABLE_ANALYTICS_SCHEDULER=true in .env file
#   - Idempotent: Setup scripts are safe to run multiple times (create-if-missing)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/performance-tracker.sh"
# Save SCRIPT_DIR before sourcing load-env.sh (which sets its own SCRIPT_DIR)
AWS_SCRIPT_DIR="$SCRIPT_DIR"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"
load_env_file || true
# Restore our SCRIPT_DIR and log resolved REPO_ROOT
SCRIPT_DIR="$AWS_SCRIPT_DIR"
log_info "[debug] REPO_ROOT resolved to: $REPO_ROOT (aws/run.sh)"

# ============================================================================
# DEFAULT VALUES (can be overridden via arguments or environment variables)
# ============================================================================
DEFAULT_DEPLOYMENT_TYPE="ecs-full"
DEFAULT_ENVIRONMENT="dev"
DEFAULT_AWS_REGION="us-east-1"
DEFAULT_ECR_REPO_NAME="fru-api"
DEFAULT_IMAGE_TAG="latest"

# ============================================================================
# Parse command-line arguments
# ============================================================================
# Initialize variables
DRY_RUN=false
SKIP_DATA_LAKE=false
PREEMPT=false
FORCE_REFRESH_DATA=false
REMAINING_ARGS=()

# First, extract flags if present
ARGS_TO_PARSE=()
for arg in "$@"; do
    if [ "$arg" = "--dry-run" ]; then
        DRY_RUN=true
    elif [ "$arg" = "--skip-data-lake" ]; then
        SKIP_DATA_LAKE=true
    elif [ "$arg" = "--preempt" ]; then
        PREEMPT=true
        # When preempting, also force refresh data resources to ensure a clean state
        FORCE_REFRESH_DATA=true
    elif [ "$arg" = "--force-refresh-data" ]; then
        FORCE_REFRESH_DATA=true
    else
        ARGS_TO_PARSE+=("$arg")
    fi
done

# Parse remaining arguments (matching original logic)
if [ ${#ARGS_TO_PARSE[@]} -eq 0 ]; then
    DEPLOYMENT_TYPE="$DEFAULT_DEPLOYMENT_TYPE"
    ENVIRONMENT="$DEFAULT_ENVIRONMENT"
elif [[ "${ARGS_TO_PARSE[0]}" =~ ^(ecs-full|eks-full|infrastructure|help|-h|--help)$ ]]; then
    DEPLOYMENT_TYPE="${ARGS_TO_PARSE[0]}"
    ENVIRONMENT="${ARGS_TO_PARSE[1]:-$DEFAULT_ENVIRONMENT}"
    REMAINING_ARGS=("${ARGS_TO_PARSE[@]:2}")
else
    # First arg might be environment (legacy support)
    DEPLOYMENT_TYPE="$DEFAULT_DEPLOYMENT_TYPE"
    ENVIRONMENT="${ARGS_TO_PARSE[0]:-$DEFAULT_ENVIRONMENT}"
    REMAINING_ARGS=("${ARGS_TO_PARSE[@]:1}")
fi

# Export flags for sub-scripts
export DRY_RUN SKIP_DATA_LAKE PREEMPT FORCE_REFRESH_DATA

# Show usage information
show_usage() {
    cat << EOF
${GREEN}AWS Deployment Orchestrator${NC}

${BLUE}Usage:${NC}
  $0 [workflow] [environment] [options...]

${BLUE}Workflows:${NC}
  ${GREEN}ecs-full${NC}        Complete ECS deployment
                              → Build container image
                              → Setup Terraform state bucket
                              → Deploy infrastructure (VPC, Aurora, IAM, Secrets)
                              → Deploy application (ECS, ALB, Frontend)

         ${GREEN}eks-full${NC}        Complete EKS deployment
                                   → Build container image
                                   → Setup Terraform state bucket
                                   → Deploy infrastructure (VPC, Aurora, IAM, Secrets)
                                   → Deploy EKS layer (EKS cluster, node groups, OIDC)
                                   → Configure kubectl
                                   → Deploy Kubernetes manifests

  ${GREEN}infrastructure${NC}  Infrastructure only
                              → Setup Terraform state bucket
                              → Deploy infrastructure (VPC, Aurora, IAM, Secrets)
                              → No application deployment

${BLUE}Environments:${NC}
  dev     Development environment (default: $DEFAULT_ENVIRONMENT)
  prod    Production environment

  ${BLUE}Options:${NC}
  ${GREEN}--dry-run${NC}          Preview changes without modifying AWS resources
  ${GREEN}--preempt${NC}          Destroy existing infrastructure before deployment (clean slate)
  ${GREEN}--skip-data-lake${NC}   Skip data-lake setup even if analytics scheduler is enabled
  ${GREEN}--force-refresh-data${NC} Force refresh of data resources (database schema, data, Delta tables) without destroying infrastructure

${BLUE}Examples:${NC}
  ${GREEN}Basic Deployments:${NC}
  $0                                    # Default: $DEFAULT_DEPLOYMENT_TYPE to dev
  $0 ecs-full dev                      # Complete ECS deployment to dev
  $0 ecs-full                          # Same as above (dev is default)
  $0 eks-full prod                     # Complete EKS deployment to prod
  $0 infrastructure dev                # Infrastructure only to dev

  ${GREEN}Data-Lake Scenarios:${NC}
  # With analytics enabled in .env (ENABLE_ANALYTICS_SCHEDULER=true)
  $0 ecs-full dev                      # Delta-lake set up automatically in Phase 5: Step 5.1

  # With analytics disabled in .env (ENABLE_ANALYTICS_SCHEDULER=false)
  $0 ecs-full dev                      # Delta-lake setup skipped
  $0 ecs-full dev --skip-data-lake     # Force skip (even if analytics enabled)

  ${GREEN}Other Options:${NC}
  $0 ecs-full dev --dry-run            # Preview changes without deploying

${BLUE}Data-Lake Setup:${NC}
  The data-lake (S3 + Delta table) is automatically set up when:
  - ENABLE_ANALYTICS_SCHEDULER=true in .env file (default behavior)
  
  It is skipped when:
  - ENABLE_ANALYTICS_SCHEDULER=false or unset (default behavior)
  - Or --skip-data-lake flag is used (forces skip)
  
  When run from this script, data-lake setup uses full-workflow mode:
  - Comprehensive verification and setup
  - Ensures everything is properly configured
  - See DATA_LAKE_USAGE_GUIDE.md for detailed scenarios

${BLUE}Note:${NC}
  - All workflows are idempotent (safe to run multiple times)
  - Container image is checked/created automatically for *-full workflows
  - Infrastructure is shared between ECS and EKS deployments
  - Use --dry-run to preview changes without modifying AWS resources
EOF
}

# Determine if data-lake setup is needed (same rules as local run.sh)
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

# Check if container image exists in ECR (idempotent check)
# Purpose: Ensure image is available before Terraform deployment
# Strategy: Auto-generate unique tags (git SHA) so Terraform detects code changes
check_or_build_image() {
    log_step "Checking container image availability"
    
    # Note: Environment variables (including IMAGE_PREFIX) are already loaded at script startup
    # Use admin profile for infrastructure operations (ECR)
    AWS_PROFILE="${AWS_PROFILE:-admin}"
    
    # Generate CONTAINER_IMAGE using centralized function
    # For AWS deployments, this resolves IMAGE_PREFIX to actual ECR URI
    CONTAINER_IMAGE=$(resolve_container_image_for_aws)
    export CONTAINER_IMAGE
    
    # Extract ECR_REPO_URI and IMAGE_TAG for build-push-ecr.sh
    # These are needed for ECR operations (check existence, push, etc.)
    ECR_REPO_URI="${CONTAINER_IMAGE%%:*}"
    IMAGE_TAG="${CONTAINER_IMAGE##*:}"
    export ECR_REPO_URI IMAGE_TAG
    
    # Get ECR repository name and region for AWS CLI operations
    ECR_REPO_NAME="${ECR_REPO_NAME:-fru-api}"
    AWS_REGION="${AWS_REGION:-$DEFAULT_AWS_REGION}"
    
    # Check if image already exists in ECR
    log_info "Checking if container image exists in ECR: $CONTAINER_IMAGE"
    local image_check_output
    if image_check_output=$(aws ecr describe-images \
        --profile "$AWS_PROFILE" \
        --repository-name "$ECR_REPO_NAME" \
        --image-ids imageTag="$IMAGE_TAG" \
        --region "$AWS_REGION" 2>&1); then
        log_success "Container image already exists: $CONTAINER_IMAGE"
        # In PREEMPT mode we still want to rebuild the image to ensure a clean slate.
        if [ "$PREEMPT" = "true" ]; then
            log_info "PREEMPT mode: Will force rebuild existing image"
            export FORCE_REBUILD=true
            # Fall through to build-and-push logic below instead of returning early.
        else
            return 0
        fi
    else
        local image_check_exit=$?
        if echo "$image_check_output" | grep -q "ImageNotFoundException\|does not exist"; then
            log_info "Container image not found: $CONTAINER_IMAGE (will be built)"
        else
            log_error "Failed to check container image existence (exit code: $image_check_exit)"
            log_error "Error: $image_check_output"
            exit 1
        fi
    fi
    
    # Image doesn't exist (or PREEMPT requested), build and push it
    log_info "Building and pushing container image..."
    log_info "Image will be tagged as: $CONTAINER_IMAGE"
    
    # In PREEMPT mode, ensure FORCE_REBUILD is set so build-push-ecr.sh always rebuilds
    if [ "$PREEMPT" = "true" ]; then
        if [ "${FORCE_REBUILD:-false}" != "true" ]; then
            log_info "PREEMPT mode: Setting FORCE_REBUILD=true for container image build"
        fi
        export FORCE_REBUILD=true
    fi
    
    if "$SCRIPT_DIR/shared/build-push-ecr.sh"; then
        log_success "Container image built and pushed: $CONTAINER_IMAGE"
        log_info "This image URI will be used by Terraform to update the ECS task definition"
        log_info "Terraform will detect the change and trigger a new ECS deployment"
        return 0
    else
        log_error "Failed to build and push container image"
        return 1
    fi
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

# Complete ECS deployment workflow
# Handles Phase 1-7: Environment Preparation → Infrastructure Setup → Database Setup → Application Infrastructure → Data Lake → Frontend Deployment → Verification
# (Phase 0 is handled in main() above)
deploy_ecs_full() {
    local deploy_start_time=$(date +%s)
    log_step "Starting complete ECS deployment workflow"
    log_info "Environment: $ENVIRONMENT"
    
    # Get step information from main() (accounts for Phase 0 steps and preempt if enabled)
    local step_num="${CURRENT_STEP:-5}"  # Default to 5 (after Phase 0.1-0.4, or 0.5 if preempt)
    local total_steps="${TOTAL_STEPS:-13}"  # Default for ecs-full
    
    # ============================================================================
    # Phase 1: Environment Preparation - Step 1.3: Prepare container image
    # ============================================================================
    perf_phase_start 1 "Environment Preparation"
    perf_step_start 1 "1.3" "Checking container image availability"
    local step_start_time=$(date +%s)
    log_step "Phase 1: Step 1.3 - Step ${step_num}/${total_steps}: Checking container image availability"
    if ! check_or_build_image; then
        local elapsed=$(( $(date +%s) - step_start_time ))
        log_error "Phase 1: Step 1.3 - Step ${step_num}/${total_steps} FAILED: Container image check/build failed (took $(format_elapsed_time $elapsed))"
        log_info "Reason: Unable to check ECR for existing image or build/push new image"
        log_info "Check AWS credentials, ECR permissions, and Docker availability"
        exit 1
    fi
    local elapsed=$(( $(date +%s) - step_start_time ))
    log_success "Phase 1: Step 1.3 - Step ${step_num}/${total_steps} PASSED: Container image ready (took $(format_elapsed_time $elapsed))"
    step_num=$((step_num + 1))
    
    # ============================================================================
    # Phase 2: Infrastructure Setup
    # ============================================================================
    step_start_time=$(date +%s)
    log_step "Phase 2: Step 2.2 - Step ${step_num}/${total_steps}: Setting up Terraform state bucket"
    if ! "$SCRIPT_DIR/terraform/setup-s3-bucket.sh"; then
        elapsed=$(( $(date +%s) - step_start_time ))
        log_error "Phase 2: Step 2.2 - Step ${step_num}/${total_steps} FAILED: Terraform state bucket setup failed (took $(format_elapsed_time $elapsed))"
        log_info "Reason: Unable to create or configure S3 bucket for Terraform state"
        log_info "Check AWS credentials, S3 permissions, and TF_STATE_BUCKET in .env"
        exit 1
    fi
    elapsed=$(( $(date +%s) - step_start_time ))
    log_success "Phase 2: Step 2.2 - Step ${step_num}/${total_steps} PASSED: Terraform state bucket ready (took $(format_elapsed_time $elapsed))"
    step_num=$((step_num + 1))
    
    # ============================================================================
    # Phase 2: Infrastructure Setup - Step 2.3: Deploy infrastructure layer
    # ============================================================================
    step_start_time=$(date +%s)
    log_step "Phase 2: Step 2.3 - Step ${step_num}/${total_steps}: Deploying infrastructure layer"
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" infrastructure; then
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 2 "2.3" "FAILED" "Infrastructure deployment failed"
        log_error "Phase 2: Step 2.3 - Step ${step_num}/${total_steps} FAILED: Infrastructure deployment failed (took $(format_elapsed_time $elapsed))"
        log_info "Reason: Terraform plan or apply failed for infrastructure layer"
        log_info "Check Terraform configuration, AWS permissions, and plan output above"
        exit 1
    fi
    elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 2 "2.3" "SUCCESS" "Infrastructure layer deployed"
    log_success "Phase 2: Step 2.3 - Step ${step_num}/${total_steps} PASSED: Infrastructure layer deployed (took $(format_elapsed_time $elapsed))"
    step_num=$((step_num + 1))
    perf_phase_end 2

    # ============================================================================
    # Phase 3: Database Setup - Step 3.3: Setup database (includes 3.1, 3.2, pgvector)
    # ============================================================================
    perf_phase_start 3 "Database Setup"
    if [ "$DRY_RUN" != "true" ]; then
        perf_step_start 3 "3.3" "Setting up database (pgvector, schema, data)"
        step_start_time=$(date +%s)
        log_step "Phase 3: Step 3.3 - Step ${step_num}/${total_steps}: Setting up database (pgvector, schema, data)"
        local db_setup_cmd="$SCRIPT_DIR/database/setup-database.sh $ENVIRONMENT"
        if [ "$FORCE_REFRESH_DATA" = "true" ]; then
            db_setup_cmd="$db_setup_cmd --force-refresh-data"
        fi
        if $db_setup_cmd; then
            elapsed=$(( $(date +%s) - step_start_time ))
            perf_step_end 3 "3.3" "SUCCESS" "Database setup completed"
            log_success "Phase 3: Step 3.3 - Step ${step_num}/${total_steps} PASSED: Database setup completed (took $(format_elapsed_time $elapsed))"
        else
            elapsed=$(( $(date +%s) - step_start_time ))
            perf_step_end 3 "3.3" "FAILED" "Database setup had issues"
            log_warning "Phase 3: Step 3.3 - Step ${step_num}/${total_steps} had issues (may already be set up) (took $(format_elapsed_time $elapsed))"
        fi
        step_num=$((step_num + 1))
    else
        perf_step_start 3 "3.3" "Setting up database (pgvector, schema, data)"
        perf_step_end 3 "3.3" "SKIPPED" "Database setup skipped (DRY-RUN)"
        log_info "[DRY-RUN] Skipping database setup"
    fi
    
    # ============================================================================
    # Phase 3: Database Setup - Step 3.4: Validate infrastructure outputs
    # ============================================================================
    perf_step_start 3 "3.4" "Validating infrastructure outputs"
    step_start_time=$(date +%s)
    log_step "Phase 3: Step 3.4 - Step ${step_num}/${total_steps}: Validating infrastructure outputs"
    if ! "$SCRIPT_DIR/database/validate-infra-outputs.sh" "$ENVIRONMENT"; then
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 3 "3.4" "FAILED" "Infrastructure outputs validation failed"
        log_error "Phase 3: Step 3.4 - Step ${step_num}/${total_steps} FAILED: Infrastructure outputs validation failed (took $(format_elapsed_time $elapsed))"
        log_info "Reason: Required infrastructure outputs are missing"
        log_info "Fix infrastructure deployment issues before deploying application layer"
        exit 1
    fi
    elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 3 "3.4" "SUCCESS" "Infrastructure outputs validated"
    log_success "Phase 3: Step 3.4 - Step ${step_num}/${total_steps} PASSED: Infrastructure outputs validated (took $(format_elapsed_time $elapsed))"
    step_num=$((step_num + 1))
    perf_phase_end 3
    
    # ============================================================================
    # Phase 4: Application Infrastructure Deployment
    # ============================================================================
    perf_phase_start 4 "Application Infrastructure Deployment"
    perf_step_start 4 "4.1" "Deploying application infrastructure (ECS, ALB, CloudFront)"
    step_start_time=$(date +%s)
    log_step "Phase 4: Step 4.1 - Step ${step_num}/${total_steps}: Deploying application infrastructure (ECS, ALB, CloudFront)"
    log_info "Using container image: $CONTAINER_IMAGE"
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" application; then
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 4 "4.1" "FAILED" "Application infrastructure deployment failed"
        log_error "Phase 4: Step 4.1 - Step ${step_num}/${total_steps} FAILED: Application infrastructure deployment failed (took $(format_elapsed_time $elapsed))"
        log_info "Reason: Terraform plan or apply failed for application layer"
        log_info "Check Terraform configuration, AWS permissions, CONTAINER_IMAGE, and plan output above"
        exit 1
    fi
    elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 4 "4.1" "SUCCESS" "Application infrastructure deployed"
    log_success "Phase 4: Step 4.1 - Step ${step_num}/${total_steps} PASSED: Application infrastructure deployed (took $(format_elapsed_time $elapsed))"
    step_num=$((step_num + 1))
    perf_phase_end 4
    
    # ============================================================================
    # Phase 5: Data Lake Setup
    # ============================================================================
    perf_phase_start 5 "Data Lake Setup"
    # Step 5.1: Setup data-lake [CONDITIONAL]
    if should_setup_data_lake; then
        perf_step_start 5 "5.1" "Setting up data-lake (S3 + Delta table)"
        step_start_time=$(date +%s)
        log_step "Phase 5: Step 5.1 - Step ${step_num}/${total_steps}: Setting up data-lake (S3 + Delta table)"
        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY-RUN] Would run: $REPO_ROOT/run_scripts/spark_delta-lake_scripts/aws/delta-lake/setup-and-verify.sh"
            if [ "$PREEMPT" = "true" ]; then
                log_info "[DRY-RUN] Would pass --preempt flag to teardown Delta tables first"
            fi
        else
            export ENVIRONMENT="$ENVIRONMENT"
            export DRY_RUN="$DRY_RUN"
            local setup_cmd="$REPO_ROOT/run_scripts/spark_delta-lake_scripts/aws/delta-lake/setup-and-verify.sh"
            if [ "$PREEMPT" = "true" ]; then
                setup_cmd="$setup_cmd --preempt"
            fi
            if [ "$FORCE_REFRESH_DATA" = "true" ]; then
                setup_cmd="$setup_cmd --force-refresh-data"
            fi
            if ! $setup_cmd; then
                elapsed=$(( $(date +%s) - step_start_time ))
                # If analytics scheduler is enabled, Delta table is REQUIRED - fail fast
                if [ "${ENABLE_ANALYTICS_SCHEDULER:-false}" = "true" ]; then
                    perf_step_end 5 "5.1" "FAILED" "Delta-lake setup failed"
                    log_error "Phase 5: Step 5.1 - Step ${step_num}/${total_steps} FAILED: Delta-lake setup failed (took $(format_elapsed_time $elapsed))"
                    log_error "Reason: Delta table creation failed, but ENABLE_ANALYTICS_SCHEDULER=true requires Delta tables"
                    log_error "Analytics scheduler will not work without Delta tables - deployment cannot proceed"
                    log_info "Fix Delta table setup issues before continuing, or set ENABLE_ANALYTICS_SCHEDULER=false to skip"
                    log_info "You can run data-lake setup separately: $REPO_ROOT/run_scripts/spark_delta-lake_scripts/aws/delta-lake/setup-and-verify.sh"
                    exit 1
                else
                    perf_step_end 5 "5.1" "FAILED" "Delta-lake setup had issues"
                    log_warning "Phase 5: Step 5.1 - Step ${step_num}/${total_steps} had issues (application may still work without Delta tables) (took $(format_elapsed_time $elapsed))"
                    log_info "You can run data-lake setup separately: $REPO_ROOT/run_scripts/spark_delta-lake_scripts/aws/delta-lake/setup-and-verify.sh"
                fi
            else
                elapsed=$(( $(date +%s) - step_start_time ))
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
    
    # ============================================================================
    # Phase 6: Frontend Deployment
    # ============================================================================
    perf_phase_start 6 "Frontend Deployment"
    perf_step_start 6 "6.1" "Deploying frontend to S3"
    step_start_time=$(date +%s)
    log_step "Phase 6: Step 6.1 - Step ${step_num}/${total_steps}: Deploying frontend to S3"
    export ENVIRONMENT="$ENVIRONMENT"
    if ! "$SCRIPT_DIR/shared/deploy-frontend.sh"; then
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 6 "6.1" "FAILED" "Frontend deployment failed"
        log_error "Phase 6: Step 6.1 - Step ${step_num}/${total_steps} FAILED: Frontend deployment failed (took $(format_elapsed_time $elapsed))"
        log_info "Reason: Failed to build frontend or sync to S3"
        log_info "Check frontend build, AWS credentials, S3 permissions, and Terraform outputs"
        exit 1
    fi
    elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 6 "6.1" "SUCCESS" "Frontend deployed to S3"
    log_success "Phase 6: Step 6.1 - Step ${step_num}/${total_steps} PASSED: Frontend deployed to S3 (took $(format_elapsed_time $elapsed))"
    perf_phase_end 6
    
    # Export updated step number for Phase 7 in main()
    export CURRENT_STEP=$((step_num + 1))
    
    local total_elapsed=$(( $(date +%s) - deploy_start_time ))
    log_success "Complete ECS deployment finished successfully!"
    log_info "Your application should now be running on AWS ECS"
    log_info "Total deployment time: $(format_elapsed_time $total_elapsed)"
}

# Complete EKS deployment workflow
# Handles Phase 1-7: Environment Preparation → Infrastructure Setup → Data Lake → Application Deployment → Verification → Cleanup
# (Phase 0 is handled in main() above)
deploy_eks_full() {
    local deploy_start_time=$(date +%s)
    log_step "Starting complete EKS deployment workflow"
    log_info "Environment: $ENVIRONMENT"
    
    # Get step information from main() (accounts for Phase 0 steps and preempt if enabled)
    local step_num="${CURRENT_STEP:-5}"  # Default to 5 (after Phase 0.1-0.4, or 0.5 if preempt)
    local total_steps="${TOTAL_STEPS:-11}"  # Default for eks-full
    
    # ============================================================================
    # Phase 1: Environment Preparation - Step 1.3: Prepare container image
    # ============================================================================
    local step_start_time=$(date +%s)
    log_step "Phase 1: Step 1.3 - Step ${step_num}/${total_steps}: Checking container image availability"
    if ! check_or_build_image; then
        local elapsed=$(( $(date +%s) - step_start_time ))
        log_error "Phase 1: Step 1.3 - Step ${step_num}/${total_steps} FAILED: Container image check/build failed (took $(format_elapsed_time $elapsed))"
        log_info "Reason: Unable to check ECR for existing image or build/push new image"
        log_info "Check AWS credentials, ECR permissions, and Docker availability"
        exit 1
    fi
    local elapsed=$(( $(date +%s) - step_start_time ))
    log_success "Phase 1: Step 1.3 - Step ${step_num}/${total_steps} PASSED: Container image ready (took $(format_elapsed_time $elapsed))"
    step_num=$((step_num + 1))
    
    # ============================================================================
    # Phase 2: Infrastructure Setup
    # ============================================================================
    step_start_time=$(date +%s)
    log_step "Phase 2: Step 2.2 - Step ${step_num}/${total_steps}: Setting up Terraform state bucket"
    if ! "$SCRIPT_DIR/terraform/setup-s3-bucket.sh"; then
        elapsed=$(( $(date +%s) - step_start_time ))
        log_error "Phase 2: Step 2.2 - Step ${step_num}/${total_steps} FAILED: Terraform state bucket setup failed (took $(format_elapsed_time $elapsed))"
        log_info "Reason: Unable to create or configure S3 bucket for Terraform state"
        log_info "Check AWS credentials, S3 permissions, and TF_STATE_BUCKET in .env"
        exit 1
    fi
    elapsed=$(( $(date +%s) - step_start_time ))
    log_success "Phase 2: Step 2.2 - Step ${step_num}/${total_steps} PASSED: Terraform state bucket ready (took $(format_elapsed_time $elapsed))"
    step_num=$((step_num + 1))
    
    # ============================================================================
    # Phase 2: Infrastructure Setup - Step 2.3: Deploy infrastructure layer
    # ============================================================================
    step_start_time=$(date +%s)
    log_step "Phase 2: Step 2.3 - Step ${step_num}/${total_steps}: Deploying infrastructure layer"
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" infrastructure; then
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 2 "2.3" "FAILED" "Infrastructure deployment failed"
        log_error "Phase 2: Step 2.3 - Step ${step_num}/${total_steps} FAILED: Infrastructure deployment failed (took $(format_elapsed_time $elapsed))"
        log_info "Reason: Terraform plan or apply failed for infrastructure layer"
        log_info "Check Terraform configuration, AWS permissions, and plan output above"
        exit 1
    fi
    elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 2 "2.3" "SUCCESS" "Infrastructure layer deployed"
    log_success "Phase 2: Step 2.3 - Step ${step_num}/${total_steps} PASSED: Infrastructure layer deployed (took $(format_elapsed_time $elapsed))"
    step_num=$((step_num + 1))
    perf_phase_end 2
    
    # ============================================================================
    # (Phase 3: Database Setup is handled via Kubernetes manifests for EKS)
    # ============================================================================
    
    # ============================================================================
    # Phase 4: Data Lake Setup
    # ============================================================================
    perf_phase_start 4 "Data Lake Setup"
    # Step 4.1: Setup data-lake [CONDITIONAL]
    if should_setup_data_lake; then
        perf_step_start 4 "4.1" "Setting up data-lake (S3 + Delta table)"
        step_start_time=$(date +%s)
        log_step "Phase 4: Step 4.1 - Step ${step_num}/${total_steps}: Setting up data-lake (S3 + Delta table)"
        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY-RUN] Would run: $REPO_ROOT/run_scripts/spark_delta-lake_scripts/aws/delta-lake/setup-and-verify.sh"
            if [ "$PREEMPT" = "true" ]; then
                log_info "[DRY-RUN] Would pass --preempt flag to teardown Delta tables first"
            fi
        else
            export ENVIRONMENT="$ENVIRONMENT"
            export DRY_RUN="$DRY_RUN"
            local setup_cmd="$REPO_ROOT/run_scripts/spark_delta-lake_scripts/aws/delta-lake/setup-and-verify.sh"
            if [ "$PREEMPT" = "true" ]; then
                setup_cmd="$setup_cmd --preempt"
            fi
            if [ "$FORCE_REFRESH_DATA" = "true" ]; then
                setup_cmd="$setup_cmd --force-refresh-data"
            fi
            if ! $setup_cmd; then
                elapsed=$(( $(date +%s) - step_start_time ))
                # If analytics scheduler is enabled, Delta table is REQUIRED - fail fast
                if [ "${ENABLE_ANALYTICS_SCHEDULER:-false}" = "true" ]; then
                    perf_step_end 4 "4.1" "FAILED" "Delta-lake setup failed"
                    log_error "Phase 4: Step 4.1 - Step ${step_num}/${total_steps} FAILED: Delta-lake setup failed (took $(format_elapsed_time $elapsed))"
                    log_error "Reason: Delta table creation failed, but ENABLE_ANALYTICS_SCHEDULER=true requires Delta tables"
                    log_error "Analytics scheduler will not work without Delta tables - deployment cannot proceed"
                    log_info "Fix Delta table setup issues before continuing, or set ENABLE_ANALYTICS_SCHEDULER=false to skip"
                    log_info "You can run data-lake setup separately: $REPO_ROOT/run_scripts/spark_delta-lake_scripts/aws/delta-lake/setup-and-verify.sh"
                    exit 1
                else
                    perf_step_end 4 "4.1" "FAILED" "Delta-lake setup had issues"
                    log_warning "Phase 4: Step 4.1 - Step ${step_num}/${total_steps} had issues (application may still work without Delta tables) (took $(format_elapsed_time $elapsed))"
                    log_info "You can run data-lake setup separately: $REPO_ROOT/run_scripts/spark_delta-lake_scripts/aws/delta-lake/setup-and-verify.sh"
                fi
            else
                elapsed=$(( $(date +%s) - step_start_time ))
                perf_step_end 4 "4.1" "SUCCESS" "Delta-lake ready"
                log_success "Phase 4: Step 4.1 - Step ${step_num}/${total_steps} PASSED: Delta-lake ready (took $(format_elapsed_time $elapsed))"
            fi
            step_num=$((step_num + 1))
        fi
    else
        perf_step_start 4 "4.1" "Setting up data-lake (S3 + Delta table)"
        perf_step_end 4 "4.1" "SKIPPED" "Data-lake setup skipped"
        log_info "Skipping data-lake setup (ENABLE_ANALYTICS_SCHEDULER=false or --skip-data-lake flag)"
    fi
    perf_phase_end 4
    
    # ============================================================================
    # Phase 5: Application Deployment
    # ============================================================================
    perf_phase_start 5 "Application Deployment"
    # Step 5.1: Deploy EKS layer
    perf_step_start 5 "5.1" "Deploying EKS layer (EKS cluster, node groups, OIDC provider)"
    step_start_time=$(date +%s)
    log_step "Phase 5: Step 5.1 - Step ${step_num}/${total_steps}: Deploying EKS layer (EKS cluster, node groups, OIDC provider)"
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" eks; then
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 5 "5.1" "FAILED" "EKS layer deployment failed"
        log_error "Phase 5: Step 5.1 - Step ${step_num}/${total_steps} FAILED: EKS layer deployment failed (took $(format_elapsed_time $elapsed))"
        log_info "Reason: Terraform plan or apply failed for EKS layer"
        log_info "Check Terraform configuration, AWS permissions, EKS quotas, and plan output above"
        exit 1
    fi
    elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 5 "5.1" "SUCCESS" "EKS layer deployed"
    log_success "Phase 5: Step 5.1 - Step ${step_num}/${total_steps} PASSED: EKS layer deployed (took $(format_elapsed_time $elapsed))"
    step_num=$((step_num + 1))
    
    # ============================================================================
    # Phase 5: Application Deployment - Step 5.3: Deploy Kubernetes manifests
    # ============================================================================
    perf_step_start 5 "5.3" "Configuring kubectl and deploying Kubernetes manifests"
    step_start_time=$(date +%s)
    log_step "Phase 5: Step 5.3 - Step ${step_num}/${total_steps}: Configuring kubectl and deploying Kubernetes manifests"
    log_info "Using container image: $CONTAINER_IMAGE"
    
    # Get cluster name from Terraform output
    TERRAFORM_DIR="$REPO_ROOT/infra/terraform/environments"
    ENV_DIR="$TERRAFORM_DIR/$ENVIRONMENT"
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would configure kubectl and deploy Kubernetes manifests"
        log_info "[DRY-RUN] Would run: aws eks update-kubeconfig --region $AWS_REGION --name <cluster-name> --profile admin"
        log_info "[DRY-RUN] Would run: kubectl apply -f infra/k8s/"
    else
        # Configure kubectl
        log_info "Configuring kubectl for EKS cluster..."
        cd "$ENV_DIR/eks"
        log_info "Fetching Terraform output: cluster_name"
        if ! CLUSTER_NAME=$(terragrunt output -raw cluster_name 2>&1); then
            log_error "Failed to fetch Terraform output 'cluster_name'"
            log_error "Error: ${CLUSTER_NAME:0:500}"
            CLUSTER_NAME=""
            exit 1
        else
            log_info "Output retrieved: cluster_name=$CLUSTER_NAME"
        fi
        
        if [ -z "$CLUSTER_NAME" ]; then
            log_error "Failed to get EKS cluster name from Terraform output"
            log_info "Try running: cd $ENV_DIR/eks && terragrunt output"
            exit 1
        fi
        
        log_info "Cluster name: $CLUSTER_NAME"
        
        # Note: Environment variables (including AWS_REGION) are already loaded at script startup
        AWS_REGION="${AWS_REGION:-$DEFAULT_AWS_REGION}"
        if ! aws eks update-kubeconfig \
            --region "$AWS_REGION" \
            --name "$CLUSTER_NAME" \
            --profile admin; then
            log_error "Failed to configure kubectl"
            log_info "Check AWS credentials, EKS cluster status, and permissions"
            exit 1
        fi
        log_success "kubectl configured for cluster: $CLUSTER_NAME"
        
        # Deploy Kubernetes manifests
        if ! "$SCRIPT_DIR/eks/deploy.sh"; then
            elapsed=$(( $(date +%s) - step_start_time ))
            perf_step_end 5 "5.3" "FAILED" "Kubernetes manifest deployment failed"
            log_error "Phase 5: Step 5.3 - Step ${step_num}/${total_steps} FAILED: Kubernetes manifest deployment failed (took $(format_elapsed_time $elapsed))"
            log_info "Reason: Kubernetes manifest application or verification failed"
            log_info "Check Kubernetes manifests, EKS cluster status, and kubectl output above"
            exit 1
        fi
    fi
    elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 5 "5.3" "SUCCESS" "Kubernetes manifests deployed"
    log_success "Phase 5: Step 5.3 - Step ${step_num}/${total_steps} PASSED: Kubernetes manifests deployed (took $(format_elapsed_time $elapsed))"
    perf_phase_end 5
    
    # Export updated step number for Phase 7 in main()
    export CURRENT_STEP=$((step_num + 1))
    
    local total_elapsed=$(( $(date +%s) - deploy_start_time ))
    log_success "Complete EKS deployment finished successfully!"
    log_info "Your application should now be running on AWS EKS"
    log_info "Total deployment time: $(format_elapsed_time $total_elapsed)"
}

# Infrastructure only workflow
# Handles Phase 2: Infrastructure Setup only
# (Phase 0 is handled in main() above; Phases 1, 3-7 are skipped)
deploy_infrastructure() {
    local deploy_start_time=$(date +%s)
    log_step "Starting infrastructure deployment"
    log_info "Environment: $ENVIRONMENT"
    
    # ============================================================================
    # Phase 2: Infrastructure Setup
    # ============================================================================
    local step_start_time=$(date +%s)
    log_step "Phase 2: Step 2.2 - Step 1/2: Setting up Terraform state bucket"
    if ! "$SCRIPT_DIR/terraform/setup-s3-bucket.sh"; then
        local elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 2 "2.2" "FAILED" "Terraform state bucket setup failed"
        log_error "Phase 2: Step 2.2 - Step 1/2 FAILED: Terraform state bucket setup failed (took $(format_elapsed_time $elapsed))"
        log_info "Reason: Unable to create or configure S3 bucket for Terraform state"
        log_info "Check AWS credentials, S3 permissions, and TF_STATE_BUCKET in .env"
        exit 1
    fi
    local elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 2 "2.2" "SUCCESS" "Terraform state bucket ready"
    log_success "Phase 2: Step 2.2 - Step 1/2 PASSED: Terraform state bucket ready (took $(format_elapsed_time $elapsed))"
    
    # ============================================================================
    # Phase 2: Infrastructure Setup
    # ============================================================================
    # Step 2.3: Deploy infrastructure layer
    perf_step_start 2 "2.3" "Deploying infrastructure layer"
    step_start_time=$(date +%s)
    log_step "Phase 2: Step 2.3 - Step 2/2: Deploying infrastructure layer"
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" infrastructure; then
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 2 "2.3" "FAILED" "Infrastructure deployment failed"
        log_error "Phase 2: Step 2.3 - Step 2/2 FAILED: Infrastructure deployment failed (took $(format_elapsed_time $elapsed))"
        log_info "Reason: Terraform plan or apply failed for infrastructure layer"
        log_info "Check Terraform configuration, AWS permissions, and plan output above"
        exit 1
    fi
    elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 2 "2.3" "SUCCESS" "Infrastructure layer deployed"
    log_success "Phase 2: Step 2.3 - Step 2/2 PASSED: Infrastructure layer deployed (took $(format_elapsed_time $elapsed))"
    perf_phase_end 2
    
    local total_elapsed=$(( $(date +%s) - deploy_start_time ))
    log_success "Infrastructure deployment finished successfully!"
    log_info "Infrastructure is ready. Deploy application with: $0 ecs-full or $0 eks-full"
    log_info "Total deployment time: $(format_elapsed_time $total_elapsed)"
}

main() {
    # Handle help first (doesn't require AWS credentials)
    if [ "$DEPLOYMENT_TYPE" = "help" ] || [ "$DEPLOYMENT_TYPE" = "-h" ] || [ "$DEPLOYMENT_TYPE" = "--help" ]; then
        show_usage
        exit 0
    fi
    
    # Show dry-run banner if enabled
    if [ "$DRY_RUN" = "true" ]; then
        echo ""
        log_warning "=== DRY-RUN MODE ENABLED ==="
        log_info "No AWS resources will be created or modified"
        log_info "This is a preview of what would happen"
        echo ""
    fi
    
    # ============================================================================
    # Phase 0: Prerequisites and Setup
    # ============================================================================
    # Note: These steps are executed once for all workflows in main()
    # They correspond to Phase 0 steps in local/run.sh
    
    # Record script start time
    local script_start_time=$(date +%s)
    
    # Initialize performance tracking
    perf_init
    
    # Calculate total steps based on deployment type
    # Base steps: 4 (Phase 0.1-0.4) + deployment steps + 1 (Phase 7)
    local total_steps=13  # Default for ecs-full: 4 (Phase 0) + 8 (deploy) + 1 (Phase 7)
    local current_step=1  # Start at step 1
    
    if [ "$DEPLOYMENT_TYPE" = "eks-full" ]; then
        total_steps=11  # 4 (Phase 0) + 6 (deploy) + 1 (Phase 7)
    elif [ "$DEPLOYMENT_TYPE" = "infrastructure" ]; then
        total_steps=6  # 4 (Phase 0) + 2 (infrastructure only)
    fi
    
    # If preempt is enabled for full workflows, add 1 to total steps
    if [ "$PREEMPT" = "true" ] && ([ "$DEPLOYMENT_TYPE" = "ecs-full" ] || [ "$DEPLOYMENT_TYPE" = "eks-full" ]); then
        total_steps=$((total_steps + 1))  # Add preempt step to total
    fi
    
    # ============================================================================
    # Phase 0: Prerequisites and Setup
    # ============================================================================
    perf_phase_start 0 "Prerequisites and Setup"
    # Step 0.1: Check prerequisites / dependencies
    perf_step_start 0 "0.1" "Checking and installing prerequisites"
    local step_start_time=$(date +%s)
    log_step "Phase 0: Step 0.1 - Step ${current_step}/${total_steps}: Checking and installing prerequisites"
    if ! "$REPO_ROOT/run_scripts/main_application_scripts/common/prerequisites/check-and-install.sh" "aws"; then
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
    
    # Step 0.2: Setup Python virtual environment
    perf_step_start 0 "0.2" "Setting up Python environment"
    step_start_time=$(date +%s)
    log_step "Phase 0: Step 0.2 - Step ${current_step}/${total_steps}: Setting up Python environment"
    if ! "$REPO_ROOT/run_scripts/main_application_scripts/local/setup-python.sh"; then
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 0 "0.2" "FAILED" "Python environment setup failed"
        log_error "Phase 0: Step 0.2 - Step ${current_step}/${total_steps} FAILED: Python environment setup failed (took $(format_elapsed_time $elapsed))"
        exit 1
    fi
    elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 0 "0.2" "SUCCESS" "Python environment ready"
    log_success "Phase 0: Step 0.2 - Step ${current_step}/${total_steps} PASSED: Python environment ready (took $(format_elapsed_time $elapsed))"
    current_step=$((current_step + 1))
    echo ""
    
    # Step 0.3: Setup configuration files (AWS profiles from .env)
    # Note: AWS uses existing .env file, but sets up AWS profiles
    perf_step_start 0 "0.3" "Setting up AWS profiles from .env"
    step_start_time=$(date +%s)
    log_step "Phase 0: Step 0.3 - Step ${current_step}/${total_steps}: Setting up AWS profiles from .env"
    if ! "$SCRIPT_DIR/setup-aws-profiles.sh"; then
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 0 "0.3" "FAILED" "AWS profiles setup failed"
        log_error "Phase 0: Step 0.3 - Step ${current_step}/${total_steps} FAILED: AWS profiles setup failed (took $(format_elapsed_time $elapsed))"
        exit 1
    fi
    elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 0 "0.3" "SUCCESS" "AWS profiles setup completed"
    log_success "Phase 0: Step 0.3 - Step ${current_step}/${total_steps} PASSED: AWS profiles setup completed (took $(format_elapsed_time $elapsed))"
    current_step=$((current_step + 1))
    echo ""
    
    # Step 0.4: Check AWS credentials for actual deployments
    # This is AWS-specific and doesn't have a direct local equivalent
    perf_step_start 0 "0.4" "Checking AWS credentials"
    step_start_time=$(date +%s)
    log_step "Phase 0: Step 0.4 - Step ${current_step}/${total_steps}: Checking AWS credentials"
    if ! "$SCRIPT_DIR/check-aws-credentials.sh"; then
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 0 "0.4" "FAILED" "AWS credentials check failed"
        log_error "Phase 0: Step 0.4 - Step ${current_step}/${total_steps} FAILED: AWS credentials check failed (took $(format_elapsed_time $elapsed))"
        exit 1
    fi
    elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 0 "0.4" "SUCCESS" "AWS credentials validated"
    log_success "Phase 0: Step 0.4 - Step ${current_step}/${total_steps} PASSED: AWS credentials validated (took $(format_elapsed_time $elapsed))"
    
    # Export flag to skip redundant credential checks in child scripts
    export AWS_CREDENTIALS_CHECKED="true"
    log_info "AWS credentials validated - skipping redundant checks in child scripts"
    
    current_step=$((current_step + 1))
    echo ""
    
    # ============================================================================
    # Phase 0: Step 0.5 - Preempt: Destroy existing infrastructure before deployment (if requested)
    # ============================================================================
    # If preempt is enabled, execute preempt teardown
    if [ "$PREEMPT" = "true" ]; then
        if [ "$DEPLOYMENT_TYPE" = "ecs-full" ] || [ "$DEPLOYMENT_TYPE" = "eks-full" ]; then
            # Note: total_steps already includes preempt step from calculation above
            perf_step_start 0 "0.5" "Destroying existing infrastructure (PREEMPT)"
            step_start_time=$(date +%s)
            log_step "Phase 0: Step 0.5 - Step ${current_step}/${total_steps}: Destroying existing infrastructure (PREEMPT MODE)"
            log_warning "════════════════════════════════════════════════════════════════"
            log_warning "PREEMPT MODE: Complete Infrastructure Destruction"
            log_warning "════════════════════════════════════════════════════════════════"
            log_info "This will DESTROY ALL infrastructure for environment: $ENVIRONMENT"
            log_info "Steps that will be performed:"
            log_info "  1. Stop ECS/EKS services (scale to 0)"
            log_info "  2. Empty S3 buckets"
            log_info "  3. Destroy Terraform infrastructure"
            log_info "  4. Clean up orphaned resources"
            log_info ""
            if [ "$DRY_RUN" = "true" ]; then
                log_info "Mode: DRY-RUN (preview only, no actual destruction)"
            else
                log_warning "Mode: ACTUAL DESTRUCTION (all resources will be permanently deleted!)"
            fi
            echo ""
            
            # Verify environment is valid before destruction
            if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|prod)$ ]]; then
                log_error "Invalid environment for preempt: $ENVIRONMENT"
                log_info "Must be: dev, staging, or prod"
                exit 1
            fi
            
            local destroy_cmd="$SCRIPT_DIR/shared/resources_cleanup/teardown-resources.sh $ENVIRONMENT"
            # --dry-run and --force are NOT mutually exclusive
            # --dry-run: preview what would be destroyed
            # --force: skip confirmation prompts
            if [ "$DRY_RUN" = "true" ]; then
                destroy_cmd="$destroy_cmd --dry-run"
            fi
            if [ "$PREEMPT" = "true" ]; then
                # PREEMPT mode: skip confirmation and force destruction
                destroy_cmd="$destroy_cmd --force"
            fi
            
            if $destroy_cmd; then
                elapsed=$(( $(date +%s) - step_start_time ))
                perf_step_end 0 "0.5" "SUCCESS" "Infrastructure destruction completed"
                log_success "════════════════════════════════════════════════════════════════"
                log_success "Phase 0: Step 0.5 - Step ${current_step}/${total_steps} PASSED: Infrastructure destruction completed (took $(format_elapsed_time $elapsed))"
                log_success "════════════════════════════════════════════════════════════════"
                log_info "Preempt destruction summary:"
                log_info "  - All services stopped"
                log_info "  - All S3 buckets emptied"
                log_info "  - All Terraform resources destroyed"
                log_info "  - Orphaned resources cleaned up"
                log_info ""
                log_info "System is now ready for fresh deployment"
                echo ""
                current_step=$((current_step + 1))  # Increment for next step
            else
                elapsed=$(( $(date +%s) - step_start_time ))
                perf_step_end 0 "0.5" "FAILED" "Preempt destruction failed"
                log_error "Phase 0: Step 0.5 - Step ${current_step}/${total_steps} FAILED: Preempt destruction failed (took $(format_elapsed_time $elapsed))"
                log_info "Check the destruction output above for details"
                exit 1
            fi
        else
            log_warning "PREEMPT mode is only supported for full workflows (ecs-full, eks-full)"
            log_info "Skipping preempt destruction for deployment type: $DEPLOYMENT_TYPE"
            echo ""
        fi
    fi
    perf_phase_end 0
    
    # Export step information for use in deployment functions
    # Always export, even if preempt is not enabled (so deployment functions know the correct total)
    export CURRENT_STEP=$current_step
    export TOTAL_STEPS=$total_steps
    
    # ============================================================================
    # (Phase 1 - 6 are handled in the respective deployment functions)
    # ============================================================================
    
    # Handle deployment types
    case "$DEPLOYMENT_TYPE" in
        ecs-full)
            deploy_ecs_full
            echo ""
            ;;
        eks-full)
            deploy_eks_full
            echo ""
            ;;
        infrastructure)
            deploy_infrastructure
            echo ""
                ;;
            *)
            log_error "Unknown deployment type: $DEPLOYMENT_TYPE"
            echo ""
            show_usage
                exit 1
                ;;
        esac
    
    # ============================================================================
    # Phase 7: Validation and Verification
    # ============================================================================
    # Step 7.1: Post-deployment verification (full workflows only)
    # Note: Phase 7 only runs for full deployment workflows (ecs-full, eks-full)
    # Infrastructure-only and legacy workflows skip this phase
    if [ "$DEPLOYMENT_TYPE" = "ecs-full" ] || [ "$DEPLOYMENT_TYPE" = "eks-full" ]; then
        # Use step number from deployment function (accounts for Phase 0 and preempt)
        local step_num="${CURRENT_STEP:-13}"  # Default: after Phase 0 (4) + deploy (8) + 1 = 13
        local total_steps="${TOTAL_STEPS:-13}"  # Default for ecs-full
        if [ "$DEPLOYMENT_TYPE" = "eks-full" ]; then
            # Defaults for eks-full if not set
            step_num="${CURRENT_STEP:-11}"  # Default: after Phase 0 (4) + deploy (6) + 1 = 11
            total_steps="${TOTAL_STEPS:-11}"  # Default for eks-full
        fi
        perf_phase_start 7 "Validation and Verification"
        perf_step_start 7 "7.1" "Verifying deployment and generating test instructions"
        step_start_time=$(date +%s)
        log_step "Phase 7: Step 7.1 - Step ${step_num}/${total_steps}: Verifying deployment and generating test instructions"
        echo ""
        if "$SCRIPT_DIR/verification/auto_verify_and_manual_hint.sh" "$DEPLOYMENT_TYPE" "$ENVIRONMENT" "$DRY_RUN"; then
            elapsed=$(( $(date +%s) - step_start_time ))
            perf_step_end 7 "7.1" "SUCCESS" "Verification completed"
            log_success "Phase 7: Step 7.1 - Step ${step_num}/${total_steps} PASSED: Verification completed (took $(format_elapsed_time $elapsed))"
        else
            elapsed=$(( $(date +%s) - step_start_time ))
            perf_step_end 7 "7.1" "FAILED" "Verification had issues"
            log_warning "Phase 7: Step 7.1 - Step ${step_num}/${total_steps} had issues (deployment may still be successful) (took $(format_elapsed_time $elapsed))"
            log_info "Check the verification output above for details"
        fi
        perf_phase_end 7
    fi
    
    # Remove trap before printing summary (to avoid duplicate output)
    trap - EXIT
    
    # Log total script execution time and print performance summary
    local total_elapsed=$(( $(date +%s) - script_start_time ))
    echo ""
    log_success "═══════════════════════════════════════════════════════════════════════════════"
    log_success "AWS deployment completed successfully!"
    log_success "Total execution time: $(format_elapsed_time $total_elapsed)"
    log_success "═══════════════════════════════════════════════════════════════════════════════"
    
    # Print performance summary and statistics
    perf_print_summary
    perf_print_statistics
}

main "$@"
