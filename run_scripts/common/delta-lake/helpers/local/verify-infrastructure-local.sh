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

if [ "$MODE" = "standalone" ]; then
    if [ -d "$DELTA_DIR/_delta_log" ]; then
        exit 0
    fi
else
    if [ ! -d "$DELTA_DIR/_delta_log" ]; then
        log_error "_delta_log directory is missing"
        exit 1
    fi
    DELTA_LOG_COUNT=$(find "$DELTA_DIR/_delta_log" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$DELTA_LOG_COUNT" -eq 0 ]; then
        log_error "Delta table has no log entries"
        exit 1
    fi
fi

