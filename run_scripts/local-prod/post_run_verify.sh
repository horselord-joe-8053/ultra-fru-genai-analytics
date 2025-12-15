#!/bin/bash
# Post-run verification script for local production simulation
# Automatically verifies services and provides instructions

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"
source "$SCRIPT_DIR/../common/load-env.sh"

# Load environment variables
load_env_file 2>/dev/null || true

API_URL="http://localhost:5000"
FRONTEND_DIST="$REPO_ROOT/frontend/dist"

verify_local_prod_deployment() {
    log_step "Verifying Local Production Simulation Deployment"
    echo ""
    
    # Check if Docker services are running
    log_info "Checking Docker services..."
    if docker ps | grep -q "fru_db\|fru_api"; then
        log_success "Docker services are running"
    else
        log_warning "Docker services may not be running"
        log_info "Start them with: ./run_scripts/local-prod/deploy.sh"
    fi
    echo ""
    
    # Check API health endpoint
    log_info "Checking API health endpoint..."
    if command_exists curl; then
        if curl -sf "$API_URL/health" >/dev/null 2>&1; then
            log_success "API is responding at $API_URL/health"
            
            # Get detailed health status
            local health_response=$(curl -sf "$API_URL/health" 2>/dev/null || echo "{}")
            if echo "$health_response" | grep -q '"status":"ok"'; then
                log_success "API health check passed"
                
                # Check database connection
                if echo "$health_response" | grep -q '"database":"connected"'; then
                    log_success "Database connection: OK"
                else
                    log_warning "Database connection: FAILED"
                fi
                
                # Check OpenAI configuration
                if echo "$health_response" | grep -q '"openai":"configured"'; then
                    log_success "OpenAI configuration: OK"
                else
                    log_warning "OpenAI configuration: NOT CONFIGURED"
                fi
                
                # Check AWS configuration
                if echo "$health_response" | grep -q '"aws":"configured"'; then
                    log_success "AWS configuration: OK"
                else
                    log_warning "AWS configuration: NOT CONFIGURED"
                fi
            else
                log_warning "API health check returned unexpected response"
            fi
        else
            log_warning "API is not responding at $API_URL/health"
            log_info "Wait a few seconds and try: curl $API_URL/health"
        fi
    else
        log_warning "curl not found, skipping API health check"
    fi
    echo ""
    
    # Check if frontend is built
    log_info "Checking frontend build..."
    if [ -d "$FRONTEND_DIST" ]; then
        log_success "Frontend is built at $FRONTEND_DIST"
        if [ -f "$FRONTEND_DIST/index.html" ]; then
            log_success "Frontend index.html exists"
        else
            log_warning "Frontend index.html not found"
        fi
    else
        log_warning "Frontend is not built"
        log_info "Build it with: ./run_scripts/local-prod/build-frontend.sh"
    fi
    echo ""
    log_success "Verification complete! Check the manual test hints for next steps."
}

verify_local_prod_deployment "$@"

