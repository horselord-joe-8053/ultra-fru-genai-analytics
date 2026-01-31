#!/bin/bash
# EKS-specific manual test hints
# Called indirectly via the common verification dispatcher in:
#   run_scripts/main_application_scripts/aws/verification/print-manual-hints.sh
#
# Purpose: Print EKS-specific manual test instructions and hints
# Type: Helper library (meant to be sourced)
# Usage: source this file, then call print_eks_manual_hints
#
# Prerequisites:
#   - logger.sh must be sourced by parent script
#   - fetch-deployment-info.sh should be sourced before calling this (for CLOUDFRONT_DOMAIN, K8S_INGRESS_HOST, etc.)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"

# Source shared logger if not already available
if ! command -v log_info >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/orchestration/shared/logger.sh" 2>/dev/null || true
fi

# Print EKS-specific manual test hints
print_eks_manual_hints() {
    log_info "${GREEN}1. Get Deployment URLs:${NC}"
    if [ -n "$CLOUDFRONT_DOMAIN" ]; then
        log_info "   ${GREEN}EKS Frontend URL: https://$CLOUDFRONT_DOMAIN${NC}${YELLOW} (CloudFront distribution for EKS deployment)${NC}"
    fi
    if [ "$DRY_RUN" = "true" ]; then
        log_info "   ${GREEN}cd $REPO_ROOT/module_infra_kube/aws/environments/$ENVIRONMENT/eks${NC}"
        log_info "   ${GREEN}terragrunt output cloudfront_domain_name${NC}  # EKS Frontend URL (CloudFront distribution)"
    fi
    if [ -z "$CLOUDFRONT_DOMAIN" ] && [ "$DRY_RUN" != "true" ]; then
        log_info "   ${GREEN}cd $REPO_ROOT/module_infra_kube/aws/environments/$ENVIRONMENT/eks${NC}"
        log_info "   ${GREEN}terragrunt output cloudfront_domain_name${NC}  # EKS Frontend URL"
    fi
    echo ""
    log_info "${GREEN}2. Check Pod Status:${NC}"
    log_info "   ${GREEN}kubectl get pods -l app=fru-api${NC}"
    log_info "   ${GREEN}kubectl get svc fru-api${NC}"
    log_info "   ${GREEN}kubectl get ingress fru-api-ingress${NC}"
    echo ""
    log_info "${GREEN}3. View Pod Logs:${NC}"
    log_info "   ${GREEN}kubectl logs -l app=fru-api --tail=100 -f${NC}"
    echo ""
    log_info "${GREEN}4. Get Service Endpoint:${NC}"
    if [ "$DRY_RUN" = "true" ]; then
        log_info "   ${GREEN}kubectl get svc fru-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'${NC}"
    else
        if [ -n "$K8S_INGRESS_HOST" ]; then
            log_info "   ${GREEN}Ingress endpoint: http://$K8S_INGRESS_HOST${NC}"
        elif [ -n "$K8S_SERVICE_IP" ]; then
            log_info "   ${GREEN}Service endpoint: http://$K8S_SERVICE_IP${NC}"
        else
            log_info "   ${GREEN}kubectl get svc fru-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'${NC}"
        fi
    fi
    echo ""
}

# Main execution (if run standalone)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    print_eks_manual_hints
fi
