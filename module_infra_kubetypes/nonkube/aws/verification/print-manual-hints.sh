#!/bin/bash
# ECS-specific manual test hints
# Called indirectly via the common verification dispatcher in:
#   run_scripts/main_application_scripts/aws/verification/print-manual-hints.sh
#
# Purpose: Print ECS-specific manual test instructions and hints
# Type: Helper library (meant to be sourced)
# Usage: source this file, then call print_ecs_manual_hints
#
# Prerequisites:
#   - logger.sh must be sourced by parent script
#   - fetch-deployment-info.sh should be sourced before calling this (for ALB_DNS, CLOUDFRONT_DOMAIN, etc.)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"

# Source shared logger if not already available
if ! command -v log_info >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/orchestration/common/logger.sh" 2>/dev/null || true
fi

# Print ECS-specific manual test hints
print_ecs_manual_hints() {
    log_info "${GREEN}1. Get Deployment URLs:${NC}"
    if [ "$DRY_RUN" = "true" ]; then
        log_info "   ${GREEN}cd $REPO_ROOT/module_infra_kubetypes/nonkube/aws/terra/environments/$ENVIRONMENT/ecs${NC}"
        log_info "   ${GREEN}terragrunt output alb_dns_name${NC}        # API endpoint"
        log_info "   ${GREEN}terragrunt output cloudfront_domain_name${NC}  # ECS Frontend URL (CloudFront distribution)"
    else
        if [ -n "$ALB_DNS" ]; then
            log_info "   ${GREEN}API endpoint: http://$ALB_DNS${NC}"
        fi
        if [ -n "$CLOUDFRONT_DOMAIN" ]; then
            log_info "   ${GREEN}ECS Frontend URL: https://$CLOUDFRONT_DOMAIN${NC}${YELLOW} (CloudFront distribution for ECS deployment)${NC}"
        fi
        if [ -z "$ALB_DNS" ] || [ -z "$CLOUDFRONT_DOMAIN" ]; then
            log_info "   ${GREEN}cd $REPO_ROOT/module_infra_kubetypes/nonkube/aws/terra/environments/$ENVIRONMENT/ecs${NC}"
            log_info "   ${GREEN}terragrunt output alb_dns_name${NC}        # API endpoint"
            log_info "   ${GREEN}terragrunt output cloudfront_domain_name${NC}  # ECS Frontend URL (CloudFront distribution)"
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
}

# Main execution (if run standalone)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    print_ecs_manual_hints
fi
