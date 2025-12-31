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
    
    log_success "Loaded environment variables from $env_path"
    log_info "Note: AWS credential variables (AWS_ADMIN_*, AWS_BEDROCK_*) are loaded but not exported"
    log_info "      Use AWS profiles (admin/bedrock) instead via --profile flag or AWS_PROFILE env var"
    return 0
}

# Source logger if not already sourced
if [ -z "${RED:-}" ]; then
    source "$ENV_SCRIPT_DIR/logger.sh"
fi

# ============================================================================
# Container Image Configuration Functions
# ============================================================================
# These functions centralize all image-related logic:
# - IMAGE_PREFIX: Base image URI prefix (from .env or built dynamically)
# - IMAGE_TAG: Image tag (auto-generated from git or manually set)
# - CONTAINER_IMAGE: Full image URI = IMAGE_PREFIX:IMAGE_TAG
#
# For AWS deployments, IMAGE_PREFIX is replaced with dynamically built ECR URI
# to ensure the correct repository is used regardless of .env configuration.

# Ensure IMAGE_TAG is generated if not set
# Uses git_helpers.sh to generate tag from git commit SHA
# Detects uncommitted changes and includes working tree hash when dirty
# Format: git-<short-sha>[-dirty-<working-tree-hash>]
ensure_image_tag() {
    if [ -z "${IMAGE_TAG:-}" ]; then
        # Source git_helpers if not already available
        if ! command -v generate_image_tag >/dev/null 2>&1; then
            source "$ENV_SCRIPT_DIR/git_helpers.sh"
        fi
        export IMAGE_TAG=$(generate_image_tag)
    fi
}

# Build ECR repository URI from AWS account and region
# Lazy evaluation: only builds when needed (requires AWS credentials)
# Returns: account.dkr.ecr.region.amazonaws.com/repo-name
# Usage: ECR_REPO_URI=$(build_ecr_repo_uri)
build_ecr_repo_uri() {
    local aws_profile="${AWS_PROFILE:-admin}"
    local aws_region="${AWS_REGION:-us-east-1}"
    local ecr_repo_name="${ECR_REPO_NAME:-fru-api}"
    
    # Get AWS account ID (requires AWS credentials)
    local aws_account_id
    aws_account_id=$(aws sts get-caller-identity --profile "$aws_profile" --query Account --output text 2>/dev/null || echo "")
    
    if [ -z "$aws_account_id" ]; then
        log_warning "Could not get AWS account ID. ECR URI cannot be built."
        return 1
    fi
    
    echo "${aws_account_id}.dkr.ecr.${aws_region}.amazonaws.com/${ecr_repo_name}"
}

# Generate CONTAINER_IMAGE from IMAGE_PREFIX:IMAGE_TAG
# This is the base format used everywhere
# If IMAGE_PREFIX not set, attempts to build from AWS account (fallback)
# Usage: CONTAINER_IMAGE=$(generate_container_image)
generate_container_image() {
    ensure_image_tag
    
    local image_prefix="${IMAGE_PREFIX:-}"
    
    if [ -z "$image_prefix" ]; then
        # Fallback: try to build from AWS account (if available)
        if ecr_uri=$(build_ecr_repo_uri 2>/dev/null); then
            image_prefix="$ecr_uri"
            log_info "IMAGE_PREFIX not set in .env, using AWS account-based ECR URI: $image_prefix"
        else
            log_warning "IMAGE_PREFIX not set in .env and cannot build from AWS account"
            log_warning "CONTAINER_IMAGE will be incomplete. Set IMAGE_PREFIX in .env or ensure AWS credentials are available."
            image_prefix="unknown"
        fi
    fi
    
    echo "${image_prefix}:${IMAGE_TAG}"
}

# Resolve CONTAINER_IMAGE for AWS deployments
# Replaces IMAGE_PREFIX with dynamically built ECR URI
# This ensures AWS deployments always use the correct ECR URI
# Usage: CONTAINER_IMAGE=$(resolve_container_image_for_aws)
resolve_container_image_for_aws() {
    local container_image="${CONTAINER_IMAGE:-}"
    
    # If CONTAINER_IMAGE not set, generate it first
    if [ -z "$container_image" ]; then
        container_image=$(generate_container_image)
    fi
    
    # Extract IMAGE_PREFIX and IMAGE_TAG from CONTAINER_IMAGE
    local image_prefix="${container_image%%:*}"
    local image_tag="${container_image##*:}"
    
    # Check if IMAGE_PREFIX needs to be replaced with ECR URI
    # Replace if:
    # 1. Contains variables (e.g., $IMAGE_PREFIX)
    # 2. Is "unknown" (fallback value)
    # 3. Doesn't look like an ECR URI (doesn't contain .dkr.ecr.)
    if [[ "$image_prefix" == *"\$"* ]] || \
       [[ "$image_prefix" == "unknown" ]] || \
       [[ "$image_prefix" != *".dkr.ecr."* ]]; then
        # Build ECR URI dynamically and replace IMAGE_PREFIX
        local ecr_uri
        if ecr_uri=$(build_ecr_repo_uri); then
            echo "${ecr_uri}:${image_tag}"
        else
            log_error "Cannot build ECR URI for AWS deployment"
            return 1
        fi
    else
        # Already a valid ECR URI, use as-is
        echo "$container_image"
    fi
}

