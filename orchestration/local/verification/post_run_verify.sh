#!/bin/bash
# Post-run verification script for local development
# Automatically verifies services and provides instructions

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/orchestration/common/logger.sh"
source "$REPO_ROOT/orchestration/common/env/load-env.sh"

# Load environment variables
load_env_file 2>/dev/null || true

# Use LOCAL_SERVER_PORT from .env, default 5000
server_port="${LOCAL_SERVER_PORT:-5000}"
API_URL="http://localhost:${server_port}"
FRONTEND_URL="http://localhost:5173"

verify_local_deployment() {
    log_step "Verifying Local Development Deployment"
    echo ""
    
    # Check if Docker services are running
    log_info "Checking Docker services..."
    if docker ps | grep -q "fru_db\|fru_api"; then
        log_success "Docker services are running"
    else
        log_warning "Docker services may not be running"
        log_info "Start them with: ./orchestration/local/start-services.sh"
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
    
    # Check if frontend is running
    log_info "Checking frontend..."
    if command_exists curl; then
        if curl -sf "$FRONTEND_URL" >/dev/null 2>&1; then
            log_success "Frontend is responding at $FRONTEND_URL"
        else
            log_info "Frontend is not running (this is OK if you skipped it)"
            log_info "Start it with: ./orchestration/local/start-frontend.sh"
        fi
    fi
    echo ""
    log_success "Verification complete! Check the manual test hints for next steps."
}

verify_local_deployment "$@"

