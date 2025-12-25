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
    load_env_file 2>/dev/null || log_warning "Could not load .env"
    
    # Export variables for child scripts (same as auto_verify_and_manual_hint.sh)
    export DEPLOYMENT_TYPE ENVIRONMENT DRY_RUN REPO_ROOT
    
    # Step 1: Fetch deployment information
    log_step "Fetching deployment information from Terraform..."
    # shellcheck source=/dev/null
    source "$REPO_ROOT/run_scripts/aws/verification/fetch-deployment-info.sh" "$DEPLOYMENT_TYPE" "$ENVIRONMENT" "$DRY_RUN" 2>/dev/null || {
        log_error "Failed to source fetch-deployment-info.sh"
        exit 1
    }
    
    # fetch-deployment-info.sh sets API_URL and FRONTEND_URL when possible
    # Call fetch_terraform_outputs to populate ALB_DNS, CLOUDFRONT_DOMAIN, etc.
    fetch_terraform_outputs

    if [[ -n "${API_URL:-}" ]]; then
        API_BASE_URL="$API_URL"
    else
        log_error "Could not determine API URL from Terraform outputs for aws test env."
        log_error "fetch-deployment-info.sh and fetch_terraform_outputs() did not populate API_URL properly"
        exit 1
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

