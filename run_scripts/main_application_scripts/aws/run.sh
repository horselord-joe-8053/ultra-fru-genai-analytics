#!/bin/bash
# Main AWS deployment orchestrator
# Orchestrates end-to-end deployment workflows for ECS, EKS, and Terraform
#
# ============================================================================
# USAGE
# ============================================================================
# Basic Syntax:
#   ./run.sh deploy --container-type <ecs|eks> [environment] [options...]
#   ./run.sh infrastructure [environment] [options...]
#
# ============================================================================
# QUICK START EXAMPLES
# ============================================================================
# ECS Deployment (most common):
#   ./run.sh deploy --container-type ecs dev
#   ./run.sh deploy --container-type ecs dev --preempt
#
# EKS Deployment:
#   ./run.sh deploy --container-type eks dev
#   ./run.sh deploy --container-type eks dev --preempt
#
# Infrastructure Only (no application deployment):
#   ./run.sh infrastructure dev
#
# ============================================================================
# FULL COMMAND EXAMPLES
# ============================================================================
# Complete ECS deployment to dev (default environment):
#   ./run.sh deploy --container-type ecs dev
#
# Complete ECS deployment to prod:
#   ./run.sh deploy --container-type ecs prod
#
# Complete EKS deployment to dev:
#   ./run.sh deploy --container-type eks dev
#
# Complete EKS deployment to prod:
#   ./run.sh deploy --container-type eks prod
#
# Full teardown and fresh deployment (ECS dev):
#   ./run.sh deploy --container-type ecs dev --preempt
#
# Full teardown and fresh deployment (EKS dev):
#   ./run.sh deploy --container-type eks dev --preempt
#
# Preview changes without deploying (dry-run):
#   ./run.sh deploy --container-type ecs dev --dry-run
#   ./run.sh deploy --container-type eks dev --dry-run
#
# Deploy both ECS and EKS sequentially:
#   ./run.sh deploy --container-type ecs dev --all
#
# Infrastructure only (no application):
#   ./run.sh infrastructure dev
#   ./run.sh infrastructure prod
#
# ============================================================================
# WORKFLOWS
# ============================================================================
# deploy --container-type ecs
#   → Build container image
#   → Setup Terraform state bucket
#   → Deploy infrastructure (VPC, Aurora, IAM, Secrets)
#   → Deploy ECS application (ECS service, ALB, CloudFront)
#   → Run verification tests
#
# deploy --container-type eks
#   → Build container image
#   → Setup Terraform state bucket
#   → Deploy infrastructure (VPC, Aurora, IAM, Secrets)
#   → Deploy EKS layer (EKS cluster, node groups, OIDC provider)
#   → Configure kubectl
#   → Deploy Kubernetes manifests (Deployment, Service, Ingress)
#   → Run verification tests
#
# infrastructure
#   → Setup Terraform state bucket
#   → Deploy infrastructure (VPC, Aurora, IAM, Secrets, S3)
#   → No application deployment
#
# ============================================================================
# ENVIRONMENTS
# ============================================================================
# dev     → Development environment (default if omitted)
# prod    → Production environment
#
# ============================================================================
# OPTIONS
# ============================================================================
# --container-type <ecs|eks>
#   Required for 'deploy' command. Specifies container orchestration type.
#   - ecs: AWS ECS (Elastic Container Service)
#   - eks: AWS EKS (Elastic Kubernetes Service)
#
# --preempt
#   Destroy all existing AWS infrastructure before deployment (complete teardown).
#   Executes Phase 0: Step 0.5 - calls teardown-resources.sh to:
#   - Stop ECS/EKS services (scale to 0)
#   - Empty S3 buckets
#   - Destroy Terraform infrastructure
#   - Clean up orphaned resources
#   Use this for a completely fresh deployment from scratch.
#
# --dry-run
#   Preview changes without modifying AWS resources.
#   Shows what would be created/modified/destroyed without actually doing it.
#
# --skip-data-lake
#   Skip data-lake setup even if ENABLE_ANALYTICS_SCHEDULER=true in .env file.
#
# --force-refresh-data
#   Force refresh of data resources (database schema, data, Delta tables)
#   without destroying infrastructure.
#
# --all
#   Run deploy for both ecs and eks sequentially (only valid with 'deploy').
#   Cannot be combined with --preempt.
#
# ============================================================================
# DATA-LAKE SETUP BEHAVIOR
# ============================================================================
# - Automatic: Setup if ENABLE_ANALYTICS_SCHEDULER=true in .env file
# - Idempotent: Setup scripts are safe to run multiple times (create-if-missing)
# - Can be skipped with --skip-data-lake flag

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/performance-tracker.sh"
# Source progress indicator for heartbeat during long-running operations
if [ -f "$REPO_ROOT/run_scripts/shared/progress-indicator.sh" ]; then
    source "$REPO_ROOT/run_scripts/shared/progress-indicator.sh"
fi
# Save SCRIPT_DIR before sourcing load-env.sh (which sets its own SCRIPT_DIR)
AWS_SCRIPT_DIR="$SCRIPT_DIR"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"
load_env_file || true
# Restore our SCRIPT_DIR and log resolved REPO_ROOT
SCRIPT_DIR="$AWS_SCRIPT_DIR"
log_info "[debug] REPO_ROOT resolved to: $REPO_ROOT (aws/run.sh)"

