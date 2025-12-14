#!/bin/bash
# Post-run verification script for local development
# Automatically verifies services and provides instructions

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"
source "$SCRIPT_DIR/../common/load-env.sh"

# Load environment variables
load_env_file 2>/dev/null || true

API_URL="http://localhost:5000"
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
        log_info "Start them with: ./run_scripts/local/start-services.sh"
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
            log_info "Start it with: ./run_scripts/local/start-frontend.sh"
        fi
    fi
    echo ""
    
    # Print usage instructions
    log_step "How to Use Your Local Development Environment"
    echo ""
    log_info "${GREEN}1. Frontend (if running):${NC}"
    log_info "   Open in browser: ${GREEN}$FRONTEND_URL${NC}"
    log_info "   - The frontend will proxy API requests to $API_URL"
    log_info "   - Try asking questions like: 'Why are Samsung customers unhappy?'"
    echo ""
    log_info "${GREEN}2. API Health Check:${NC}"
    log_info "   ${GREEN}curl $API_URL/health${NC}"
    log_info "   - Should return: {\"status\": \"ok\", \"database\": \"connected\", ...}"
    echo ""
    log_info "${GREEN}3. Test Query Endpoint:${NC}"
    log_info "   ${GREEN}curl -X POST $API_URL/query \\"
    log_info "     -H \"Content-Type: application/json\" \\"
    log_info "     -d '{\"query\": \"Why are Samsung customers unhappy?\"}'${NC}"
    echo ""
    log_info "${GREEN}4. View Logs:${NC}"
    log_info "   ${GREEN}cd $REPO_ROOT/infra/docker && docker compose logs -f${NC}"
    echo ""
    log_info "${GREEN}5. Stop Services:${NC}"
    log_info "   ${GREEN}./run_scripts/local/stop-services.sh${NC}"
    echo ""
    log_success "Verification complete! Your local development environment is ready."
}

verify_local_deployment "$@"

