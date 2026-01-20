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
    log_info "[DEBUG] ensure_image_tag: Starting at $(date)" >&2
    if [ -z "${IMAGE_TAG:-}" ]; then
        log_info "[DEBUG] ensure_image_tag: IMAGE_TAG not set, will generate it" >&2
        # Source git_helpers if not already available
        if ! command -v generate_image_tag >/dev/null 2>&1; then
            log_info "[DEBUG] ensure_image_tag: Sourcing git_helpers.sh..." >&2
            source "$ENV_SCRIPT_DIR/git_helpers.sh"
            log_info "[DEBUG] ensure_image_tag: git_helpers.sh sourced" >&2
        fi
        log_info "[DEBUG] ensure_image_tag: About to call generate_image_tag..." >&2
        local gen_start=$(date +%s)
        # Capture only stdout (the actual tag), redirect stderr to /dev/null to avoid mixing warnings
        # Warnings from generate_image_tag go to stderr and will be visible in main output
        export IMAGE_TAG=$(generate_image_tag 2>/dev/null)
        local gen_elapsed=$(( $(date +%s) - gen_start ))
        log_info "[DEBUG] ensure_image_tag: generate_image_tag completed in ${gen_elapsed}s, IMAGE_TAG=$IMAGE_TAG" >&2
    else
        log_info "[DEBUG] ensure_image_tag: IMAGE_TAG already set: $IMAGE_TAG" >&2
    fi
    log_info "[DEBUG] ensure_image_tag: Completed at $(date)" >&2
}

# Build ECR repository URI from AWS account and region
# Lazy evaluation: only builds when needed (requires AWS credentials)
# Returns: account.dkr.ecr.region.amazonaws.com/repo-name
# Usage: ECR_REPO_URI=$(build_ecr_repo_uri)
build_ecr_repo_uri() {
    log_info "[DEBUG] build_ecr_repo_uri: Starting at $(date)" >&2
    local aws_profile="${AWS_PROFILE:-admin}"
    local aws_region="${AWS_REGION:-us-east-1}"
    local ecr_repo_name="${ECR_REPO_NAME:-fru-api}"
    log_info "[DEBUG] build_ecr_repo_uri: Using AWS_PROFILE=$aws_profile, AWS_REGION=$aws_region, ECR_REPO_NAME=$ecr_repo_name" >&2
    
    # Get AWS account ID (requires AWS credentials)
    log_info "[DEBUG] build_ecr_repo_uri: About to call 'aws sts get-caller-identity'..." >&2
    local aws_account_id
    local sts_start=$(date +%s)
    aws_account_id=$(aws sts get-caller-identity --profile "$aws_profile" --query Account --output text 2>/dev/null || echo "")
    local sts_elapsed=$(( $(date +%s) - sts_start ))
    log_info "[DEBUG] build_ecr_repo_uri: 'aws sts get-caller-identity' completed in ${sts_elapsed}s, result=$aws_account_id" >&2
    
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
    log_info "[DEBUG] generate_container_image: Starting at $(date)" >&2
    log_info "[DEBUG] generate_container_image: About to call ensure_image_tag..." >&2
    local ensure_start=$(date +%s)
    ensure_image_tag >&2  # Redirect all output to stderr
    local ensure_elapsed=$(( $(date +%s) - ensure_start ))
    log_info "[DEBUG] generate_container_image: ensure_image_tag completed in ${ensure_elapsed}s" >&2
    
    local image_prefix="${IMAGE_PREFIX:-}"
    log_info "[DEBUG] generate_container_image: IMAGE_PREFIX=$image_prefix" >&2
    
    if [ -z "$image_prefix" ]; then
        # Fallback: try to build from AWS account (if available)
        # Capture only stdout, redirect stderr to /dev/null to avoid mixing logs
        if ecr_uri=$(build_ecr_repo_uri 2>/dev/null); then
            image_prefix="$ecr_uri"
            log_info "IMAGE_PREFIX not set in .env, using AWS account-based ECR URI: $image_prefix" >&2
        else
            log_warning "IMAGE_PREFIX not set in .env and cannot build from AWS account" >&2
            log_warning "CONTAINER_IMAGE will be incomplete. Set IMAGE_PREFIX in .env or ensure AWS credentials are available." >&2
            image_prefix="unknown"
        fi
    fi
    
    # Output only the image string, no logs
    echo "${image_prefix}:${IMAGE_TAG}"
}

