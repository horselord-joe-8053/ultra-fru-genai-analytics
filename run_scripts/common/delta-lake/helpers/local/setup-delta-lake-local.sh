#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../../.." && pwd)"
source "$SCRIPT_DIR/../../../logger.sh"
source "$SCRIPT_DIR/../../../load-env.sh"

MODE="${DATA_LAKE_SETUP_MODE:-standalone}"
load_env_file || true
DELTA_TABLE_PATH="${DELTA_TABLE_PATH:-data/delta/fru_sales}"

if [[ "$DELTA_TABLE_PATH" = /* ]]; then
    DELTA_DIR="$DELTA_TABLE_PATH"
else
    DELTA_DIR="$REPO_ROOT/$DELTA_TABLE_PATH"
fi

if [ "$MODE" = "standalone" ]; then
    if [ -d "$DELTA_DIR" ] && [ -d "$DELTA_DIR/_delta_log" ]; then
        exit 0
    fi
else
    if [ -d "$DELTA_DIR" ]; then
        if [ ! -d "$DELTA_DIR/_delta_log" ]; then
            mkdir -p "$DELTA_DIR"
        fi
    else
        mkdir -p "$DELTA_DIR"
    fi
fi

export DELTA_DIR DELTA_TABLE_PATH

