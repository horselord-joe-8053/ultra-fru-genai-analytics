#!/bin/bash
# Utility to load .env file and export variables
# Provides common path variables: SCRIPT_DIR, REPO_ROOT, ENV_FILE, ENV_TEMPLATE
# Usage: source load-env.sh [path/to/.env]

# Calculate paths (only if not already set by caller)
if [ -z "${ENV_SCRIPT_DIR:-}" ]; then
    ENV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Detect repo root based on this script's location
DETECTED_REPO_ROOT="$(cd "$ENV_SCRIPT_DIR/../.." && pwd)"

# Harden REPO_ROOT/ENV_FILE handling:
# - Always use DETECTED_REPO_ROOT as the single source of truth
# - If caller pre-set REPO_ROOT/ENV_FILE to something else, log a warning
if [ -n "${REPO_ROOT:-}" ] && [ "$REPO_ROOT" != "$DETECTED_REPO_ROOT" ]; then
    echo "[load-env] WARNING: REPO_ROOT was pre-set to '$REPO_ROOT' but detected repo root is '$DETECTED_REPO_ROOT'. Overriding to detected repo root." >&2
fi

export REPO_ROOT="$DETECTED_REPO_ROOT"

if [ -n "${ENV_FILE:-}" ] && [ "$ENV_FILE" != "$REPO_ROOT/.env" ]; then
    echo "[load-env] WARNING: ENV_FILE was pre-set to '$ENV_FILE' but expected '$REPO_ROOT/.env'. Overriding to '$REPO_ROOT/.env'." >&2
fi

export ENV_FILE="$REPO_ROOT/.env"
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
    
    # AWS configuration (for Terragrunt get_env())
    export AWS_REGION="${AWS_REGION:-}"
    export AWS_PROFILE="${AWS_PROFILE:-}"
    export TF_STATE_BUCKET="${TF_STATE_BUCKET:-}"
    
    # Application configuration (for Terragrunt get_env())
    # Use empty defaults for fail-fast behavior (consistent with get_env("VAR", ""))
    export AWS_BEDROCK_INFERENCE_PROFILE_ID="${AWS_BEDROCK_INFERENCE_PROFILE_ID:-}"  # Primary for Claude 3.5
    export AWS_BEDROCK_MODEL_ID="${AWS_BEDROCK_MODEL_ID:-}"  # Fallback for ON_DEMAND models
    export OPENAI_API_KEY="${OPENAI_API_KEY:-}"
    export USE_AGENT_QUERY="${USE_AGENT_QUERY:-}"  # Agent-based query processing (single source of truth: .env)
    export LOG_LEVEL="${LOG_LEVEL:-}"  # Logging level (single source of truth: .env)
    export ALLOWED_ORIGINS="${ALLOWED_ORIGINS:-}"  # CORS allowed origins (single source of truth: .env)
    export OPENAI_EMBED_MODEL="${OPENAI_EMBED_MODEL:-}"  # OpenAI embedding model (single source of truth: .env)
    
    # Database configuration (for Terragrunt get_env())
    export PGUSER="${PGUSER:-}"
    export PGPASSWORD="${PGPASSWORD:-}"
    export PGHOST="${PGHOST:-}"
    export PGPORT="${PGPORT:-}"
    export PGDATABASE="${PGDATABASE:-}"
    
    # Environment variable (for Terragrunt get_env())
    export ENVIRONMENT="${ENVIRONMENT:-}"
    
    # Container image configuration
    # IMAGE_PREFIX: Base image URI prefix (from .env or built dynamically)
    export IMAGE_PREFIX="${IMAGE_PREFIX:-}"
    
    # Local development configuration
    export LOCAL_SERVER_PORT="${LOCAL_SERVER_PORT:-5000}"  # Local API server port (default: 5000)
    
    # Spark + Delta Lake configuration (.env is single source of truth, no defaults)
    export DELTA_LAKE_PACKAGE="${DELTA_LAKE_PACKAGE:-}"  # No default - must be set in .env
    
    # Analytics scheduler configuration (for Terragrunt get_env())
    export ENABLE_ANALYTICS_SCHEDULER="${ENABLE_ANALYTICS_SCHEDULER:-}"
    export ANALYTICS_SCHEDULER_INTERVAL_SECONDS="${ANALYTICS_SCHEDULER_INTERVAL_SECONDS:-}"
    export SPARK_HOME="${SPARK_HOME:-}"
    export DELTA_TABLE_PATH="${DELTA_TABLE_PATH:-}"
    
    log_success "Loaded environment variables from $env_path"
    log_info "Note: AWS credential variables (AWS_ADMIN_*, AWS_BEDROCK_*) are loaded but not exported"
    log_info "      Use AWS profiles (admin/bedrock) instead via --profile flag or AWS_PROFILE env var"
    return 0
}

# Require Delta Lake package from environment (.env is single source of truth)
# This function validates that DELTA_LAKE_PACKAGE is set and provides helpful error message if not
# Usage: require_delta_lake_package
# Returns: 0 if set, 1 if not set (caller should exit on error)
require_delta_lake_package() {
    # Ensure .env file is loaded
    load_env_file || true
    
    # Check if DELTA_LAKE_PACKAGE is set (no defaults, .env is source of truth)
    if [ -z "${DELTA_LAKE_PACKAGE:-}" ]; then
        log_error "DELTA_LAKE_PACKAGE is not set in .env file"
        log_error ""
        log_error ".env file is the single source of truth for version configuration."
        log_error "Please add DELTA_LAKE_PACKAGE to your .env file."
        log_error ""
        log_info "Standard combination: io.delta:delta-spark_2.13:4.0.0"
        log_info "  - Spark: 4.0.1"
        log_info "  - Delta Lake: 4.0.0"
        log_info "  - Scala: 2.13.x"
        log_info ""
        log_info "Example .env entry:"
        log_info "  DELTA_LAKE_PACKAGE=io.delta:delta-spark_2.13:4.0.0"
        log_info ""
        log_info "You can run: ./run_scripts/local/setup-env.sh to create/update .env file"
        return 1
    fi
    
    log_info "Using Delta Lake package: $DELTA_LAKE_PACKAGE"
    log_info "Standard combination: Spark 4.0.1 + Delta Lake 4.0.0 + Scala 2.13"
    return 0
}

# Source logger if not already sourced
if [ -z "${RED:-}" ]; then
    source "$ENV_SCRIPT_DIR/logger.sh"
fi

# ============================================================================
# Container Image Configuration Functions
# ============================================================================
# NOTE: Container image functions have been moved to load-image-identifiers.sh
# for centralized cloud provider identifier management.
#
# For backward compatibility, we source load-image-identifiers.sh and re-export
# the functions. New code should source load-image-identifiers.sh directly.
#
# Functions available:
# - ensure_image_tag()
# - build_ecr_repo_uri()
# - generate_container_image()
# - resolve_container_image_for_aws()
#
# See: run_scripts/shared/load-image-identifiers.sh

# Source load-image-identifiers.sh to get container image functions
# Only source if not already sourced (to avoid re-sourcing)
if ! command -v resolve_container_image_for_aws >/dev/null 2>&1; then
    image_identifiers_file="$ENV_SCRIPT_DIR/load-image-identifiers.sh"
    if [ -f "$image_identifiers_file" ]; then
        source "$image_identifiers_file" 2>/dev/null || true
    fi
fi

