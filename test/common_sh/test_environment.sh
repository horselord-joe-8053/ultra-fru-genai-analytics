#!/usr/bin/env bash
# Environment setup functions for test scripts (AWS and local)

# Setup AWS test environment
# Sets: API_BASE_URL
# Also performs service status check (fail-fast if not ready)
# Supports both ECS and EKS deployments via CONTAINER_TYPE (new) or DEPLOYMENT_TYPE (backward compatibility)
setup_aws_environment() {
    # Determine container type from CONTAINER_TYPE
    local container_type="${CONTAINER_TYPE:-ecs}"  # Default to ecs if not specified
    
    ENVIRONMENT="${ENVIRONMENT:-dev}"
    DRY_RUN="${DRY_RUN:-false}"
    
    # Export CONTAINER_TYPE for child scripts
    export CONTAINER_TYPE="$container_type"
    
    # Source the same utilities as auto_verify_and_manual_hint.sh does
    # shellcheck source=/dev/null
    source "$REPO_ROOT/run_scripts/shared/logger.sh" 2>/dev/null || {
        echo "ERROR: Could not source logger.sh" >&2
        exit 1
    }
    # shellcheck source=/dev/null
    source "$REPO_ROOT/run_scripts/shared/load-env.sh" 2>/dev/null || {
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
        
        # Get test_env from environment (set by run_test_suite.sh)
        local test_env="${TEST_ENV:-aws}"  # Default to 'aws'
        
        # Try to load cached values (cache key uses container type for consistency)
        local cache_key="${container_type}-full"  # Use format for cache compatibility
        if load_cached_values "$ENVIRONMENT" "$cache_key" "$aws_region" "$test_env"; then
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
        # If not using cache, clear any existing deployment variables to force fresh fetch
        # This prevents stale values from previous test runs in the same shell session
        # from being used, ensuring we always fetch fresh values when cache is not used
        if [[ "$use_cache" == "false" ]]; then
            unset API_URL ALB_DNS CLOUDFRONT_DOMAIN ECS_CLUSTER_ID ECS_CLUSTER_NAME ECS_SERVICE_NAME FRONTEND_URL
            log_info "Not using cache: cleared existing deployment variables to force fresh fetch"
        fi
        
        log_step "Fetching deployment information from Terraform..."
        
        # Debug: Verify variables are still set before sourcing fetch-deployment-info.sh
        log_info "Before sourcing fetch-deployment-info.sh:"
        log_info "  TF_STATE_BUCKET=[${TF_STATE_BUCKET:-NOT SET}]"
        log_info "  AWS_PROFILE=[${AWS_PROFILE:-NOT SET}]"
        log_info "  CONTAINER_TYPE=[${CONTAINER_TYPE:-NOT SET}]"
        
        # Export CONTAINER_TYPE for fetch-deployment-info.sh
        export CONTAINER_TYPE="$container_type"
        
        # shellcheck source=/dev/null
        source "$REPO_ROOT/run_scripts/main_application_scripts/aws/verification/fetch-deployment-info.sh" "" "$ENVIRONMENT" "$DRY_RUN" 2>/dev/null || {
            log_error "Failed to source fetch-deployment-info.sh"
            exit 1
        }
        
        # Debug: Verify variables are still set after sourcing
        log_info "After sourcing fetch-deployment-info.sh:"
        log_info "  TF_STATE_BUCKET=[${TF_STATE_BUCKET:-NOT SET}]"
        log_info "  AWS_PROFILE=[${AWS_PROFILE:-NOT SET}]"
        
        # fetch-deployment-info.sh already calls fetch_terraform_outputs() when sourced
        # Verify API_URL was set after sourcing
        # For EKS, also check K8S_INGRESS_HOST or K8S_SERVICE_IP if API_URL is not set  
        # Note: EKS uses NGINX Ingress Controller which creates an NLB (not ALB), so always use HTTP
        if [[ -z "${API_URL:-}" ]]; then
            if [ "$container_type" = "eks" ] && [ -n "${K8S_INGRESS_HOST:-}" ]; then
                API_URL="http://$K8S_INGRESS_HOST"
                log_info "Using EKS ingress host for API URL: $API_URL"
            elif [ "$container_type" = "eks" ] && [ -n "${K8S_SERVICE_IP:-}" ]; then
                API_URL="http://$K8S_SERVICE_IP"
                log_info "Using EKS service IP for API URL: $API_URL"
            elif [ "$container_type" = "eks" ]; then
                # Try to get from kubectl if available
                if command -v kubectl >/dev/null 2>&1 && kubectl config current-context >/dev/null 2>&1; then
                    log_info "Attempting to fetch API URL from Kubernetes ingress/service..."
                    local k8s_ingress=$(kubectl get ingress fru-api-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
                    if [ -n "$k8s_ingress" ]; then
                        API_URL="http://$k8s_ingress"
                        log_info "Found EKS ingress host: $API_URL"
                    else
                        local k8s_service=$(kubectl get svc fru-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
                        if [ -n "$k8s_service" ]; then
                            API_URL="http://$k8s_service"
                            log_info "Found EKS service host: $API_URL"
                        fi
                    fi
                fi
            fi
            
        if [[ -z "${API_URL:-}" ]]; then
            log_error "Could not determine API URL from Terraform outputs for aws test env."
            log_error "fetch-deployment-info.sh did not populate API_URL properly"
                log_error "Container type: $container_type"
            exit 1
            fi
        fi
        API_BASE_URL="$API_URL"
        
        # Write to cache after successful fetch (always update cache to keep it fresh)
        # Source cache utilities if not already sourced
        if ! command -v write_cache_value >/dev/null 2>&1; then
            # shellcheck source=/dev/null
            source "$(dirname "${BASH_SOURCE[0]}")/test_cache.sh" 2>/dev/null || true
        fi
        
        # Write cached values (non-fatal - log warning if fails)
        # Get test_env from environment (set by run_test_suite.sh)
        local test_env="${TEST_ENV:-aws}"  # Default to 'aws'
        
        # Use cache key format for compatibility
        local cache_key="${container_type}-full"  # Use format for cache compatibility
        
        if command -v write_cache_value >/dev/null 2>&1; then
            write_cache_value "ALB_DNS" "$ENVIRONMENT" "$cache_key" "$aws_region" "$test_env" "${ALB_DNS:-}" "" || true
            write_cache_value "CLOUDFRONT_DOMAIN" "$ENVIRONMENT" "$cache_key" "$aws_region" "$test_env" "${CLOUDFRONT_DOMAIN:-}" "" || true
            write_cache_value "ECS_CLUSTER_ID" "$ENVIRONMENT" "$cache_key" "$aws_region" "$test_env" "${ECS_CLUSTER_ID:-}" "" || true
            write_cache_value "ECS_SERVICE_NAME" "$ENVIRONMENT" "$cache_key" "$aws_region" "$test_env" "${ECS_SERVICE_NAME:-}" "" || true
            if [[ "$use_cache" == "true" ]]; then
                log_info "Updated cache with fetched AWS values"
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
    if ! check_service_status "$container_type" "$ENVIRONMENT"; then
        log_error "Service status check failed. Services are not ready for testing."
        if [ "$container_type" = "ecs" ]; then
        log_error "Please ensure ECS tasks are running and API is healthy before running tests."
        elif [ "$container_type" = "eks" ]; then
            log_error "Please ensure EKS pods are running and API is healthy before running tests."
        fi
        exit 1
    fi
    log_success "Service status check passed"
    
    export API_BASE_URL
}

# Check if Docker services are running
# Returns 0 if both fru_db and fru_api are running, 1 otherwise
check_services_running() {
    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi
    
    local db_running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^fru_db$" || echo "0")
    local api_running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^fru_api$" || echo "0")
    
    if [ "$db_running" -eq 1 ] && [ "$api_running" -eq 1 ]; then
        return 0  # Both services running
    fi
    return 1  # Services not running
}

# Check if all required Docker images exist
# Returns 0 if all images exist, 1 if any are missing
check_images_exist() {
    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi
    
    # Check db image (pulled from Docker Hub)
    if ! docker image inspect ankane/pgvector:latest >/dev/null 2>&1; then
        return 1  # Missing
    fi
    
    # Check api image (built locally)
    # Get project name from docker-compose (defaults to directory name)
    local docker_dir="${REPO_ROOT}/infra/docker"
    if [ ! -d "$docker_dir" ]; then
        return 1
    fi
    
    cd "$docker_dir"
    # Get the actual image name that docker-compose would use
    # Try to get it from docker compose config
    local api_image_name
    api_image_name=$(docker compose config --images api 2>/dev/null | head -1 || echo "")
    
    if [ -z "$api_image_name" ]; then
        # Fallback: try common naming patterns
        local project_name=$(basename "$(cd "$docker_dir/../.." && pwd)" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
        api_image_name="${project_name}_api"
    fi
    
    # Check if the image exists
    if ! docker image inspect "$api_image_name" >/dev/null 2>&1; then
        return 1  # Missing
    fi
    
    return 0  # All images exist
}

# Setup local test environment
# Sets: API_BASE_URL
# Automatically ensures Docker services are running (implicit requirement for local testing)
# Behavior:
#   1. If services are up → runs tests immediately (fast)
#   2. If services are down but images exist → starts services (no build)
#   3. If services are down and images missing → builds missing images, then starts
#   4. If --force-rebuild-local-img → rebuilds all images, then starts
setup_local_environment() {
    # Load .env file to get LOCAL_SERVER_PORT if available
    if [ -z "${REPO_ROOT:-}" ]; then
        # Try to detect REPO_ROOT if not set
        local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        export REPO_ROOT="$(cd "$script_dir/../.." && pwd)"
    fi
    
    # Source load-env.sh to get LOCAL_SERVER_PORT
    # shellcheck source=/dev/null
    if [ -f "$REPO_ROOT/run_scripts/shared/load-env.sh" ]; then
        source "$REPO_ROOT/run_scripts/shared/load-env.sh" 2>/dev/null || true
        # Load .env file if it exists
        if [ -f "$REPO_ROOT/.env" ]; then
            load_env_file 2>/dev/null || true
        fi
    fi
    
    # Use LOCAL_SERVER_PORT from .env, defaulting to 5001 for local testing
    local server_port="${LOCAL_SERVER_PORT:-5001}"
    API_BASE_URL="http://localhost:${server_port}"
    
    # Get force rebuild flag (from test runner)
    local force_rebuild="${FORCE_REBUILD_LOCAL_IMG:-false}"
    
    # Ensure Docker is available
    if ! command -v docker >/dev/null 2>&1; then
        echo "WARNING: docker command not found. Cannot ensure services are running." >&2
        echo "WARNING: Continuing anyway, but tests may fail if services are not running." >&2
        export API_BASE_URL
        return 0
    fi
    
    # Check if services are already running (fastest path)
    if check_services_running; then
        echo "INFO: Docker services are already running (fru_db, fru_api)" >&2
        # Still do a quick health check
        if command -v curl >/dev/null 2>&1; then
            if ! curl -sf "$API_BASE_URL/health" >/dev/null 2>&1; then
                echo "WARNING: Services are running but API health check failed at $API_BASE_URL" >&2
            fi
        fi
        export API_BASE_URL
        return 0
    fi
    
    # Services are down - need to start them
    echo "INFO: Docker services are not running. Ensuring services are up..." >&2
    
    local docker_dir="${REPO_ROOT}/infra/docker"
    if [ ! -d "$docker_dir" ]; then
        echo "ERROR: Docker directory not found at $docker_dir" >&2
        exit 1
    fi
    
    cd "$docker_dir"
    
    # Ensure Docker daemon is running
    # shellcheck source=/dev/null
    if [ -f "$REPO_ROOT/run_scripts/main_application_scripts/common/docker_run.sh" ]; then
        source "$REPO_ROOT/run_scripts/main_application_scripts/common/docker_run.sh" 2>/dev/null || true
        if command -v ensure_docker_running >/dev/null 2>&1; then
            if ! ensure_docker_running; then
                echo "ERROR: Docker daemon is not running. Please start Docker Desktop." >&2
                exit 1
            fi
        fi
    fi
    
    # Load .env for docker-compose
    if [ -f "$REPO_ROOT/.env" ]; then
        load_env_file 2>/dev/null || true
    fi
    
    if [[ "$force_rebuild" == "true" ]]; then
        # Force rebuild all images
        echo "INFO: Force rebuilding all Docker images..." >&2
        docker compose --env-file "$REPO_ROOT/.env" build
        
        # Clean up dangling images after build
        docker image prune -f >/dev/null 2>&1 || true
    else
        # Check if images exist
        if check_images_exist; then
            # Images exist - just start services
            echo "INFO: All required images exist. Starting services..." >&2
        else
            # Images missing - build missing images, then start
            echo "INFO: Some images are missing. Building images..." >&2
            docker compose --env-file "$REPO_ROOT/.env" build
            
            # Clean up dangling images after build
            docker image prune -f >/dev/null 2>&1 || true
        fi
    fi
    
    # Start services
    echo "INFO: Starting Docker Compose services..." >&2
    docker compose --env-file "$REPO_ROOT/.env" up -d
    
    # Wait for services to be ready
    echo "INFO: Waiting for services to be ready..." >&2
    
    # Wait for database
    # shellcheck source=/dev/null
    if [ -f "$REPO_ROOT/run_scripts/main_application_scripts/common/wait-for-service.sh" ]; then
        source "$REPO_ROOT/run_scripts/main_application_scripts/common/wait-for-service.sh" 2>/dev/null || true
        if command -v wait_for_port >/dev/null 2>&1; then
            wait_for_port "localhost" "55432" 30 2 || true
        fi
    fi
    
    # Wait for API health check
    if command -v curl >/dev/null 2>&1; then
        local max_retries=10
        local retry_count=0
        local health_ok=false
        
        while [ $retry_count -lt $max_retries ]; do
            if curl -sf "$API_BASE_URL/health" >/dev/null 2>&1; then
                health_ok=true
                break
            fi
            sleep 2
            retry_count=$((retry_count + 1))
        done
        
        if [ "$health_ok" = false ]; then
            echo "WARNING: API health check failed after ${max_retries} attempts at $API_BASE_URL" >&2
            echo "WARNING: Services may still be starting. Continuing anyway..." >&2
        else
            echo "INFO: Services are ready!" >&2
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

