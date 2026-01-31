#!/bin/bash
# Verify local Delta table exists and is valid
# Checks for _delta_log directory and log entries

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../../.." && pwd)"
source "$REPO_ROOT/orchestration/shared/logger.sh"
source "$REPO_ROOT/orchestration/shared/load-env.sh"

# Resolve Delta table path
if [ -z "$DELTA_DIR" ] || [ -z "$DELTA_TABLE_PATH" ]; then
    load_env_file || true
    DELTA_TABLE_PATH="${DELTA_TABLE_PATH:-data/delta/fru_sales}"
    if [[ "$DELTA_TABLE_PATH" = /* ]]; then
        DELTA_DIR="$DELTA_TABLE_PATH"
    else
        DELTA_DIR="$REPO_ROOT/$DELTA_TABLE_PATH"
    fi
fi

if [ ! -d "$DELTA_DIR" ]; then
    log_error "Delta table directory does not exist: $DELTA_DIR"
    exit 1
fi

# Verify Delta table exists (uses Python helper for consistency)
if ! "$REPO_ROOT/run_scripts/spark_delta-lake_scripts/common/delta-lake/helpers/check-delta-table-exists.sh" "$DELTA_DIR" "filesystem" "false" "false" 2>/dev/null; then
    log_error "Delta table does not exist at: $DELTA_DIR"
    exit 1
fi

# Verify table has log entries (indicates valid Delta table)
DELTA_LOG_COUNT=$(find "$DELTA_DIR/_delta_log" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
if [ "$DELTA_LOG_COUNT" -eq 0 ]; then
    log_error "Delta table has no log entries (invalid table)"
    exit 1
fi

log_success "Delta table verified at: $DELTA_DIR"

