#!/bin/bash
# Setup local Delta Lake directory structure
# Creates directory for Delta table if it doesn't exist (idempotent)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"

load_env_file || true
DELTA_TABLE_PATH="${DELTA_TABLE_PATH:-data/delta/fru_sales}"

# Resolve absolute path
if [[ "$DELTA_TABLE_PATH" = /* ]]; then
    DELTA_DIR="$DELTA_TABLE_PATH"
else
    DELTA_DIR="$REPO_ROOT/$DELTA_TABLE_PATH"
fi

# Create directory (idempotent)
mkdir -p "$DELTA_DIR"
log_info "Delta table directory ready: $DELTA_DIR"

export DELTA_DIR DELTA_TABLE_PATH

