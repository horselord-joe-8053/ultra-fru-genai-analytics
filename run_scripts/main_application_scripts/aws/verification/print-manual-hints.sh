#!/bin/bash
# Displays manual test instructions and hints for using the deployment
# Usage: source print-manual-hints.sh
#        print_manual_test_hints

# Note: fetch_terraform_outputs() should be called before this function
# Note: validate_urls() is called separately by orchestrator

print_manual_test_hints() {
    # Add prominent separator
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    if [ "$DRY_RUN" = "true" ]; then
        log_warning "═══════════  DRY-RUN MODE: Manual Test Hints (Preview Only)  ═══════════"
        log_info "These instructions show what you would do after a real deployment."
        log_info "No actual deployment has been made."
    else
        log_success "═══════════  Manual Test Hints: How to Use Your Deployment  ═══════════"
    fi
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    
    log_step "How to Verify and Use Your AWS Deployment"
    echo ""
    
    if [ "$DEPLOYMENT_TYPE" = "ecs-full" ]; then
        log_info "${GREEN}1. Get Deployment URLs:${NC}"
        if [ "$DRY_RUN" = "true" ]; then
            log_info "   ${GREEN}cd $REPO_ROOT/infra/terraform/environments/$ENVIRONMENT/application${NC}"
            log_info "   ${GREEN}terragrunt output alb_dns_name${NC}        # API endpoint"
            log_info "   ${GREEN}terragrunt output cloudfront_domain_name${NC}  # Frontend URL"
        else
            if [ -n "$ALB_DNS" ]; then
                log_info "   ${GREEN}API endpoint: http://$ALB_DNS${NC}"
            fi
            if [ -n "$CLOUDFRONT_DOMAIN" ]; then
                log_info "   ${GREEN}Frontend URL: https://$CLOUDFRONT_DOMAIN${NC}"
            fi
            if [ -z "$ALB_DNS" ] || [ -z "$CLOUDFRONT_DOMAIN" ]; then
                log_info "   ${GREEN}cd $REPO_ROOT/infra/terraform/environments/$ENVIRONMENT/application${NC}"
                log_info "   ${GREEN}terragrunt output alb_dns_name${NC}        # API endpoint"
                log_info "   ${GREEN}terragrunt output cloudfront_domain_name${NC}  # Frontend URL"
            fi
        fi
        echo ""
        log_info "${GREEN}2. Check ECS Service Status:${NC}"
        if [ "$DRY_RUN" = "true" ]; then
            log_info "   ${GREEN}aws ecs list-services --cluster <cluster-name>${NC}"
            log_info "   ${GREEN}aws ecs describe-services --cluster <cluster-name> --services <service-name>${NC}"
        else
            if [ -n "$ECS_CLUSTER_NAME" ] && [ -n "$ECS_SERVICE_NAME" ]; then
                log_info "   ${GREEN}aws ecs list-services --cluster $ECS_CLUSTER_NAME${NC}"
                log_info "   ${GREEN}aws ecs describe-services --cluster $ECS_CLUSTER_NAME --services $ECS_SERVICE_NAME${NC}"
            else
                log_info "   ${GREEN}aws ecs list-services --cluster <cluster-name>${NC}"
                log_info "   ${GREEN}aws ecs describe-services --cluster <cluster-name> --services <service-name>${NC}"
            fi
        fi
        echo ""
        log_info "${GREEN}3. View ECS Logs:${NC}"
        log_info "   ${GREEN}aws logs tail /ecs/fru-dev --follow${NC}"
        echo ""
    fi
    
    if [ "$DEPLOYMENT_TYPE" = "eks-full" ]; then
        log_info "${GREEN}1. Check Pod Status:${NC}"
        log_info "   ${GREEN}kubectl get pods -l app=fru-api${NC}"
        log_info "   ${GREEN}kubectl get svc fru-api${NC}"
        log_info "   ${GREEN}kubectl get ingress fru-api-ingress${NC}"
        echo ""
        log_info "${GREEN}2. View Pod Logs:${NC}"
        log_info "   ${GREEN}kubectl logs -l app=fru-api --tail=100 -f${NC}"
        echo ""
        log_info "${GREEN}3. Get Service Endpoint:${NC}"
        if [ "$DRY_RUN" = "true" ]; then
            log_info "   ${GREEN}kubectl get svc fru-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'${NC}"
        else
            if [ -n "$K8S_INGRESS_HOST" ]; then
                log_info "   ${GREEN}Ingress endpoint: https://$K8S_INGRESS_HOST${NC}"
            elif [ -n "$K8S_SERVICE_IP" ]; then
                log_info "   ${GREEN}Service endpoint: http://$K8S_SERVICE_IP${NC}"
            else
                log_info "   ${GREEN}kubectl get svc fru-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'${NC}"
            fi
        fi
        echo ""
    fi
    
    log_info "${GREEN}4. Test API Health:${NC}"
    if [ -n "$API_URL" ]; then
        log_info "   ${GREEN}curl $API_URL/health${NC}"
    elif [ -n "$ALB_DNS" ]; then
        # Use ALB_DNS directly if available (for ECS deployments)
        log_info "   ${GREEN}curl http://$ALB_DNS/health${NC}"
    elif [ "$DRY_RUN" = "true" ]; then
        log_info "   ${GREEN}curl http://<alb-dns-name>/health${NC}"
        log_info "   - Replace <alb-dns-name> with your ALB DNS from Terraform outputs"
    else
        log_info "   ${GREEN}curl http://<alb-dns-name>/health${NC}"
        log_info "   - Replace <alb-dns-name> with your ALB DNS from Terraform outputs"
        log_info "   - Or run: ${GREEN}cd $REPO_ROOT/infra/terraform/environments/$ENVIRONMENT/application && terragrunt output alb_dns_name${NC}"
    fi
    log_info "   - Should return: {\"status\": \"ok\", \"database\": \"connected\", ...}"
    echo ""
    
    log_info "${GREEN}5. Test Query Endpoint:${NC}"
    if [ -n "$API_URL" ]; then
        log_info "   ${GREEN}curl -X POST $API_URL/query \\"
    elif [ -n "$ALB_DNS" ]; then
        # Use ALB_DNS directly if available (for ECS deployments)
        log_info "   ${GREEN}curl -X POST http://$ALB_DNS/query \\"
    elif [ "$DRY_RUN" = "true" ]; then
        log_info "   ${GREEN}curl -X POST http://<alb-dns-name>/query \\"
    else
        log_info "   ${GREEN}curl -X POST http://<alb-dns-name>/query \\"
        log_info "   - Replace <alb-dns-name> with your ALB DNS from Terraform outputs"
    fi
    log_info "     -H \"Content-Type: application/json\" \\"
    log_info "     -d '{\"query\": \"What is the overall average customer rating?\"}'${NC}"
    echo ""
    
    log_info "${GREEN}6. Access Frontend:${NC}"
    if [ -n "$FRONTEND_URL" ]; then
        log_info "   Open in browser: ${GREEN}$FRONTEND_URL${NC}"
    elif [ "$DRY_RUN" = "true" ]; then
        log_info "   ${GREEN}cd $REPO_ROOT/infra/terraform/environments/$ENVIRONMENT/application${NC}"
        log_info "   ${GREEN}terragrunt output cloudfront_domain_name${NC}"
        log_info "   - Open https://<cloudfront-domain> in your browser"
    else
        log_info "   ${GREEN}cd $REPO_ROOT/infra/terraform/environments/$ENVIRONMENT/application${NC}"
        log_info "   ${GREEN}terragrunt output cloudfront_domain_name${NC}"
        log_info "   - Or if shown above, open: https://<cloudfront-domain> in your browser"
    fi
    log_info "   - Try asking questions like: 'What is the overall average customer rating?'"
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
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
}

# Main execution (if run standalone)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Source logger if not already sourced
    if [ -z "${log_info:-}" ]; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        source "$REPO_ROOT/run_scripts/shared/logger.sh" 2>/dev/null || true
    fi
    
    # Source fetch-deployment-info to get values
    source "$SCRIPT_DIR/fetch-deployment-info.sh" "${1:-ecs-full}" "${2:-dev}" "${3:-false}"
    
    print_manual_test_hints
else
    # If sourced, just define the function
    true  # Function is already defined above
fi

