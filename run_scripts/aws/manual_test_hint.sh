#!/bin/bash
# Manual test hints for AWS deployment
# Shows how to play with the application end-to-end after successful deployment
# Usage: ./manual_test_hint.sh <deployment-type> <environment> [api_url] [frontend_url] [dry-run]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"

# Get parameters
DEPLOYMENT_TYPE="${1:-ecs-full}"
ENVIRONMENT="${2:-dev}"
API_URL="${3:-}"
FRONTEND_URL="${4:-}"
DRY_RUN="${5:-false}"

print_manual_test_hints() {
    if [ "$DRY_RUN" = "true" ]; then
        echo ""
        log_warning "=== DRY-RUN MODE: Manual Test Hints (Preview Only) ==="
        log_info "These instructions show what you would do after a real deployment."
        log_info "No actual deployment has been made."
        echo ""
    fi
    
    log_step "How to Verify and Use Your AWS Deployment"
    echo ""
    
    if [ "$DEPLOYMENT_TYPE" = "ecs-full" ] || [ "$DEPLOYMENT_TYPE" = "ecs" ]; then
        log_info "${GREEN}1. Get Deployment URLs:${NC}"
        log_info "   ${GREEN}cd $REPO_ROOT/infra/terraform/environments/$ENVIRONMENT/application${NC}"
        log_info "   ${GREEN}terragrunt output alb_dns_name${NC}        # API endpoint"
        log_info "   ${GREEN}terragrunt output cloudfront_domain_name${NC}  # Frontend URL"
        echo ""
        log_info "${GREEN}2. Check ECS Service Status:${NC}"
        log_info "   ${GREEN}aws ecs list-services --cluster <cluster-name>${NC}"
        log_info "   ${GREEN}aws ecs describe-services --cluster <cluster-name> --services <service-name>${NC}"
        echo ""
        log_info "${GREEN}3. View ECS Logs:${NC}"
        log_info "   ${GREEN}aws logs tail /ecs/fru-api --follow${NC}"
        echo ""
    fi
    
    if [ "$DEPLOYMENT_TYPE" = "eks-full" ] || [ "$DEPLOYMENT_TYPE" = "eks" ]; then
        log_info "${GREEN}1. Check Pod Status:${NC}"
        log_info "   ${GREEN}kubectl get pods -l app=fru-api${NC}"
        log_info "   ${GREEN}kubectl get svc fru-api${NC}"
        log_info "   ${GREEN}kubectl get ingress fru-api-ingress${NC}"
        echo ""
        log_info "${GREEN}2. View Pod Logs:${NC}"
        log_info "   ${GREEN}kubectl logs -l app=fru-api --tail=100 -f${NC}"
        echo ""
        log_info "${GREEN}3. Get Service Endpoint:${NC}"
        log_info "   ${GREEN}kubectl get svc fru-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'${NC}"
        echo ""
    fi
    
    log_info "${GREEN}4. Test API Health:${NC}"
    if [ -n "$API_URL" ]; then
        log_info "   ${GREEN}curl $API_URL/health${NC}"
    else
        log_info "   ${GREEN}curl http://<alb-dns-name>/health${NC}"
        log_info "   - Replace <alb-dns-name> with your ALB DNS from Terraform outputs"
    fi
    log_info "   - Should return: {\"status\": \"ok\", \"database\": \"connected\", ...}"
    echo ""
    
    log_info "${GREEN}5. Test Query Endpoint:${NC}"
    if [ -n "$API_URL" ]; then
        log_info "   ${GREEN}curl -X POST $API_URL/query \\"
    else
        log_info "   ${GREEN}curl -X POST http://<alb-dns-name>/query \\"
    fi
    log_info "     -H \"Content-Type: application/json\" \\"
    log_info "     -d '{\"query\": \"Why are Samsung customers unhappy?\"}'${NC}"
    echo ""
    
    log_info "${GREEN}6. Access Frontend:${NC}"
    if [ -n "$FRONTEND_URL" ]; then
        log_info "   Open in browser: ${GREEN}$FRONTEND_URL${NC}"
    else
        log_info "   ${GREEN}cd $REPO_ROOT/infra/terraform/environments/$ENVIRONMENT/application${NC}"
        log_info "   ${GREEN}terragrunt output cloudfront_domain_name${NC}"
        log_info "   - Open https://<cloudfront-domain> in your browser"
    fi
    log_info "   - Try asking questions like: 'Why are Samsung customers unhappy?'"
    echo ""
    
    log_info "${GREEN}7. Monitor Resources:${NC}"
    log_info "   - AWS Console: https://console.aws.amazon.com/"
    log_info "   - CloudWatch Logs: Check /ecs/fru-api or EKS pod logs"
    log_info "   - CloudWatch Metrics: Monitor ECS/EKS service metrics"
    echo ""
    
    if [ "$DRY_RUN" = "true" ]; then
        log_warning "Note: This was a dry-run. No actual deployment was made."
        log_info "Run without --dry-run to perform the actual deployment."
    else
        log_success "Verification complete! Your AWS deployment should be ready."
        log_info "Note: It may take a few minutes for all services to be fully available."
    fi
}

print_manual_test_hints "$@"

