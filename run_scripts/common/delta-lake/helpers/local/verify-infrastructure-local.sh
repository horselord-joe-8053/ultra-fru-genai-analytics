#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../../.." && pwd)"
source "$SCRIPT_DIR/../../../logger.sh"
source "$SCRIPT_DIR/../../../load-env.sh"

MODE="${DATA_LAKE_SETUP_MODE:-standalone}"

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

# Use common helper to check if Delta table exists
if ! "$SCRIPT_DIR/../check-delta-table-exists.sh" "$DELTA_DIR" "filesystem" 2>/dev/null; then
    if [ "$MODE" = "standalone" ]; then
        # Standalone mode: exit silently if table doesn't exist (idempotent check)
        exit 0
    else
        # Full-workflow mode: fail if table doesn't exist
        log_error "Delta table does not exist at: $DELTA_DIR"
        exit 1
    fi
fi

# Table exists - verify it has log entries (full-workflow mode only)
if [ "$MODE" != "standalone" ]; then
    DELTA_LOG_COUNT=$(find "$DELTA_DIR/_delta_log" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$DELTA_LOG_COUNT" -eq 0 ]; then
        log_error "Delta table has no log entries"
        exit 1
    fi
fi

