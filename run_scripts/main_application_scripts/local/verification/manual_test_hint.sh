#!/bin/bash
# Manual test hints for local development
# Shows how to play with the application end-to-end after successful setup
# Usage: ./manual_test_hint.sh [dry-run]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"

# Load environment variables
load_env_file 2>/dev/null || true

# Get parameters
DRY_RUN="${1:-false}"

# Use LOCAL_SERVER_PORT from .env, default 5000
server_port="${LOCAL_SERVER_PORT:-5000}"
API_URL="http://localhost:${server_port}"
FRONTEND_URL="http://localhost:5173"

print_manual_test_hints() {
    # Add prominent separator
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    if [ "$DRY_RUN" = "true" ]; then
        log_warning "═══════════  DRY-RUN MODE: Manual Test Hints (Preview Only)  ═══════════"
        log_info "These instructions show what you would do after a real setup."
        log_info "No actual setup has been made."
    else
        log_success "═══════════  Manual Test Hints: How to Use Your Deployment  ═══════════"
    fi
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    
    log_step "How to Use Your Local Development Environment"
    echo ""
    log_info "${GREEN}1. Frontend (if running):${NC}"
    log_info "   Open in browser: ${GREEN}$FRONTEND_URL${NC}"
    log_info "   - The frontend will proxy API requests to $API_URL"
    log_info "   - Try asking questions like: 'What is the overall average customer rating?'"
    echo ""
    log_info "${GREEN}2. API Health Check:${NC}"
    log_info "   ${GREEN}curl $API_URL/health${NC}"
    log_info "   - Should return: {\"status\": \"ok\", \"database\": \"connected\", ...}"
    echo ""
    log_info "${GREEN}3. Test Query Stream Endpoint (Server-Sent Events):${NC}"
    # NOTE: The /query/stream endpoint is verified automatically during deployment.
    # Manual testing example:
    log_info "   ${GREEN}curl \"$API_URL/query/stream?query=average%20rating\"${NC}"
    log_info "   - This endpoint streams responses in real-time using SSE format"
    log_info "   - The frontend uses this endpoint for query responses"
    echo ""
    log_info "${GREEN}3b. Test Query Endpoint (Optional - synchronous):${NC}"
    log_info "   ${GREEN}curl -X POST $API_URL/query \\"
    log_info "     -H \"Content-Type: application/json\" \\"
    log_info "           -d '{\"query\": \"What is the overall average customer rating?\"}'${NC}"
    log_info "   - Note: This endpoint is not verified automatically (may timeout)"
    echo ""
    log_info "${GREEN}4. View Logs:${NC}"
    log_info "   ${GREEN}cd $REPO_ROOT/infra/docker && docker compose logs -f${NC}"
    echo ""
    log_info "${GREEN}5. Stop Services:${NC}"
    log_info "   ${GREEN}./run_scripts/local/stop-services.sh${NC}"
    echo ""
    
    if [ "$DRY_RUN" = "true" ]; then
        log_warning "Note: This was a dry-run. No actual setup was made."
        log_info "Run without --dry-run to perform the actual setup."
    else
        log_success "Verification complete! Your local development environment is ready."
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
}

print_manual_test_hints "$@"

