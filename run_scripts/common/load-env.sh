#!/bin/bash
# Utility to load .env file and export variables
# Usage: source load-env.sh [path/to/.env]

ENV_FILE=".env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

load_env_file() {
    local env_path="$REPO_ROOT/$ENV_FILE"
    
    if [ ! -f "$env_path" ]; then
        log_warning ".env file not found at $env_path"
        return 1
    fi
    
    # Load and export all variables from .env
    set -a
    source "$env_path"
    set +a
    
    log_success "Loaded environment variables from $env_path"
    return 0
}

# Source logger if not already sourced
if [ -z "${RED:-}" ]; then
    source "$SCRIPT_DIR/logger.sh"
fi

