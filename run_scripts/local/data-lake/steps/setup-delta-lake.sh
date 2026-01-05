#!/bin/bash
# Setup Delta Lake directory structure for local development
# Called by: run_scripts/local/data-lake/setup-and-verify.sh
# Receives: DATA_LAKE_SETUP_MODE from parent

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$SCRIPT_DIR/../../../common/logger.sh"
source "$SCRIPT_DIR/../../../common/load-env.sh"

MODE="${DATA_LAKE_SETUP_MODE:-standalone}"

# Default Delta table path (can be overridden by DELTA_TABLE_PATH env var)
load_env_file || true
DELTA_TABLE_PATH="${DELTA_TABLE_PATH:-data/delta/fru_sales}"

# Resolve to absolute path
if [[ "$DELTA_TABLE_PATH" = /* ]]; then
    # Already absolute
    DELTA_DIR="$DELTA_TABLE_PATH"
else
    # Relative to repo root
    DELTA_DIR="$REPO_ROOT/$DELTA_TABLE_PATH"
fi

log_info "Delta table path: $DELTA_DIR"

# Mode-specific behavior
if [ "$MODE" = "standalone" ]; then
    # Idempotent: Check if directory already exists
    if [ -d "$DELTA_DIR" ]; then
        log_info "Delta Lake directory already exists: $DELTA_DIR"
        
        # Quick verification - check if it looks like a Delta table
        if [ -d "$DELTA_DIR/_delta_log" ]; then
        log_success "✓ Delta Lake directory exists and contains _delta_log"
        log_info "Skipping directory setup (idempotent mode)"
        exit 0
        else
            log_warning "Directory exists but doesn't look like a Delta table, will be created by Delta table creation step"
        fi
    else
        log_info "Delta Lake directory does not exist, will be created by Delta table creation step"
    fi
else
    # Full-workflow: Ensure directory structure is ready
    log_info "Ensuring Delta Lake directory structure is ready (full-workflow mode)..."
    
    if [ -d "$DELTA_DIR" ]; then
        log_info "Delta Lake directory exists, verifying structure..."
        
        if [ -d "$DELTA_DIR/_delta_log" ]; then
            log_success "✓ Delta Lake directory structure appears valid"
        else
            log_warning "Directory exists but _delta_log subdirectory missing (will be created by Delta table creation)"
        fi
    else
        log_info "Creating Delta Lake directory structure..."
        mkdir -p "$DELTA_DIR"
        log_success "Created Delta Lake directory: $DELTA_DIR"
    fi
fi

# Export for next step
export DELTA_DIR DELTA_TABLE_PATH