# Resolve CONTAINER_IMAGE for AWS deployments
# Replaces IMAGE_PREFIX with dynamically built ECR URI
# This ensures AWS deployments always use the correct ECR URI
# Usage: CONTAINER_IMAGE=$(resolve_container_image_for_aws)
resolve_container_image_for_aws() {
    log_info "[DEBUG] resolve_container_image_for_aws: Starting at $(date)" >&2
    local container_image="${CONTAINER_IMAGE:-}"
    log_info "[DEBUG] resolve_container_image_for_aws: CONTAINER_IMAGE=$container_image" >&2
    
    # If CONTAINER_IMAGE not set, generate it first
    if [ -z "$container_image" ]; then
        log_info "[DEBUG] resolve_container_image_for_aws: CONTAINER_IMAGE not set, calling generate_container_image..." >&2
        local gen_start=$(date +%s)
        # Capture only stdout (the actual return value), redirect stderr to /dev/null
        container_image=$(generate_container_image 2>/dev/null)
        local gen_elapsed=$(( $(date +%s) - gen_start ))
        log_info "[DEBUG] resolve_container_image_for_aws: generate_container_image completed in ${gen_elapsed}s, result=$container_image" >&2
    fi
    
    # Extract IMAGE_PREFIX and IMAGE_TAG from CONTAINER_IMAGE
    local image_prefix="${container_image%%:*}"
    local image_tag="${container_image##*:}"
    
    # Check if IMAGE_PREFIX needs to be replaced with ECR URI
    # Replace if:
    # 1. Contains variables (e.g., $IMAGE_PREFIX)
    # 2. Is "unknown" (fallback value)
    # 3. Doesn't look like an ECR URI (doesn't contain .dkr.ecr.)
    log_info "[DEBUG] resolve_container_image_for_aws: Checking if IMAGE_PREFIX needs replacement..." >&2
    log_info "[DEBUG] resolve_container_image_for_aws: image_prefix=$image_prefix, image_tag=$image_tag" >&2
    if [[ "$image_prefix" == *"\$"* ]] || \
       [[ "$image_prefix" == "unknown" ]] || \
       [[ "$image_prefix" != *".dkr.ecr."* ]]; then
        log_info "[DEBUG] resolve_container_image_for_aws: IMAGE_PREFIX needs replacement, calling build_ecr_repo_uri..." >&2
        # Build ECR URI dynamically and replace IMAGE_PREFIX
        local ecr_uri
        local build_start=$(date +%s)
        # Capture only stdout (the actual ECR URI), redirect stderr to /dev/null
        if ecr_uri=$(build_ecr_repo_uri 2>/dev/null); then
            local build_elapsed=$(( $(date +%s) - build_start ))
            log_info "[DEBUG] resolve_container_image_for_aws: build_ecr_repo_uri completed in ${build_elapsed}s, result=$ecr_uri" >&2
            # Output only the image string, no logs
            echo "${ecr_uri}:${image_tag}"
        else
            log_error "Cannot build ECR URI for AWS deployment" >&2
            return 1
        fi
    else
        log_info "[DEBUG] resolve_container_image_for_aws: IMAGE_PREFIX already valid ECR URI, using as-is" >&2
        # Already a valid ECR URI, use as-is
        echo "$container_image"
    fi
    log_info "[DEBUG] resolve_container_image_for_aws: Completed at $(date)" >&2
}

