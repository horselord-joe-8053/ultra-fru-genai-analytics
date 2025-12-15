#!/bin/bash
# Manual test hints for local production simulation
# Shows how to play with the application end-to-end after successful deployment
# Usage: ./manual_test_hint.sh [dry-run]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"

# Get parameters
DRY_RUN="${1:-false}"

API_URL="http://localhost:5000"
FRONTEND_DIST="$REPO_ROOT/frontend/dist"

print_manual_test_hints() {
    if [ "$DRY_RUN" = "true" ]; then
        echo ""
        log_warning "=== DRY-RUN MODE: Manual Test Hints (Preview Only) ==="
        log_info "These instructions show what you would do after a real deployment."
        log_info "No actual deployment has been made."
        echo ""
    fi
    
    log_step "How to Use Your Local Production Simulation"
    echo ""
    log_info "${GREEN}1. Start Frontend Server (if built):${NC}"
    if [ -d "$FRONTEND_DIST" ]; then
        log_info "   ${GREEN}cd $REPO_ROOT/frontend && npx serve dist${NC}"
        log_info "   - Frontend will be available at: http://localhost:3000 (or port shown)"
        log_info "   - The frontend will need to be configured to call $API_URL for API"
        log_info "   - Or use: ${GREEN}python3 -m http.server 3000${NC} in the dist directory"
    else
        log_info "   Frontend was not built. Build it with:"
        log_info "   ${GREEN}cd $REPO_ROOT/frontend && npm run build && npx serve dist${NC}"
    fi
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
    log_info "   ${GREEN}./run_scripts/local-prod/teardown.sh${NC}"
    echo ""
    
    if [ "$DRY_RUN" = "true" ]; then
        log_warning "Note: This was a dry-run. No actual deployment was made."
        log_info "Run without --dry-run to perform the actual deployment."
    else
        log_success "Verification complete! Your local production simulation is ready."
    fi
}

print_manual_test_hints "$@"

