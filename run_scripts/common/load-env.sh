#!/bin/bash
# Utility to load .env file and export variables
# Provides common path variables: SCRIPT_DIR, REPO_ROOT, ENV_FILE, ENV_TEMPLATE
# Usage: source load-env.sh [path/to/.env]

# Calculate paths (only if not already set by caller)
if [ -z "${ENV_SCRIPT_DIR:-}" ]; then
    ENV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Set common paths (exported for use by calling scripts)
export REPO_ROOT="${REPO_ROOT:-$(cd "$ENV_SCRIPT_DIR/../.." && pwd)}"
export ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"
export ENV_TEMPLATE="${ENV_TEMPLATE:-$REPO_ROOT/.env.example}"

# Note: We use ENV_SCRIPT_DIR internally to avoid overwriting caller's SCRIPT_DIR
# Callers can use their own SCRIPT_DIR for their script's location

load_env_file() {
    local env_path="${ENV_FILE:-$REPO_ROOT/.env}"
    
    if [ ! -f "$env_path" ]; then
        log_warning ".env file not found at $env_path"
        return 1
    fi
    
    # Load variables from .env (but don't export credential variables)
    # We load them into the current shell but don't export them to avoid
    # AWS CLI/boto3 picking them up instead of using profiles
    set +a  # Don't auto-export
    
    # Source the file to load variables
    source "$env_path"
    
    # Explicitly export non-credential variables that scripts need
    # Credential variables (AWS_ADMIN_*, AWS_BEDROCK_*) are NOT exported
    # They are only used by setup-aws-profiles.sh to populate ~/.aws/credentials
    export AWS_REGION="${AWS_REGION:-}"
    export AWS_PROFILE="${AWS_PROFILE:-}"
    export BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-}"
    export TF_STATE_BUCKET="${TF_STATE_BUCKET:-}"
    
    # Export database, OpenAI, and other non-AWS-credential variables
    # (These are loaded from .env but we don't need to list them all)
    
    log_success "Loaded environment variables from $env_path"
    log_info "Note: AWS credential variables (AWS_ADMIN_*, AWS_BEDROCK_*) are loaded but not exported"
    log_info "      Use AWS profiles (admin/bedrock) instead via --profile flag or AWS_PROFILE env var"
    return 0
}

# Source logger if not already sourced
if [ -z "${RED:-}" ]; then
    source "$ENV_SCRIPT_DIR/logger.sh"
fi