# Load cloud provider image identifiers (AWS Account ID, ECR URI, CONTAINER_IMAGE, etc.)
# Unset any existing AWS_ACCOUNT_ID to ensure we resolve fresh from AWS STS
# (prevents stale dummy/test values from being used)
unset AWS_ACCOUNT_ID
source "$REPO_ROOT/run_scripts/shared/load-image-identifiers.sh"
load_image_identifiers "aws"

# Source shared deployment phases (common logic for ECS/EKS)
source "$SCRIPT_DIR/shared/container-deploy-common.sh"

# ============================================================================
# DEFAULT VALUES (can be overridden via arguments or environment variables)
# ============================================================================
DEFAULT_CONTAINER_TYPE="ecs"  # Default container type for AWS (ecs or eks)
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
RUN_ALL=false          # When true, run deploy for both ecs and eks sequentially
CONTAINER_TYPE=""
DEPLOY_COMMAND=""
REMAINING_ARGS=()

# First, extract flags and --container-type parameter
# Use shift-based parsing for bash 3.2 compatibility (macOS default)
ARGS_TO_PARSE=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
        DRY_RUN=true
            shift
            ;;
        --skip-data-lake)
        SKIP_DATA_LAKE=true
            shift
            ;;
        --preempt)
        PREEMPT=true
        FORCE_REFRESH_DATA=true
            shift
            ;;
        --force-refresh-data)
        FORCE_REFRESH_DATA=true
            shift
            ;;
        --all)
            # Run deploy for both ecs and eks. Only valid with 'deploy' command.
            RUN_ALL=true
            shift
            ;;
        --container-type)
            # Extract container type value
            if [ $# -ge 2 ]; then
                CONTAINER_TYPE="$2"
                # Validate container type for AWS provider
                if [[ "$CONTAINER_TYPE" != "ecs" && "$CONTAINER_TYPE" != "eks" ]]; then
                    log_error "Invalid container type for AWS: $CONTAINER_TYPE (must be ecs or eks)"
                    exit 1
                fi
                shift 2  # Skip both --container-type and its value
            else
                log_error "--container-type requires a value (ecs or eks)"
                exit 1
            fi
            ;;
        deploy)
            DEPLOY_COMMAND="deploy"
            shift
            ;;
        infrastructure)
            DEPLOY_COMMAND="infrastructure"
            shift
            ;;
        help|-h|--help)
            DEPLOY_COMMAND="help"
            shift
            ;;
        *)
            ARGS_TO_PARSE+=("$1")
            shift
            ;;
    esac
done

