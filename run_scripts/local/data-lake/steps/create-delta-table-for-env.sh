#!/bin/bash
# Local wrapper for creating Delta table
# Sets up local-specific configuration and calls common script
# Called by: run_scripts/local/data-lake/setup-and-verify.sh
# Receives: DATA_LAKE_SETUP_MODE, DELTA_DIR, DELTA_TABLE_PATH from parent

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
source "$SCRIPT_DIR/../../../common/logger.sh"
source "$SCRIPT_DIR/../../../common/load-env.sh"

MODE="${DATA_LAKE_SETUP_MODE:-standalone}"

# Get Delta table path (from parent or environment)
if [ -z "$DELTA_DIR" ] || [ -z "$DELTA_TABLE_PATH" ]; then
    load_env_file || true
    DELTA_TABLE_PATH="${DELTA_TABLE_PATH:-data/delta/fru_sales}"
    
    # Resolve to absolute path
    if [[ "$DELTA_TABLE_PATH" = /* ]]; then
        DELTA_DIR="$DELTA_TABLE_PATH"
    else
        DELTA_DIR="$REPO_ROOT/$DELTA_TABLE_PATH"
    fi
fi

# Default CSV file
CSV_FILE="${1:-$REPO_ROOT/data/raw/fridge_sales_with_rating.csv}"

log_info "Delta table path: $DELTA_DIR"
log_info "CSV file: $CSV_FILE"

# Ensure directory exists (will be created by Delta table creation if needed)
if [ ! -d "$(dirname "$DELTA_DIR")" ]; then
    mkdir -p "$(dirname "$DELTA_DIR")"
fi

# Require Delta Lake package from environment
if ! require_delta_lake_package; then
    exit 1
fi

# Set up local-specific environment variables for common script
export SPARK_PACKAGES="$DELTA_LAKE_PACKAGE"
export PATH_CHECK_METHOD="filesystem"
export REPO_ROOT="$REPO_ROOT"
export MODE="$MODE"

# Determine execution method (local or Docker)
EXECUTION_METHOD=""
SPARK_SUBMIT_PATH=""

if command -v spark-submit >/dev/null 2>&1; then
    EXECUTION_METHOD="local"
    SPARK_SUBMIT_PATH="spark-submit"
elif docker ps >/dev/null 2>&1 && docker ps --filter "name=fru_api" --format "{{.Names}}" | grep -q "fru_api"; then
    # Check if container has Spark installed
    if docker exec fru_api test -f /opt/spark/bin/spark-submit 2>/dev/null; then
        EXECUTION_METHOD="docker"
        SPARK_SUBMIT_PATH="/opt/spark/bin/spark-submit"
    else
        log_error "Spark not found in Docker container"
        log_info "Please ensure the fru_api container has Spark installed, or install Spark locally"
        exit 1
    fi
else
    log_error "Neither local Spark nor Docker container with Spark is available"
    log_info "Please install Spark locally (use --setup-spark flag) or start Docker services"
    exit 1
fi

export EXECUTION_METHOD
export SPARK_SUBMIT_PATH

log_info "Execution method: $EXECUTION_METHOD"
log_info "Spark submit path: $SPARK_SUBMIT_PATH"

# Call common script
"$REPO_ROOT/run_scripts/common/data-lake/create-delta-table.sh" \
    "$CSV_FILE" \
    "$DELTA_DIR"

