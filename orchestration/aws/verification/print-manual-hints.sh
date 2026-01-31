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
    
    # Determine container type from CONTAINER_TYPE
    local container_type="${CONTAINER_TYPE:-ecs}"  # Default to ecs
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local repo_root="${REPO_ROOT:-$(cd "$script_dir/../.." && pwd)}"
    
    # Dispatch to container-type-specific hint functions
    if [ "$container_type" = "ecs" ]; then
        if [ -f "$repo_root/module_infra_kubetypes/nonkube/aws/verification/print-manual-hints.sh" ]; then
            # shellcheck source=/dev/null
            source "$repo_root/module_infra_kubetypes/nonkube/aws/verification/print-manual-hints.sh"
            print_ecs_manual_hints
        else
            log_warning "ECS manual hints script not found at: $repo_root/module_infra_kubetypes/nonkube/aws/verification/print-manual-hints.sh"
        fi
    elif [ "$container_type" = "eks" ]; then
        if [ -f "$repo_root/module_infra_kubetypes/kube/aws/verification/print-manual-hints.sh" ]; then
            # shellcheck source=/dev/null
            source "$repo_root/module_infra_kubetypes/kube/aws/verification/print-manual-hints.sh"
            print_eks_manual_hints
        else
            log_warning "EKS manual hints script not found at: $repo_root/module_infra_kubetypes/kube/aws/verification/print-manual-hints.sh"
        fi
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
        log_info "   - Or run: ${GREEN}cd $REPO_ROOT/infra/terraform/providers/aws/environments/$ENVIRONMENT/ecs && terragrunt output alb_dns_name${NC}"
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
        local frontend_label="Frontend URL"
        if [ "$container_type" = "ecs" ]; then
            frontend_label="ECS Frontend URL (CloudFront distribution for ECS deployment)"
        elif [ "$container_type" = "eks" ]; then
            frontend_label="EKS Frontend URL (CloudFront distribution for EKS deployment)"
        fi
        log_info "   ${YELLOW}${frontend_label}:${NC} ${GREEN}$FRONTEND_URL${NC}"
        log_info "   Open in browser: ${GREEN}$FRONTEND_URL${NC}"
    elif [ "$DRY_RUN" = "true" ]; then
        if [ "$container_type" = "ecs" ]; then
            log_info "   ${GREEN}cd $REPO_ROOT/infra/terraform/providers/aws/environments/$ENVIRONMENT/ecs${NC}"
            log_info "   ${GREEN}terragrunt output cloudfront_domain_name${NC}  # ECS Frontend URL"
        elif [ "$container_type" = "eks" ]; then
            log_info "   ${GREEN}cd $REPO_ROOT/infra/terraform/providers/aws/environments/$ENVIRONMENT/eks${NC}"
            log_info "   ${GREEN}terragrunt output cloudfront_domain_name${NC}  # EKS Frontend URL"
        else
            log_info "   ${GREEN}cd $REPO_ROOT/infra/terraform/providers/aws/environments/$ENVIRONMENT/ecs${NC}"
            log_info "   ${GREEN}terragrunt output cloudfront_domain_name${NC}"
        fi
        log_info "   - Open https://<cloudfront-domain> in your browser"
    else
        if [ "$container_type" = "ecs" ]; then
            log_info "   ${GREEN}cd $REPO_ROOT/infra/terraform/providers/aws/environments/$ENVIRONMENT/ecs${NC}"
            log_info "   ${GREEN}terragrunt output cloudfront_domain_name${NC}  # ECS Frontend URL"
        elif [ "$container_type" = "eks" ]; then
            log_info "   ${GREEN}cd $REPO_ROOT/infra/terraform/providers/aws/environments/$ENVIRONMENT/eks${NC}"
            log_info "   ${GREEN}terragrunt output cloudfront_domain_name${NC}  # EKS Frontend URL"
        else
            log_info "   ${GREEN}cd $REPO_ROOT/infra/terraform/providers/aws/environments/$ENVIRONMENT/ecs${NC}"
            log_info "   ${GREEN}terragrunt output cloudfront_domain_name${NC}"
        fi
        log_info "   - Or if shown above, open the $(echo "$container_type" | tr '[:lower:]' '[:upper:]') frontend URL in your browser"
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
        source "$REPO_ROOT/orchestration/common/logger.sh" 2>/dev/null || true
    fi
    
    # Source fetch-deployment-info to get values
    # CONTAINER_TYPE is already exported from run.sh (via --container-type parameter)
    # First argument is ignored (kept for backward compatibility with old call sites)
    source "$SCRIPT_DIR/fetch-deployment-info.sh" "" "${2:-${ENVIRONMENT:-dev}}" "${3:-${DRY_RUN:-false}}"
    
    print_manual_test_hints
else
    # If sourced, just define the function
    true  # Function is already defined above
fi