# Parse remaining arguments for environment
if [ ${#ARGS_TO_PARSE[@]} -eq 0 ]; then
    ENVIRONMENT="$DEFAULT_ENVIRONMENT"
else
    ENVIRONMENT="${ARGS_TO_PARSE[0]:-$DEFAULT_ENVIRONMENT}"
    REMAINING_ARGS=("${ARGS_TO_PARSE[@]:1}")
fi

# Set default container type if deploy command is used without --container-type
if [ "$DEPLOY_COMMAND" = "deploy" ] && [ "$RUN_ALL" = false ] && [ -z "$CONTAINER_TYPE" ]; then
    CONTAINER_TYPE="$DEFAULT_CONTAINER_TYPE"  # Default to ecs for AWS
fi

# Export flags for sub-scripts (CONTAINER_TYPE may be overridden for --all mode)
export DRY_RUN SKIP_DATA_LAKE PREEMPT FORCE_REFRESH_DATA RUN_ALL

# Show usage information
show_usage() {
    cat << EOF
${GREEN}AWS Deployment Orchestrator${NC}

${BLUE}Usage:${NC}
  $0 deploy --container-type <type> [environment] [options...]
  $0 infrastructure [environment] [options...]

${BLUE}Workflows:${NC}
  ${GREEN}deploy${NC}          Deploy application (requires --container-type)
                              → Build container image
                              → Setup Terraform state bucket
                              → Deploy infrastructure (VPC, Aurora, IAM, Secrets)
                              → Deploy application (container-specific)

  ${GREEN}infrastructure${NC}  Infrastructure only
                                   → Setup Terraform state bucket
                                   → Deploy infrastructure (VPC, Aurora, IAM, Secrets)
                              → No application deployment

${BLUE}Container Types (for --container-type):${NC}
  ecs     ECS deployment (default for AWS)
          → Deploy application (ECS, ALB, CloudFront)
  eks     EKS deployment
                                   → Deploy EKS layer (EKS cluster, node groups, OIDC)
                                   → Configure kubectl
                                   → Deploy Kubernetes manifests

${BLUE}Environments:${NC}
  dev     Development environment (default: $DEFAULT_ENVIRONMENT)
  prod    Production environment

  ${BLUE}Options:${NC}
  ${GREEN}--container-type <ecs|eks>${NC}  Container orchestration type (required for deploy)
  ${GREEN}--dry-run${NC}          Preview changes without modifying AWS resources
  ${GREEN}--preempt${NC}          Destroy existing infrastructure before deployment (clean slate)
  ${GREEN}--skip-data-lake${NC}   Skip data-lake setup even if analytics scheduler is enabled
  ${GREEN}--force-refresh-data${NC} Force refresh of data resources (database schema, data, Delta tables) without destroying infrastructure

${BLUE}Examples:${NC}
  ${GREEN}Basic Deployments:${NC}
  $0 deploy --container-type ecs dev          # Complete ECS deployment to dev
  $0 deploy --container-type ecs              # Same as above (dev is default)
  $0 deploy --container-type eks dev          # Complete EKS deployment to dev
  $0 deploy --container-type eks prod         # Complete EKS deployment to prod
  $0 infrastructure dev                        # Infrastructure only to dev

  ${GREEN}Full Teardown and Fresh Deployment:${NC}
  $0 deploy --container-type ecs dev --preempt    # Destroy everything, then deploy ECS
  $0 deploy --container-type eks dev --preempt    # Destroy everything, then deploy EKS

  ${GREEN}Preview Changes (Dry-Run):${NC}
  $0 deploy --container-type ecs dev --dry-run    # Preview ECS deployment
  $0 deploy --container-type eks dev --dry-run    # Preview EKS deployment

  ${GREEN}Data-Lake Scenarios:${NC}
  # With analytics enabled in .env (ENABLE_ANALYTICS_SCHEDULER=true)
  $0 deploy --container-type ecs dev   # Delta-lake set up automatically in Phase 5: Step 5.1

  # With analytics disabled in .env (ENABLE_ANALYTICS_SCHEDULER=false)
  $0 deploy --container-type ecs dev   # Delta-lake setup skipped
  $0 deploy --container-type ecs dev --skip-data-lake  # Force skip (even if analytics enabled)

  ${GREEN}Deploy Both Container Types:${NC}
  $0 deploy --container-type ecs dev --all    # Deploy both ECS and EKS sequentially

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
    log_info "[DEBUG] check_or_build_image: Starting at $(date)"
    
    # Note: Environment variables (including IMAGE_PREFIX) are already loaded at script startup
    # Use admin profile for infrastructure operations (ECR)
    AWS_PROFILE="${AWS_PROFILE:-admin}"
    log_info "[DEBUG] check_or_build_image: Using AWS_PROFILE=$AWS_PROFILE"
    
    # Generate CONTAINER_IMAGE using centralized function
    # For AWS deployments, this resolves IMAGE_PREFIX to actual ECR URI
    log_info "[DEBUG] check_or_build_image: About to call resolve_container_image_for_aws..."
    local resolve_start=$(date +%s)
    # Capture only stdout (the actual return value), redirect stderr to /dev/null to avoid mixing logs
    CONTAINER_IMAGE=$(resolve_container_image_for_aws 2>/dev/null)
    local resolve_elapsed=$(( $(date +%s) - resolve_start ))
    log_info "[DEBUG] check_or_build_image: resolve_container_image_for_aws completed in ${resolve_elapsed}s"
    log_info "[DEBUG] check_or_build_image: CONTAINER_IMAGE='$CONTAINER_IMAGE'"
    log_info "[DEBUG] check_or_build_image: CONTAINER_IMAGE length: ${#CONTAINER_IMAGE}"
    log_info "[DEBUG] check_or_build_image: CONTAINER_IMAGE contains colon: $(echo "$CONTAINER_IMAGE" | grep -c ':' || echo '0')"
    
    # Validate CONTAINER_IMAGE format before extracting
    if [ -z "$CONTAINER_IMAGE" ]; then
        log_error "CONTAINER_IMAGE is empty!"
        exit 1
    fi
    
    if [[ "$CONTAINER_IMAGE" != *":"* ]]; then
        log_error "CONTAINER_IMAGE does not contain a colon separator: '$CONTAINER_IMAGE'"
        log_error "Expected format: <repository>:<tag>"
        exit 1
    fi
    
    export CONTAINER_IMAGE
    
    # Extract ECR_REPO_URI and IMAGE_TAG for build-push-ecr.sh
    # These are needed for ECR operations (check existence, push, etc.)
    # Use robust extraction method: ##*: extracts everything after LAST colon (handles edge cases)
    # This matches the approach in build-push-ecr.sh for consistency
    ECR_REPO_URI="${CONTAINER_IMAGE%%:*}"
    IMAGE_TAG="${CONTAINER_IMAGE##*:}"
    
    # Remove any trailing whitespace or newlines that might have been captured
    IMAGE_TAG=$(echo "$IMAGE_TAG" | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    ECR_REPO_URI=$(echo "$ECR_REPO_URI" | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    log_info "[DEBUG] check_or_build_image: Extracted from CONTAINER_IMAGE='$CONTAINER_IMAGE':"
    log_info "[DEBUG] check_or_build_image:   ECR_REPO_URI='$ECR_REPO_URI'"
    log_info "[DEBUG] check_or_build_image:   IMAGE_TAG='$IMAGE_TAG'"
    log_info "[DEBUG] check_or_build_image:   IMAGE_TAG length: ${#IMAGE_TAG}"
    export ECR_REPO_URI IMAGE_TAG
    
    # Get ECR repository name and region for AWS CLI operations
    ECR_REPO_NAME="${ECR_REPO_NAME:-fru-api}"
    AWS_REGION="${AWS_REGION:-$DEFAULT_AWS_REGION}"
    
    # NOTE: We rely on ECR itself to validate IMAGE_TAG format.
    # Our generators (generate_image_tag, ensure_image_tag) already produce
    # ECR-safe tags; if anything is wrong, aws ecr describe-images will fail
    # with a clear error from AWS. This avoids false negatives from shell regex.
    log_info "[DEBUG] check_or_build_image: IMAGE_TAG value: '$IMAGE_TAG'"
    log_info "[DEBUG] check_or_build_image: IMAGE_TAG length: ${#IMAGE_TAG}"
    
    # Check if image already exists in ECR
    log_info "Checking if container image exists in ECR: $CONTAINER_IMAGE"
    log_info "[DEBUG] check_or_build_image: About to call aws ecr describe-images with imageTag='$IMAGE_TAG'"
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

# Container type deployment workflow (wrapper for deploy_ecs_full and deploy_eks_full)
# Routes to the appropriate deployment function based on CONTAINER_TYPE
deploy_with_container_type() {
    # Ensure CONTAINER_TYPE is set
    CONTAINER_TYPE="${CONTAINER_TYPE:-ecs}"
    
    # Validate container type for AWS
    if [[ "$CONTAINER_TYPE" != "ecs" && "$CONTAINER_TYPE" != "eks" ]]; then
        log_error "Invalid container type for AWS: $CONTAINER_TYPE (must be ecs or eks)"
        exit 1
    fi
    
    # Call container-specific deployment function
    case "$CONTAINER_TYPE" in
        ecs)
            deploy_ecs_full
            ;;
        eks)
            deploy_eks_full
            ;;
        *)
            log_error "Unknown container type: $CONTAINER_TYPE"
            exit 1
            ;;
    esac
}

# Complete ECS deployment workflow
# Handles Phase 1-7: Environment Preparation → Infrastructure Setup → Database Setup → Application Infrastructure → Data Lake → Frontend Deployment → Verification
# (Phase 0 is handled in main() above)
# NOTE: This function is called by deploy_with_container_type() when CONTAINER_TYPE=ecs
deploy_ecs_full() {
    local deploy_start_time=$(date +%s)
    log_step "Starting complete ECS deployment workflow"
    log_info "Environment: $ENVIRONMENT"
    
    # Get step information from main() (accounts for Phase 0 steps and preempt if enabled)
    local step_num="${CURRENT_STEP:-5}"  # Default to 5 (after Phase 0.1-0.4, or 0.5 if preempt)
    local total_steps="${TOTAL_STEPS:-13}"  # Default for ecs
    
    # ============================================================================
    # Phase 1: Environment Preparation - Step 1.3: Prepare container image
    # Phase 2: Infrastructure Setup - Steps 2.2, 2.3
    # ============================================================================
    # Use shared phase functions to reduce duplication
    # Note: Functions return step_num via echo (stdout), logs go to stderr
    # Extract only numeric value from output (filter out any log output that leaks to stdout)
    step_num=$(deploy_phase_check_image "$step_num" "$total_steps" 2>&1 | grep -E '^[0-9]+$' | tail -1)
    step_num=$(deploy_phase_setup_state_bucket "$step_num" "$total_steps" "$SCRIPT_DIR" 2>&1 | grep -E '^[0-9]+$' | tail -1)
    step_num=$(deploy_phase_deploy_infrastructure "$step_num" "$total_steps" "$SCRIPT_DIR" "$ENVIRONMENT" 2>&1 | grep -E '^[0-9]+$' | tail -1)

    # ============================================================================
    # Phase 3: Database Setup (ECS only - EKS uses Kubernetes manifests)
    # ============================================================================
    step_num=$(deploy_phase_setup_database "$step_num" "$total_steps" "$SCRIPT_DIR" "$ENVIRONMENT" "${FORCE_REFRESH_DATA:-false}" "${DRY_RUN:-false}" 2>&1 | grep -E '^[0-9]+$' | tail -1)
    
    # ============================================================================
    # Phase 4: Application Infrastructure Deployment
    # ============================================================================
    perf_phase_start 4 "Application Infrastructure Deployment"
    perf_step_start 4 "4.1" "Deploying application infrastructure (ECS, ALB, CloudFront)"
    step_start_time=$(date +%s)
    log_step "Phase 4: Step 4.1 - Step ${step_num}/${total_steps}: Deploying application infrastructure (ECS, ALB, CloudFront)"
    log_info "Using container image: $CONTAINER_IMAGE"
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" "$CONTAINER_TYPE"; then
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
    # Phase 5: Data Lake Setup (optional, conditional)
    # ============================================================================
    step_num=$(deploy_phase_setup_data_lake "$step_num" "$total_steps" "$REPO_ROOT" "$ENVIRONMENT" "${PREEMPT:-false}" "${FORCE_REFRESH_DATA:-false}" "${DRY_RUN:-false}" "${ENABLE_ANALYTICS_SCHEDULER:-false}" "${SKIP_DATA_LAKE:-false}" 2>&1 | grep -E '^[0-9]+$' | tail -1)
    
    # ============================================================================
    # Phase 6: Frontend Deployment
    # ============================================================================
    step_num=$(deploy_phase_deploy_frontend "$step_num" "$total_steps" "$SCRIPT_DIR" "$ENVIRONMENT" 2>&1 | grep -E '^[0-9]+$' | tail -1)
    
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
    log_info "[DEBUG] Deployment start time: $(date)"
    log_info "[DEBUG] Script directory: $SCRIPT_DIR"
    log_info "[DEBUG] Repo root: $REPO_ROOT"
    
    # Get step information from main() (accounts for Phase 0 steps and preempt if enabled)
    local step_num="${CURRENT_STEP:-5}"  # Default to 5 (after Phase 0.1-0.4, or 0.5 if preempt)
    local total_steps="${TOTAL_STEPS:-11}"  # Default for eks
    log_info "[DEBUG] Starting at step: $step_num/$total_steps"
    
    # ============================================================================
    # Phase 1: Environment Preparation - Step 1.3: Prepare container image
    # Phase 2: Infrastructure Setup - Steps 2.2, 2.3
    # ============================================================================
    log_info "[DEBUG] About to start Phase 1: Checking container image..."
    log_info "[DEBUG] Calling deploy_phase_check_image with step_num=$step_num, total_steps=$total_steps"
    log_info "[DEBUG] Current time before function call: $(date)"
    
    # Use shared phase functions to reduce duplication
    # Note: Functions return step_num via echo (stdout), logs go to stderr
    # Extract only numeric value from output (filter out any log output that leaks to stdout)
    local phase1_start=$(date +%s)
    log_info "[DEBUG] phase1_start=$phase1_start, about to call function NOW..."
    
    # Call function and capture output separately to avoid pipe buffering issues
    # Use a temp file to capture both stdout and stderr
    local temp_output=$(mktemp)
    log_info "[DEBUG] Created temp file: $temp_output"
    log_info "[DEBUG] About to execute deploy_phase_check_image..."
    
    # Execute function with output redirection to temp file
    deploy_phase_check_image "$step_num" "$total_steps" > "$temp_output" 2>&1 &
    local func_pid=$!
    log_info "[DEBUG] Function started in background with PID: $func_pid"
    
    # Wait for function with timeout and show progress
    local wait_timeout=1800  # 30 minutes max (large downloads and ECR push can take time)
    local waited=0
    local wait_interval=5
    
    while kill -0 "$func_pid" 2>/dev/null && [ $waited -lt $wait_timeout ]; do
        sleep $wait_interval
        waited=$((waited + wait_interval))
        log_info "[DEBUG] Function still running... (waited ${waited}s/${wait_timeout}s)"
        # Show last few lines of output
        if [ -s "$temp_output" ]; then
            log_info "[DEBUG] Last output from function:"
            tail -3 "$temp_output" | while IFS= read -r line; do
                log_info "[DEBUG]   $line"
            done
        fi
    done
    
    # Check if function completed
    if kill -0 "$func_pid" 2>/dev/null; then
        log_error "[DEBUG] Function timed out after ${wait_timeout}s, killing..."
        kill "$func_pid" 2>/dev/null || true
        wait "$func_pid" 2>/dev/null || true
        log_error "Function deploy_phase_check_image timed out"
        cat "$temp_output"
        rm -f "$temp_output"
        exit 1
    fi
    
    # Wait for function to complete and get exit code
    wait "$func_pid"
    local func_exit_code=$?
    log_info "[DEBUG] Function completed with exit code: $func_exit_code"
    
    # Show all output
    if [ -s "$temp_output" ]; then
        log_info "[DEBUG] Full function output:"
        cat "$temp_output"
    fi
    
    # Extract step_num from output (should be the last number on its own line)
    step_num=$(grep -E '^[0-9]+$' "$temp_output" | tail -1)
    log_info "[DEBUG] Extracted step_num=$step_num from output"
    
    # Extract CONTAINER_IMAGE from output if it was logged
    # The check_or_build_image function should have set CONTAINER_IMAGE, but since it ran in background,
    # we need to re-export it in the main shell. Check if it's already set, otherwise extract from logs.
    if [ -z "${CONTAINER_IMAGE:-}" ]; then
        # Try to extract CONTAINER_IMAGE from the output logs
        # Look for lines like: "CONTAINER_IMAGE='...'" or "Using container image: ..."
        # Extract the full ECR URI with tag, removing any quotes
        local extracted_image=$(grep -E "(CONTAINER_IMAGE=|Using container image:)" "$temp_output" | \
            grep -oE "[0-9]+\.dkr\.ecr\.[^:']+:[^[:space:]']+" | head -1 | tr -d "'\"")
        if [ -n "$extracted_image" ]; then
            export CONTAINER_IMAGE="$extracted_image"
            log_info "[DEBUG] Extracted CONTAINER_IMAGE from function output: $CONTAINER_IMAGE"
        else
            # If not found in logs, regenerate it (should be fast since image already exists)
            log_info "[DEBUG] CONTAINER_IMAGE not found in output, regenerating..."
            if command -v resolve_container_image_for_aws >/dev/null 2>&1; then
                export CONTAINER_IMAGE=$(resolve_container_image_for_aws 2>/dev/null)
                log_info "[DEBUG] Regenerated CONTAINER_IMAGE: $CONTAINER_IMAGE"
            fi
        fi
    else
        # Clean up any quotes that might have been included
        CONTAINER_IMAGE=$(echo "$CONTAINER_IMAGE" | tr -d "'\"")
        export CONTAINER_IMAGE
        log_info "[DEBUG] CONTAINER_IMAGE already set (cleaned): $CONTAINER_IMAGE"
    fi
    
    # Cleanup
    rm -f "$temp_output"
    
    if [ -z "$step_num" ] || [ "$func_exit_code" -ne 0 ]; then
        log_error "Function deploy_phase_check_image failed or returned invalid step_num"
        exit 1
    fi
    
    log_info "[DEBUG] Function call completed successfully, step_num=$step_num"
    local phase1_elapsed=$(( $(date +%s) - phase1_start ))
    log_info "[DEBUG] Phase 1 completed in $(format_elapsed_time $phase1_elapsed), new step_num=$step_num"
    
    log_info "[DEBUG] About to start Phase 2.2: Setting up Terraform state bucket..."
    log_info "[DEBUG] Calling deploy_phase_setup_state_bucket with step_num=$step_num, total_steps=$total_steps"
    local phase2_2_start=$(date +%s)
    step_num=$(deploy_phase_setup_state_bucket "$step_num" "$total_steps" "$SCRIPT_DIR" 2>&1 | grep -E '^[0-9]+$' | tail -1)
    local phase2_2_elapsed=$(( $(date +%s) - phase2_2_start ))
    log_info "[DEBUG] Phase 2.2 completed in $(format_elapsed_time $phase2_2_elapsed), new step_num=$step_num"
    
    log_info "[DEBUG] About to start Phase 2.3: Deploying infrastructure layer..."
    log_info "[DEBUG] Calling deploy_phase_deploy_infrastructure with step_num=$step_num, total_steps=$total_steps, environment=$ENVIRONMENT"
    local phase2_3_start=$(date +%s)
    step_num=$(deploy_phase_deploy_infrastructure "$step_num" "$total_steps" "$SCRIPT_DIR" "$ENVIRONMENT" 2>&1 | grep -E '^[0-9]+$' | tail -1)
    local phase2_3_elapsed=$(( $(date +%s) - phase2_3_start ))
    log_info "[DEBUG] Phase 2.3 completed in $(format_elapsed_time $phase2_3_elapsed), new step_num=$step_num"
    
    # ============================================================================
    # (Phase 3: Database Setup is handled via Kubernetes manifests for EKS)
    # ============================================================================
    
    # ============================================================================
    # Phase 4: Data Lake Setup (optional, conditional)
    # ============================================================================
    step_num=$(deploy_phase_setup_data_lake "$step_num" "$total_steps" "$REPO_ROOT" "$ENVIRONMENT" "${PREEMPT:-false}" "${FORCE_REFRESH_DATA:-false}" "${DRY_RUN:-false}" "${ENABLE_ANALYTICS_SCHEDULER:-false}" "${SKIP_DATA_LAKE:-false}" 2>&1 | grep -E '^[0-9]+$' | tail -1)
    
    # ============================================================================
    # Phase 5: Application Deployment
    # ============================================================================
    perf_phase_start 5 "Application Deployment"
    # Step 5.1: Deploy eks layer (EKS cluster + Frontend)
    # Note: EKS cluster and Frontend are now combined in eks layer (matching ECS pattern)
    perf_step_start 5 "5.1" "Deploying eks layer (EKS cluster + Frontend)"
    step_start_time=$(date +%s)
    log_step "Phase 5: Step 5.1 - Step ${step_num}/${total_steps}: Deploying eks layer (EKS cluster, node groups, OIDC provider, Frontend)" >&2
    
    # Start progress indicator for Terraform EKS deployment (can take 10-20 minutes)
    if command -v progress_heartbeat_start >/dev/null 2>&1; then
        progress_heartbeat_start "Deploying EKS layer (Terraform)" 10 >&2
    fi
    
    local eks_deploy_result=0
    if ! "$SCRIPT_DIR/terraform/deploy.sh" "$ENVIRONMENT" eks; then
        eks_deploy_result=1
    fi
    
    # Stop progress indicator
    if command -v progress_heartbeat_stop >/dev/null 2>&1; then
        progress_heartbeat_stop >&2
    fi
    
    if [ "$eks_deploy_result" -ne 0 ]; then
        elapsed=$(( $(date +%s) - step_start_time ))
        perf_step_end 5 "5.1" "FAILED" "EKS layer deployment failed" >&2
        log_error "Phase 5: Step 5.1 - Step ${step_num}/${total_steps} FAILED: EKS layer deployment failed (took $(format_elapsed_time $elapsed))" >&2
        log_info "Reason: Terraform plan or apply failed for eks layer" >&2
        log_info "Check Terraform configuration, AWS permissions, EKS quotas, and plan output above" >&2
        exit 1
    fi
    elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 5 "5.1" "SUCCESS" "EKS layer deployed" >&2
    log_success "Phase 5: Step 5.1 - Step ${step_num}/${total_steps} PASSED: EKS layer deployed (took $(format_elapsed_time $elapsed))" >&2
    step_num=$((step_num + 1))
    
    # ============================================================================
    # Phase 5: Application Deployment - Step 5.2: Deploy Kubernetes manifests
    # ============================================================================
    perf_step_start 5 "5.2" "Configuring kubectl and deploying Kubernetes manifests"
    step_start_time=$(date +%s)
    log_step "Phase 5: Step 5.2 - Step ${step_num}/${total_steps}: Configuring kubectl and deploying Kubernetes manifests"
    log_info "Using container image: $CONTAINER_IMAGE"
    
    # Get cluster name from Terraform output
    TERRAFORM_DIR="$REPO_ROOT/infra/terraform/providers/aws/environments"
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
        
        # Start progress indicator for kubectl configuration
        if command -v progress_heartbeat_start >/dev/null 2>&1; then
            progress_heartbeat_start "Configuring kubectl for EKS cluster" 10
        fi
        
        # Note: Environment variables (including AWS_REGION) are already loaded at script startup
        AWS_REGION="${AWS_REGION:-$DEFAULT_AWS_REGION}"
        local kubeconfig_result=0
        if ! aws eks update-kubeconfig \
            --region "$AWS_REGION" \
            --name "$CLUSTER_NAME" \
            --profile admin; then
            kubeconfig_result=1
        fi
        
        # Stop progress indicator
        if command -v progress_heartbeat_stop >/dev/null 2>&1; then
            progress_heartbeat_stop
        fi
        
        if [ "$kubeconfig_result" -ne 0 ]; then
            elapsed=$(( $(date +%s) - step_start_time ))
            perf_step_end 5 "5.2" "FAILED" "kubectl configuration failed"
            log_error "Phase 5: Step 5.2 - Step ${step_num}/${total_steps} FAILED: kubectl configuration failed (took $(format_elapsed_time $elapsed))"
            log_info "Check AWS credentials, EKS cluster status, and permissions"
            exit 1
        fi
        log_success "kubectl configured for cluster: $CLUSTER_NAME"
        
        # Ensure AWS_PROFILE is exported for eks/deploy.sh subprocess
        # This is critical because eks/deploy.sh calls kubectl which uses AWS_PROFILE
        export AWS_PROFILE="${AWS_PROFILE:-admin}"
        log_info "Exported AWS_PROFILE=$AWS_PROFILE for eks/deploy.sh subprocess"
        
        # Ensure CONTAINER_IMAGE is exported for eks/deploy.sh subprocess
        # This is critical to prevent image tag regeneration (timestamp drift)
        # CONTAINER_IMAGE should be set during Phase 1 (check_or_build_image)
        export CONTAINER_IMAGE="${CONTAINER_IMAGE:-}"
        if [ -z "$CONTAINER_IMAGE" ]; then
            log_error "CONTAINER_IMAGE not set - cannot deploy Kubernetes manifests"
            log_error "This should have been set during Phase 1 (container image check/build)"
            exit 1
        fi
        log_info "Exported CONTAINER_IMAGE=$CONTAINER_IMAGE for eks/deploy.sh subprocess"
        
        # Start progress indicator for Kubernetes manifest deployment
        if command -v progress_heartbeat_start >/dev/null 2>&1; then
            progress_heartbeat_start "Deploying Kubernetes manifests" 10
        fi
        
        # Deploy Kubernetes manifests
        local k8s_deploy_result=0
        if ! "$SCRIPT_DIR/eks/deploy.sh"; then
            k8s_deploy_result=1
        fi
        
        # Stop progress indicator
        if command -v progress_heartbeat_stop >/dev/null 2>&1; then
            progress_heartbeat_stop
        fi
        
        if [ "$k8s_deploy_result" -ne 0 ]; then
            elapsed=$(( $(date +%s) - step_start_time ))
            perf_step_end 5 "5.2" "FAILED" "Kubernetes manifest deployment failed"
            log_error "Phase 5: Step 5.2 - Step ${step_num}/${total_steps} FAILED: Kubernetes manifest deployment failed (took $(format_elapsed_time $elapsed))"
            log_info "Reason: Kubernetes manifest application or verification failed"
            log_info "Check Kubernetes manifests, EKS cluster status, and kubectl output above"
            exit 1
        fi
    fi
    elapsed=$(( $(date +%s) - step_start_time ))
    perf_step_end 5 "5.2" "SUCCESS" "Kubernetes manifests deployed"
    log_success "Phase 5: Step 5.2 - Step ${step_num}/${total_steps} PASSED: Kubernetes manifests deployed (took $(format_elapsed_time $elapsed))"
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
    log_info "Infrastructure is ready. Deploy application with:"
    log_info "  $0 deploy --container-type ecs dev"
    log_info "  $0 deploy --container-type eks dev"
    log_info "Total deployment time: $(format_elapsed_time $total_elapsed)"
}

main() {
    # Handle help first (doesn't require AWS credentials)
    if [ "$DEPLOY_COMMAND" = "help" ]; then
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
    
    # Calculate total steps based on deployment command and container type
    # Base steps: 4 (Phase 0.1-0.4) + deployment steps + 1 (Phase 7)
    local container_type_for_steps="${CONTAINER_TYPE:-ecs}"  # Default to ecs
    local total_steps=13  # Default for ecs: 4 (Phase 0) + 8 (deploy) + 1 (Phase 7)
    local current_step=1  # Start at step 1
    
    if [ "$DEPLOY_COMMAND" = "deploy" ]; then
        if [ "$container_type_for_steps" = "eks" ]; then
        total_steps=11  # 4 (Phase 0) + 6 (deploy) + 1 (Phase 7)
        fi
    elif [ "$DEPLOY_COMMAND" = "infrastructure" ]; then
        total_steps=6  # 4 (Phase 0) + 2 (infrastructure only)
    fi
    
    # If preempt is enabled for full workflows, add 1 to total steps
    if [ "$PREEMPT" = "true" ] && [ "$DEPLOY_COMMAND" = "deploy" ] && [ -n "$CONTAINER_TYPE" ]; then
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
        # PREEMPT only applies to full deployments (deploy command)
        if [ "$DEPLOY_COMMAND" = "deploy" ] && [ -n "$CONTAINER_TYPE" ]; then
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
            
            # Pass CONTAINER_TYPE explicitly to teardown (required parameter)
            local destroy_cmd="$SCRIPT_DIR/shared/resources_cleanup/teardown-resources.sh $ENVIRONMENT --container-type $CONTAINER_TYPE"
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
            log_warning "PREEMPT mode is only supported for 'deploy' command"
            log_info "Skipping preempt destruction for command: ${DEPLOY_COMMAND:-<not set>}"
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
    
    # Handle deployment commands
    if [ "$DEPLOY_COMMAND" = "deploy" ]; then
        # If --all is set, run deploy (and its own verification) for both ecs and eks sequentially.
        if [ "$RUN_ALL" = true ]; then
            if [ "$PREEMPT" = true ]; then
                log_error "--all cannot be combined with --preempt (would destroy infrastructure twice)"
                exit 1
            fi

            local extra_flags=()
            [ "$DRY_RUN" = true ] && extra_flags+=("--dry-run")
            [ "$SKIP_DATA_LAKE" = true ] && extra_flags+=("--skip-data-lake")
            [ "$FORCE_REFRESH_DATA" = true ] && extra_flags+=("--force-refresh-data")

            for ct in ecs eks; do
                log_step "Running full AWS deploy workflow for container type: $ct (environment: $ENVIRONMENT)"
                "$0" deploy --container-type "$ct" "$ENVIRONMENT" "${extra_flags[@]}"
            done

            # Phase 7 and final summary are handled by each child invocation.
            trap - EXIT
            local total_elapsed=$(( $(date +%s) - script_start_time ))
            echo ""
            log_success "═══════════════════════════════════════════════════════════════════════════════"
            log_success "AWS deployment (--all: ecs + eks) completed!"
            log_success "Total execution time: $(format_elapsed_time $total_elapsed)"
            log_success "═══════════════════════════════════════════════════════════════════════════════"
            perf_print_summary
            perf_print_statistics
            exit 0
        fi

        if [ -z "$CONTAINER_TYPE" ]; then
            log_error "Missing required --container-type parameter for deploy command"
            echo ""
            show_usage
            exit 1
        fi
        export CONTAINER_TYPE
        deploy_with_container_type
        echo ""
    elif [ "$DEPLOY_COMMAND" = "infrastructure" ]; then
            deploy_infrastructure
            echo ""
    elif [ "$DEPLOY_COMMAND" = "help" ] || [ ${#ARGS_TO_PARSE[@]} -eq 0 ]; then
        # Show help if no arguments or help requested
        show_usage
        exit 0
    else
        log_error "Unknown command: ${DEPLOY_COMMAND:-<not set>}"
        log_error "Container type: ${CONTAINER_TYPE:-<not set>}"
            echo ""
            show_usage
                exit 1
    fi
    
    # ============================================================================
    # Phase 7: Validation and Verification
    # ============================================================================
    # Step 7.1: Post-deployment verification (full workflows only)
    # Note: Phase 7 only runs for full deployment workflows (deploy with container type)
    # Infrastructure-only workflows skip this phase
    if [ "$DEPLOY_COMMAND" = "deploy" ] && [ -n "$CONTAINER_TYPE" ]; then
        # Use step number from deployment function (accounts for Phase 0 and preempt)
        local container_type_for_steps="${CONTAINER_TYPE:-ecs}"  # Default to ecs
        local step_num="${CURRENT_STEP:-13}"  # Default: after Phase 0 (4) + deploy (8) + 1 = 13
        local total_steps="${TOTAL_STEPS:-13}"  # Default for ecs
        if [ "$container_type_for_steps" = "eks" ]; then
            # Defaults for eks if not set
            step_num="${CURRENT_STEP:-11}"  # Default: after Phase 0 (4) + deploy (6) + 1 = 11
            total_steps="${TOTAL_STEPS:-11}"  # Default for eks
        fi
        perf_phase_start 7 "Validation and Verification"
        perf_step_start 7 "7.1" "Verifying deployment and generating test instructions"
        step_start_time=$(date +%s)
        log_step "Phase 7: Step 7.1 - Step ${step_num}/${total_steps}: Verifying deployment and generating test instructions"
        echo ""
        # Pass empty string - verification script uses CONTAINER_TYPE env var
        if "$SCRIPT_DIR/verification/auto_verify_and_manual_hint.sh" "" "$ENVIRONMENT" "$DRY_RUN"; then
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
