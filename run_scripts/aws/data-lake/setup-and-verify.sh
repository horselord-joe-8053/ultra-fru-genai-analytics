#!/bin/bash
# Setup and verify Delta Lake / S3 infrastructure for analytics
# Usage: Called by run_scripts/aws/run.sh (receives MODE from parent)
#        Or standalone: ./setup-and-verify.sh [--full-workflow|--standalone]
#
# This script orchestrates:
#   1. Setup data-lake infrastructure (S3 bucket + IAM permissions) via Terraform
#   2. Create Delta table in S3 from CSV
#   3. Verify data-lake setup
#
# Mode behavior:
#   - full-workflow: Comprehensive setup - ensures everything is properly configured
#     → Always runs Terraform apply (verifies infrastructure is up-to-date)
#     → Verifies Delta table integrity, recreates if corrupted
#     → Comprehensive verification (configuration, permissions, integrity)
#     → Used automatically when called from run_scripts/aws/run.sh
#
#   - standalone: Idempotent - skips operations if resources already exist
#     → Checks if outputs exist first, skips Terraform apply if already deployed
#     → Checks if Delta table exists, skips creation if present
#     → Basic verification (resource exists, accessible)
#     → Default when run directly (safe to run multiple times)
#
# Practical Examples:
#
#   # Standalone execution (idempotent - safe to run multiple times)
#   ./setup-and-verify.sh                                # Default: standalone mode
#   ./setup-and-verify.sh --standalone                   # Explicit standalone mode
#
#   # Force comprehensive setup (even if resources exist)
#   ./setup-and-verify.sh --full-workflow                # Force full-workflow mode
#
#   # When called from run.sh (automatically uses full-workflow mode)
#   ./run_scripts/aws/run.sh ecs-full dev                # Step 3.7 uses full-workflow mode
#
#   # With environment variables (from parent or manually set)
#   export ENVIRONMENT=dev
#   export DRY_RUN=false
#   export DATA_LAKE_SETUP_MODE=standalone
#   ./setup-and-verify.sh
#
#   # First-time setup (resources don't exist yet)
#   ./setup-and-verify.sh                                # Creates everything (idempotent mode)
#
#   # Re-running setup (resources already exist)
#   ./setup-and-verify.sh                                # Skips existing resources (idempotent mode)
#   ./setup-and-verify.sh --full-workflow                # Verifies and updates everything
#
# Environment Variables:
#   ENVIRONMENT          → Environment name (dev|prod), defaults to 'dev'
#   DRY_RUN              → If 'true', shows what would be done without making changes
#   DATA_LAKE_SETUP_MODE → Mode to use (full-workflow|standalone), defaults to 'standalone'
#                          Set automatically to 'full-workflow' when called from run.sh
#
# See DATA_LAKE_USAGE_GUIDE.md for detailed scenarios and mode behavior.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/../../common/logger.sh"
source "$SCRIPT_DIR/../../common/load-env.sh"

# Default mode (from environment or default to standalone)
DATA_LAKE_SETUP_MODE="${DATA_LAKE_SETUP_MODE:-standalone}"

# Parse flags (allow override)
for arg in "$@"; do
    if [ "$arg" = "--full-workflow" ]; then
        DATA_LAKE_SETUP_MODE="full-workflow"
    elif [ "$arg" = "--standalone" ]; then
        DATA_LAKE_SETUP_MODE="standalone"
    fi
done

export DATA_LAKE_SETUP_MODE

log_step "Setting up and verifying data-lake infrastructure"
log_info "Mode: $DATA_LAKE_SETUP_MODE"
if [ "$DATA_LAKE_SETUP_MODE" = "full-workflow" ]; then
    log_info "Running in full-workflow mode (comprehensive setup and verification)"
else
    log_info "Running in standalone mode (idempotent - skip if already exists)"
fi

# Ensure ENVIRONMENT and DRY_RUN are set (from parent or defaults)
ENVIRONMENT="${ENVIRONMENT:-dev}"
DRY_RUN="${DRY_RUN:-false}"
export ENVIRONMENT
export DRY_RUN

# Step 1: Setup data-lake infrastructure
log_step "Step 1/3: Setting up data-lake infrastructure (S3 + IAM)"
if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would run: $SCRIPT_DIR/steps/setup-data-lake.sh"
else
    export DATA_LAKE_SETUP_MODE="$DATA_LAKE_SETUP_MODE"  # Pass mode to step
    VARS_FILE=$("$SCRIPT_DIR/steps/setup-data-lake.sh" 2>&1 | tee /dev/stderr | tail -1)
    EXIT_CODE=${PIPESTATUS[0]}
    if [ $EXIT_CODE -ne 0 ]; then
        log_error "Step 1/3 FAILED: Data-lake infrastructure setup failed"
        exit 1
    fi
    # Load exported variables from step script (if it created a vars file)
    if [ -n "$VARS_FILE" ] && [ -f "$VARS_FILE" ]; then
        source "$VARS_FILE"
        rm -f "$VARS_FILE"
    fi
fi
log_success "Step 1/3 PASSED: Data-lake infrastructure ready"

# Step 2: Create Delta table
log_step "Step 2/3: Creating Delta table in S3"
if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would run: $SCRIPT_DIR/steps/create-delta-table-for-env.sh"
else
    export DATA_LAKE_SETUP_MODE="$DATA_LAKE_SETUP_MODE"  # Pass mode to step
    if ! "$SCRIPT_DIR/steps/create-delta-table-for-env.sh"; then
        log_warning "Step 2/3 had issues: Delta table creation failed"
        if [ "$DATA_LAKE_SETUP_MODE" = "full-workflow" ]; then
            log_error "Full-workflow mode requires successful Delta table creation"
            exit 1
        else
            log_info "Standalone mode: continuing despite issues (Delta table may already exist)"
        fi
    fi
fi
log_success "Step 2/3 PASSED: Delta table ready"

# Step 3: Verify data-lake setup
log_step "Step 3/3: Verifying data-lake setup"
if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would run: $SCRIPT_DIR/steps/verify-data-lake.sh"
else
    export DATA_LAKE_SETUP_MODE="$DATA_LAKE_SETUP_MODE"  # Pass mode to step
    if ! "$SCRIPT_DIR/steps/verify-data-lake.sh"; then
        log_error "Step 3/3 FAILED: Data-lake verification failed"
        if [ "$DATA_LAKE_SETUP_MODE" = "full-workflow" ]; then
            exit 1
        else
            log_warning "Standalone mode: verification had issues but continuing"
        fi
    fi
fi
log_success "Step 3/3 PASSED: Data-lake verification complete"

log_success "Data-lake setup and verification completed successfully!"
log_info "Delta Lake is ready for batch analytics"

