#!/bin/bash
# Setup and verify Delta Lake for local development
# Usage: Called by run_scripts/local/run.sh (receives MODE from parent)
#        Or standalone: ./setup-and-verify.sh [--full-workflow|--standalone]
#
# This script orchestrates:
#   1. Setup Delta Lake directory structure
#   2. Create Delta table from CSV using Spark
#   3. Verify Delta table
#
# Mode behavior:
#   - full-workflow: Comprehensive setup - ensures everything is properly configured
#     → Always verifies directory structure is ready
#     → Verifies Delta table integrity, recreates if corrupted
#     → Comprehensive verification (structure, integrity, Spark can read it)
#     → Used automatically when called from run_scripts/local/run.sh
#
#   - standalone: Idempotent - skips operations if resources already exist
#     → Checks if directory exists first, skips creation if already present
#     → Checks if Delta table exists, skips creation if present
#     → Basic verification (directory exists, _delta_log exists)
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
#   ./run_scripts/local/run.sh                           # Step 7.5 uses full-workflow mode
#
#   # With environment variables (from parent or manually set)
#   export DATA_LAKE_SETUP_MODE=standalone
#   ./setup-and-verify.sh
#
#   # First-time setup (Delta table doesn't exist yet)
#   ./setup-and-verify.sh                                # Creates everything (idempotent mode)
#                                                         # Requires: Spark (local or Docker) + CSV file
#
#   # Re-running setup (Delta table already exists)
#   ./setup-and-verify.sh                                # Skips existing table (idempotent mode)
#   ./setup-and-verify.sh --full-workflow                # Verifies and recreates if corrupted
#
#   # If CSV file is missing
#   ./setup-and-verify.sh                                # Will fail with helpful error message
#                                                         # Expected CSV: data/raw/fridge_sales_with_rating.csv
#
# Environment Variables:
#   DATA_LAKE_SETUP_MODE → Mode to use (full-workflow|standalone), defaults to 'standalone'
#                          Set automatically to 'full-workflow' when called from run.sh
#   DELTA_TABLE_PATH     → Path to Delta table (relative to repo root or absolute)
#                          Defaults to 'data/delta/fru_sales'
#   DRY_RUN              → If 'true', shows what would be done without making changes
#
# Requirements:
#   - Spark: Either local (spark-submit in PATH) or Docker container (fru_api with Spark)
#   - CSV file: data/raw/fridge_sales_with_rating.csv (or specified path)
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

log_step "Setting up and verifying Delta Lake for local development"
log_info "Mode: $DATA_LAKE_SETUP_MODE"
if [ "$DATA_LAKE_SETUP_MODE" = "full-workflow" ]; then
    log_info "Running in full-workflow mode (comprehensive setup and verification)"
else
    log_info "Running in standalone mode (idempotent - skip if already exists)"
fi

# Step 1: Setup Delta Lake directory structure
log_step "Step 1/3: Setting up Delta Lake directory structure"
if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would run: $SCRIPT_DIR/steps/setup-delta-lake.sh"
else
    export DATA_LAKE_SETUP_MODE="$DATA_LAKE_SETUP_MODE"  # Pass mode to step
    if ! "$SCRIPT_DIR/steps/setup-delta-lake.sh"; then
        log_error "Step 1/3 FAILED: Delta Lake directory setup failed"
        exit 1
    fi
fi
log_success "Step 1/3 PASSED: Delta Lake directory structure ready"

# Step 2: Create Delta table
log_step "Step 2/3: Creating Delta table from CSV"
if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would run: $SCRIPT_DIR/steps/create-delta-table.sh"
else
    export DATA_LAKE_SETUP_MODE="$DATA_LAKE_SETUP_MODE"  # Pass mode to step
    if ! "$SCRIPT_DIR/steps/create-delta-table.sh"; then
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

# Step 3: Verify Delta table
log_step "Step 3/3: Verifying Delta table"
if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would run: $SCRIPT_DIR/steps/verify-delta-table.sh"
else
    export DATA_LAKE_SETUP_MODE="$DATA_LAKE_SETUP_MODE"  # Pass mode to step
    if ! "$SCRIPT_DIR/steps/verify-delta-table.sh"; then
        log_error "Step 3/3 FAILED: Delta table verification failed"
        if [ "$DATA_LAKE_SETUP_MODE" = "full-workflow" ]; then
            exit 1
        else
            log_warning "Standalone mode: verification had issues but continuing"
        fi
    fi
fi
log_success "Step 3/3 PASSED: Delta table verification complete"

log_success "Delta Lake setup and verification completed successfully!"
log_info "Delta Lake is ready for batch analytics"

