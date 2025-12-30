#!/usr/bin/env bash
# Environment setup functions for test scripts (AWS and local)

# Setup AWS test environment
# Sets: API_BASE_URL
# Also performs service status check (fail-fast if not ready)
setup_aws_environment() {
    # Set required variables that fetch-deployment-info.sh expects
    DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE:-ecs-full}"
    ENVIRONMENT="${ENVIRONMENT:-dev}"
    DRY_RUN="${DRY_RUN:-false}"
    
    # Source the same utilities as auto_verify_and_manual_hint.sh does
    # shellcheck source=/dev/null
    source "$REPO_ROOT/run_scripts/common/logger.sh" 2>/dev/null || {
        echo "ERROR: Could not source logger.sh" >&2
        exit 1
    }
    # shellcheck source=/dev/null
    source "$REPO_ROOT/run_scripts/common/load-env.sh" 2>/dev/null || {
        echo "ERROR: Could not source load-env.sh" >&2
        exit 1
    }
    # shellcheck source=/dev/null
    if ! load_env_file; then
        log_error "Failed to load .env file"
        exit 1
    fi
    
    # Debug: Verify critical variables are exported
    if [ -z "${TF_STATE_BUCKET:-}" ]; then
        log_warning "TF_STATE_BUCKET is not set after load_env_file()"
    fi
    if [ -z "${AWS_PROFILE:-}" ]; then
        log_warning "AWS_PROFILE is not set after load_env_file()"
    fi
    
    # Export variables for child scripts (same as auto_verify_and_manual_hint.sh)
    export DEPLOYMENT_TYPE ENVIRONMENT DRY_RUN REPO_ROOT
    
    # Get AWS region for cache key
    local aws_region="${AWS_REGION:-us-east-1}"
    
    # Step 1: Fetch deployment information
    # Check cache first if --use-cached-aws-val flag is set
    local use_cache="${USE_CACHED_AWS_VAL:-false}"
    local cache_hit=false
    
    if [[ "$use_cache" == "true" ]]; then
        # Source cache utilities
        # shellcheck source=/dev/null
        source "$(dirname "${BASH_SOURCE[0]}")/test_cache.sh" 2>/dev/null || {
            log_warning "Could not source test_cache.sh, proceeding without cache"
        }
        
        # Try to load cached values
        if load_cached_values "$ENVIRONMENT" "$DEPLOYMENT_TYPE" "$aws_region"; then
            # Compute derived variables from cached base variables
            if [ -n "${ALB_DNS:-}" ]; then
                API_URL="http://$ALB_DNS"
                if [ -z "${ECS_CLUSTER_NAME:-}" ] && [ -n "${ECS_CLUSTER_ID:-}" ]; then
                    ECS_CLUSTER_NAME=$(echo "$ECS_CLUSTER_ID" | awk -F'/' '{print $NF}' || echo "")
                fi
                if [ -n "${CLOUDFRONT_DOMAIN:-}" ]; then
                    FRONTEND_URL="https://$CLOUDFRONT_DOMAIN"
                fi
                
                if [ -n "$API_URL" ]; then
                    log_info "Using cached AWS values (loaded from cache)"
                    API_BASE_URL="$API_URL"
                    cache_hit=true
                fi
            fi
        fi
    fi
    
    # If cache miss or not using cache, fetch from AWS
    if [[ "$cache_hit" == "false" ]]; then
        # Optimization: Skip expensive fetch operations if API_URL is already set
        # Note: This optimization only helps if setup_aws_environment() is called multiple times
        # in the same shell session. For normal usage (each test script runs in its own shell),
        # this check will always be false on the first call. However, it's harmless and provides
        # a safety net if someone manually sources test scripts or runs them in a loop.
        if [[ -n "${API_URL:-}" ]]; then
            log_info "API_URL already set: ${API_URL}, skipping deployment info fetch"
            API_BASE_URL="$API_URL"
        else
            log_step "Fetching deployment information from Terraform..."
            
            # Debug: Verify variables are still set before sourcing fetch-deployment-info.sh
        log_info "Before sourcing fetch-deployment-info.sh:"
        log_info "  TF_STATE_BUCKET=[${TF_STATE_BUCKET:-NOT SET}]"
        log_info "  AWS_PROFILE=[${AWS_PROFILE:-NOT SET}]"
        
        # shellcheck source=/dev/null
        source "$REPO_ROOT/run_scripts/aws/verification/fetch-deployment-info.sh" "$DEPLOYMENT_TYPE" "$ENVIRONMENT" "$DRY_RUN" 2>/dev/null || {
            log_error "Failed to source fetch-deployment-info.sh"
            exit 1
        }
        
        # Debug: Verify variables are still set after sourcing
        log_info "After sourcing fetch-deployment-info.sh:"
        log_info "  TF_STATE_BUCKET=[${TF_STATE_BUCKET:-NOT SET}]"
        log_info "  AWS_PROFILE=[${AWS_PROFILE:-NOT SET}]"
        
        # fetch-deployment-info.sh already calls fetch_terraform_outputs() when sourced (line 243)
        # No need to call it again explicitly - it's redundant
        # Verify API_URL was set after sourcing
        if [[ -z "${API_URL:-}" ]]; then
            log_error "Could not determine API URL from Terraform outputs for aws test env."
            log_error "fetch-deployment-info.sh did not populate API_URL properly"
            exit 1
        fi
        API_BASE_URL="$API_URL"
        
            # Write to cache after successful fetch (always update cache to keep it fresh)
            # Source cache utilities if not already sourced
            if ! command -v write_cache_value >/dev/null 2>&1; then
                # shellcheck source=/dev/null
                source "$(dirname "${BASH_SOURCE[0]}")/test_cache.sh" 2>/dev/null || true
            fi
            
            # Write cached values (non-fatal - log warning if fails)
            if command -v write_cache_value >/dev/null 2>&1; then
                write_cache_value "ALB_DNS" "$ENVIRONMENT" "$DEPLOYMENT_TYPE" "$aws_region" "${ALB_DNS:-}" "" || true
                write_cache_value "CLOUDFRONT_DOMAIN" "$ENVIRONMENT" "$DEPLOYMENT_TYPE" "$aws_region" "${CLOUDFRONT_DOMAIN:-}" "" || true
                write_cache_value "ECS_CLUSTER_ID" "$ENVIRONMENT" "$DEPLOYMENT_TYPE" "$aws_region" "${ECS_CLUSTER_ID:-}" "" || true
                write_cache_value "ECS_SERVICE_NAME" "$ENVIRONMENT" "$DEPLOYMENT_TYPE" "$aws_region" "${ECS_SERVICE_NAME:-}" "" || true
                if [[ "$use_cache" == "true" ]]; then
                    log_info "Updated cache with fetched AWS values"
                fi
            fi
        fi
    fi
    
    # Step 2: Check service status (fail-fast if services are not ready)
    log_step "Checking service status (fail-fast if not ready)..."
    VERIFICATION_DIR="$REPO_ROOT/run_scripts/aws/verification"
    # shellcheck source=/dev/null
    source "$VERIFICATION_DIR/check-service-status.sh" || {
        log_error "Failed to source check-service-status.sh"
        exit 1
    }
    
    # Check service status - fail-fast if it returns non-zero
    if ! check_service_status "$DEPLOYMENT_TYPE" "$ENVIRONMENT"; then
        log_error "Service status check failed. Services are not ready for testing."
        log_error "Please ensure ECS tasks are running and API is healthy before running tests."
        exit 1
    fi
    log_success "Service status check passed"
    
    export API_BASE_URL
}

# Setup local test environment
# Sets: API_BASE_URL
setup_local_environment() {
    # Default local API URL (matches docker-compose port; adjust if needed)
    API_BASE_URL="http://localhost:5001"
    
    # For local, we can do a simple health check
    if command -v curl >/dev/null 2>&1; then
        if ! curl -sf "$API_BASE_URL/health" >/dev/null 2>&1; then
            echo "WARNING: Local API health check failed. Is the API running at $API_BASE_URL?" >&2
            echo "Continuing anyway..." >&2
        fi
    fi
    
    export API_BASE_URL
}

# Setup test environment based on TEST_ENV
# Calls either setup_aws_environment or setup_local_environment
setup_test_environment_by_type() {
    if [[ "$TEST_ENV" == "aws" ]]; then
        setup_aws_environment
    elif [[ "$TEST_ENV" == "local" ]]; then
        setup_local_environment
    else
        echo "ERROR: Invalid TEST_ENV: $TEST_ENV (must be 'aws' or 'local')" >&2
        exit 1
    fi
}

