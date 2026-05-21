#!/bin/bash
# Centralized Cloud Provider Image Identifiers Loading
# Provides cloud-specific identifier resolution (AWS Account ID, ECR URI, Container Image, etc.)
# Usage: source load-image-identifiers.sh && load_image_identifiers [aws|gcp|azure|local]
#
# This script centralizes all cloud provider identifier resolution to:
# - Eliminate duplicate AWS STS calls (DRY principle)
# - Provide consistent retry/timeout logic
# - Support multiple cloud providers (AWS, GCP, Azure, Local)
# - Cache resolved identifiers to avoid redundant API calls

# Ensure logger is available
if ! command -v log_info >/dev/null 2>&1; then
    # Define minimal logging if logger.sh not sourced
    log_info() { echo "[INFO] $*" >&2; }
    log_success() { echo "[SUCCESS] $*" >&2; }
    log_warning() { echo "[WARNING] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

# Detect cloud provider from script path or environment
detect_cloud_provider() {
    local script_path="${BASH_SOURCE[1]:-${BASH_SOURCE[0]:-}}"
    if [[ "$script_path" == *"/aws/"* ]]; then
        echo "aws"
    elif [[ "$script_path" == *"/gcp/"* ]]; then
        echo "gcp"
    elif [[ "$script_path" == *"/azure/"* ]]; then
        echo "azure"
    else
        echo "local"
    fi
}

# ============================================================================
# AWS Identifier Resolution
# ============================================================================

# Resolve AWS Account ID with retry and timeout
# Retries every 10 seconds, timeout after 3 minutes (18 attempts)
# Usage: resolve_aws_account_id_with_retry
resolve_aws_account_id_with_retry() {
    # Known dummy/test AWS account IDs that should be rejected
    local dummy_account_ids=(
        "999999999999"  # Standard dummy/test value (used in all examples/docs)
        "000000000000"  # Zero account ID
        "111111111111"  # Test pattern
        "123456789012"  # Legacy placeholder (deprecated, use 999999999999)
    )
    
    # Check if AWS_ACCOUNT_ID is set and not a dummy value
    if [ -n "${AWS_ACCOUNT_ID:-}" ] && [[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
        # Validate it's not a dummy/test value
        local is_dummy=false
        for dummy_id in "${dummy_account_ids[@]}"; do
            if [ "$AWS_ACCOUNT_ID" = "$dummy_id" ]; then
                is_dummy=true
                break
            fi
        done
        
        if [ "$is_dummy" = false ]; then
            log_info "Using cached AWS Account ID: $AWS_ACCOUNT_ID"
            return 0
        else
            log_warning "AWS_ACCOUNT_ID is set to dummy/test value '$AWS_ACCOUNT_ID'"
            log_info "Ignoring dummy value and resolving real AWS Account ID..."
            unset AWS_ACCOUNT_ID  # Clear dummy value to force real resolution
        fi
    fi
    
    local max_attempts=18  # 18 * 10s = 3 minutes
    local retry_interval=10
    local timeout=180  # 3 minutes total
    local aws_profile="${AWS_PROFILE:-admin}"
    
    log_info "Resolving AWS Account ID (max ${timeout}s, retry every ${retry_interval}s)..."
    
    for attempt in $(seq 1 $max_attempts); do
        local account_id
        account_id=$(aws sts get-caller-identity \
            --profile "$aws_profile" \
            --query Account \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$account_id" ] && [[ "$account_id" =~ ^[0-9]{12}$ ]]; then
            export AWS_ACCOUNT_ID="$account_id"
            log_success "AWS Account ID resolved: $account_id (attempt $attempt/$max_attempts)"
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            log_warning "Attempt $attempt/$max_attempts failed. Retrying in ${retry_interval}s..."
            sleep $retry_interval
        fi
    done
    
    log_error "Failed to resolve AWS Account ID after $max_attempts attempts (${timeout}s)"
    log_error "Please check:"
    log_error "  1. AWS credentials are configured: aws configure --profile $aws_profile"
    log_error "  2. AWS credentials are valid: aws sts get-caller-identity --profile $aws_profile"
    log_error "  3. Network connectivity to AWS STS service"
    return 1
}

# Resolve ECR Repository URI
# Requires AWS_ACCOUNT_ID to be set (via resolve_aws_account_id_with_retry)
# Usage: resolve_ecr_repo_uri
resolve_ecr_repo_uri() {
    if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
        log_error "AWS_ACCOUNT_ID not set. Cannot build ECR URI."
        log_error "Call resolve_aws_account_id_with_retry() first."
        return 1
    fi
    
    # If already resolved, use cached value
    if [ -n "${ECR_REPO_URI:-}" ] && [[ "$ECR_REPO_URI" == *".dkr.ecr."* ]]; then
        log_info "Using cached ECR Repository URI: $ECR_REPO_URI" >&2
        return 0
    fi
    
    local aws_region="${AWS_REGION:-us-east-1}"
    local ecr_repo_name="${ECR_REPO_NAME:-fru-api}"
    
    export ECR_REPO_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${aws_region}.amazonaws.com/${ecr_repo_name}"
    log_info "ECR Repository URI: $ECR_REPO_URI" >&2
    return 0
}

# Build ECR repository URI from AWS account and region
# This is a wrapper that uses the centralized AWS_ACCOUNT_ID
# Usage: ECR_REPO_URI=$(build_ecr_repo_uri)
# NOTE: This function outputs ONLY the URI to stdout (no log messages)
# Log messages from resolve_ecr_repo_uri() are suppressed to prevent contamination
build_ecr_repo_uri() {
    # If AWS_ACCOUNT_ID not set, try to resolve it
    if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
        if ! resolve_aws_account_id_with_retry >/dev/null 2>&1; then
            log_warning "Could not get AWS account ID. ECR URI cannot be built." >&2
            return 1
        fi
    fi
    
    # Call resolve_ecr_repo_uri but suppress ALL output (log_info goes to stdout!)
    # We only want the ECR_REPO_URI variable set, not the log messages
    resolve_ecr_repo_uri >/dev/null 2>&1
    
    # Output ONLY the URI to stdout (no log messages)
    # This ensures command substitution captures only the URI
    echo "$ECR_REPO_URI"
}

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
        # git_helpers.sh lives in orchestration/common/, we are in orchestration/common/env/
        if ! command -v generate_image_tag >/dev/null 2>&1; then
            local env_script_dir="${ENV_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
            local git_helpers_path="$env_script_dir/../git_helpers.sh"
            log_info "[DEBUG] ensure_image_tag: Sourcing git_helpers.sh from $git_helpers_path" >&2
            if [ -f "$git_helpers_path" ]; then
                source "$git_helpers_path" 2>/dev/null || {
                    log_warning "Could not source git_helpers.sh"
                    return 1
                }
                log_info "[DEBUG] ensure_image_tag: git_helpers.sh sourced" >&2
            else
                log_warning "git_helpers.sh not found at $git_helpers_path"
                return 1
            fi
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
        # Capture only stdout (URI), suppress stderr AND stdout from build_ecr_repo_uri
        # (build_ecr_repo_uri outputs URI to stdout, but resolve_ecr_repo_uri logs to stdout via log_info)
        if ecr_uri=$(build_ecr_repo_uri 2>&1 | grep -v "^\[" | grep -v "ECR Repository URI" | head -1); then
            # Clean the URI (remove any log messages that might have leaked through)
            ecr_uri=$(echo "$ecr_uri" | grep -E "^[0-9]+\.dkr\.ecr\." | head -1)
            if [ -n "$ecr_uri" ]; then
                image_prefix="$ecr_uri"
                log_info "IMAGE_PREFIX not set in .env, using AWS account-based ECR URI: $image_prefix" >&2
            else
                log_warning "IMAGE_PREFIX not set in .env and cannot build from AWS account" >&2
                log_warning "CONTAINER_IMAGE will be incomplete. Set IMAGE_PREFIX in .env or ensure AWS credentials are available." >&2
                image_prefix="unknown"
            fi
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
        # Capture stdout (URI), filter out any log messages that might leak through
        # build_ecr_repo_uri should only output URI, but resolve_ecr_repo_uri logs to stdout
        local build_output
        build_output=$(build_ecr_repo_uri 2>&1)
        # Extract only the ECR URI (format: account.dkr.ecr.region.amazonaws.com/repo)
        # Use a flexible pattern: account.dkr.ecr.<region>.amazonaws.com/<repo>
        # Region can contain hyphens (e.g., us-east-1), so use .* for flexibility
        ecr_uri=$(echo "$build_output" | grep -E "^[0-9]+\.dkr\.ecr\.[^[:space:]]+\.amazonaws\.com/[a-z0-9_-]+$" | head -1)
        
        if [ -n "$ecr_uri" ]; then
            local build_elapsed=$(( $(date +%s) - build_start ))
            log_info "[DEBUG] resolve_container_image_for_aws: build_ecr_repo_uri completed in ${build_elapsed}s, result=$ecr_uri" >&2
            # Output only the image string, no logs
            echo "${ecr_uri}:${image_tag}"
        else
            log_error "Cannot build ECR URI for AWS deployment" >&2
            log_error "build_ecr_repo_uri output: $build_output" >&2
            return 1
        fi
    else
        log_info "[DEBUG] resolve_container_image_for_aws: IMAGE_PREFIX already valid ECR URI, using as-is" >&2
        # Already a valid ECR URI, use as-is
        echo "$container_image"
    fi
    log_info "[DEBUG] resolve_container_image_for_aws: Completed at $(date)" >&2
}

# ============================================================================
# Cloud Provider-Specific Loaders
# ============================================================================

# Load AWS identifiers
load_aws_identifiers() {
    log_step "Loading AWS image identifiers"
    
    # Resolve AWS Account ID with retry/timeout
    if ! resolve_aws_account_id_with_retry; then
        log_error "Failed to resolve AWS Account ID. Cannot proceed."
        return 1
    fi
    
    # Resolve ECR Repository URI
    if ! resolve_ecr_repo_uri; then
        log_error "Failed to resolve ECR Repository URI. Cannot proceed."
        return 1
    fi
    
    # Resolve CONTAINER_IMAGE for AWS
    local container_image
    # Capture stdout (image URI), filter out any log messages that might leak through
    local resolve_output
    resolve_output=$(resolve_container_image_for_aws 2>&1)
    # Extract only the container image URI (format: repo:tag)
    # Use a flexible pattern: account.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>
    # Region can contain hyphens (e.g., us-east-1), so use .* for flexibility
    container_image=$(echo "$resolve_output" | grep -E "^[0-9]+\.dkr\.ecr\.[^[:space:]]+\.amazonaws\.com/[a-z0-9_-]+:[a-zA-Z0-9_.-]+$" | head -1)
    
    if [ -n "$container_image" ]; then
        export CONTAINER_IMAGE="$container_image"
        log_success "Resolved CONTAINER_IMAGE: $container_image"
    else
        log_warning "Could not resolve CONTAINER_IMAGE, but continuing..."
        log_warning "resolve_container_image_for_aws output: $resolve_output"
    fi
    
    log_success "AWS identifiers loaded:"
    log_info "  AWS_ACCOUNT_ID: ${AWS_ACCOUNT_ID:-<not set>}"
    log_info "  ECR_REPO_URI: ${ECR_REPO_URI:-<not set>}"
    log_info "  CONTAINER_IMAGE: ${CONTAINER_IMAGE:-<not set>}"
    
    return 0
}

# Load GCP identifiers (future)
load_gcp_identifiers() {
    log_step "Loading GCP image identifiers"
    log_warning "GCP support not yet implemented"
    return 0
}

# Load Azure identifiers (future)
load_azure_identifiers() {
    log_step "Loading Azure image identifiers"
    log_warning "Azure support not yet implemented"
    return 0
}

# Load local identifiers (no cloud provider)
load_local_identifiers() {
    log_info "Local deployment - skipping cloud provider identifier resolution"
    return 0
}

# ============================================================================
# Main Entry Point
# ============================================================================

# Main function to load image identifiers based on cloud provider
# Usage: load_image_identifiers [aws|gcp|azure|local]
# If no argument provided, auto-detects from script path
load_image_identifiers() {
    local cloud_provider="${1:-}"
    
    # Auto-detect if not provided
    if [ -z "$cloud_provider" ]; then
        cloud_provider=$(detect_cloud_provider)
        log_info "Auto-detected cloud provider: $cloud_provider"
    fi
    
    # Also check environment variable
    if [ -n "${CLOUD_PROVIDER:-}" ]; then
        cloud_provider="$CLOUD_PROVIDER"
        log_info "Using cloud provider from CLOUD_PROVIDER env var: $cloud_provider"
    fi
    
    case "$cloud_provider" in
        aws)
            load_aws_identifiers
            ;;
        gcp)
            load_gcp_identifiers
            ;;
        azure)
            load_azure_identifiers
            ;;
        local|*)
            load_local_identifiers
            ;;
    esac
}

# If script is sourced (not executed), export the main function
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f load_image_identifiers
    export -f resolve_aws_account_id_with_retry
    export -f resolve_ecr_repo_uri
    export -f build_ecr_repo_uri
    export -f ensure_image_tag
    export -f generate_container_image
    export -f resolve_container_image_for_aws
fi
