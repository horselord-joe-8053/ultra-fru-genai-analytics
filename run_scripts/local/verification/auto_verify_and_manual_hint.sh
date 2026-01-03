#!/bin/bash
# Auto-verify local deployment and show manual test hints
# Consistent with AWS verification workflow
# Usage: ./auto_verify_and_manual_hint.sh [dry-run]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/../../common/logger.sh"
source "$SCRIPT_DIR/../../common/load-env.sh"
source "$SCRIPT_DIR/../../common/verify-endpoints.sh"

# Load environment variables
load_env_file 2>/dev/null || true

# Local URLs (use LOCAL_SERVER_PORT from .env, default 5000)
server_port="${LOCAL_SERVER_PORT:-5000}"
API_URL="http://localhost:${server_port}"
FRONTEND_URL="http://localhost:5173"
DRY_RUN="${1:-false}"

# Export for child scripts
export API_URL FRONTEND_URL DRY_RUN REPO_ROOT

echo ""
log_step "═══════════════════════════════════════════════════════════════════════════════"
log_step "Post-Deployment Verification and Manual Test Hints (Local Development)"
log_step "═══════════════════════════════════════════════════════════════════════════════"
echo ""

# Step 1: Check Docker services
log_step "Step 1/4: Checking Docker services..."
if [ "$DRY_RUN" != "true" ]; then
    check_docker_services || true  # Don't fail on service checks
    echo ""
fi

# Step 1.5: Check Spark setup (optional)
log_step "Step 1.5/4: Checking Spark setup (optional)..."
if [ "$DRY_RUN" != "true" ]; then
    if command -v spark-submit >/dev/null 2>&1; then
        if spark-submit --version 2>&1 | grep -qE "version 4\.0"; then
            log_success "Spark 4.0.1 is configured and available"
            SPARK_VERSION=$(spark-submit --version 2>&1 | grep -i "version" | head -1 || echo "Spark 4.0.1")
            log_info "  $SPARK_VERSION"
        else
            log_warning "Spark is installed but not version 4.0"
        fi
    else
        log_info "Spark is not configured locally (this is optional)"
        log_info "  Spark 4.0.1 is already installed in the fru_api Docker container"
        log_info "  The analytics scheduler runs Spark jobs inside the container automatically"
        log_info "  Use --setup-spark flag only if you need to run Spark jobs manually outside Docker"
    fi
    echo ""
fi

# Step 2: Display manual test hints
log_step "Step 2/4: Displaying manual test hints..."
source "$SCRIPT_DIR/manual_test_hint.sh"
print_manual_test_hints "$DRY_RUN"

# Step 3: Validate endpoints (using common logic)
if [ "$DRY_RUN" != "true" ]; then
    log_step "Step 3/4: Validating endpoints..."
    
    # Validate API endpoint
    if validate_api_endpoint "$API_URL"; then
        # Get detailed health status
        get_api_health_status "$API_URL"
    fi
    echo ""
    
    # Validate frontend endpoint (optional)
    if validate_frontend_endpoint "$FRONTEND_URL"; then
        log_success "Frontend is accessible"
    else
        log_info "Frontend is not running (this is OK if you skipped it)"
        log_info "Start it with: ./run_scripts/local/start-frontend.sh"
    fi
    echo ""
fi

log_success "═══════════════════════════════════════════════════════════════════════════════"
log_success "Verification complete!"
log_success "═══════════════════════════════════════════════════════════════════════════════"

