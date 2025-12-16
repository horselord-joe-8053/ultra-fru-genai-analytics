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

# Fetch actual values from Terraform outputs (if not dry-run)
fetch_terraform_outputs() {
    if [ "$DRY_RUN" = "true" ]; then
        return 0
    fi
    
    # Initialize variables to empty (in case fetch fails)
    ALB_DNS=""
    CLOUDFRONT_DOMAIN=""
    ECS_CLUSTER_ID=""
    ECS_CLUSTER_NAME=""
    ECS_SERVICE_NAME=""
    EKS_CLUSTER_NAME=""
    K8S_SERVICE_IP=""
    K8S_INGRESS_HOST=""
    
    TERRAFORM_DIR="$REPO_ROOT/infra/terraform/environments/$ENVIRONMENT"
    
    # Fetch ECS/ALB outputs
    if [ "$DEPLOYMENT_TYPE" = "ecs-full" ] || [ "$DEPLOYMENT_TYPE" = "ecs" ]; then
        APP_DIR="$TERRAFORM_DIR/application"
        if [ -d "$APP_DIR" ] && command_exists terragrunt; then
            ORIG_DIR=$(pwd)
            cd "$APP_DIR" 2>/dev/null || return 0
            ALB_DNS=$(terragrunt output -raw alb_dns_name 2>/dev/null || echo "")
            CLOUDFRONT_DOMAIN=$(terragrunt output -raw cloudfront_domain_name 2>/dev/null || echo "")
            ECS_CLUSTER_ID=$(terragrunt output -raw ecs_cluster_id 2>/dev/null || echo "")
            ECS_SERVICE_NAME=$(terragrunt output -raw ecs_service_name 2>/dev/null || echo "")
            cd "$ORIG_DIR" 2>/dev/null || true
            
            # Extract cluster name from ARN if needed
            if [ -n "$ECS_CLUSTER_ID" ]; then
                ECS_CLUSTER_NAME=$(echo "$ECS_CLUSTER_ID" | awk -F'/' '{print $NF}' || echo "")
            fi
            
            # Set API_URL and FRONTEND_URL if not already set
            if [ -z "$API_URL" ] && [ -n "$ALB_DNS" ]; then
                API_URL="http://$ALB_DNS"
            fi
            if [ -z "$FRONTEND_URL" ] && [ -n "$CLOUDFRONT_DOMAIN" ]; then
                FRONTEND_URL="https://$CLOUDFRONT_DOMAIN"
            fi
        fi
    fi
    
    # Fetch EKS outputs
    if [ "$DEPLOYMENT_TYPE" = "eks-full" ] || [ "$DEPLOYMENT_TYPE" = "eks" ]; then
        EKS_DIR="$TERRAFORM_DIR/eks"
        if [ -d "$EKS_DIR" ] && command_exists terragrunt; then
            ORIG_DIR=$(pwd)
            cd "$EKS_DIR" 2>/dev/null || return 0
            EKS_CLUSTER_NAME=$(terragrunt output -raw cluster_name 2>/dev/null || echo "")
            cd "$ORIG_DIR" 2>/dev/null || true
        fi
        
        # Try to get service endpoint from kubectl if available
        if command_exists kubectl && kubectl config current-context >/dev/null 2>&1; then
            K8S_SERVICE_IP=$(kubectl get svc fru-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
            K8S_INGRESS_HOST=$(kubectl get ingress fru-api-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
            
            if [ -n "$K8S_INGRESS_HOST" ]; then
                API_URL="https://$K8S_INGRESS_HOST"
            elif [ -n "$K8S_SERVICE_IP" ]; then
                API_URL="http://$K8S_SERVICE_IP"
            fi
        fi
    fi
}

# Helper function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Validate URLs by testing connectivity
validate_urls() {
    if [ "$DRY_RUN" = "true" ]; then
        return 0
    fi
    
    # Check if curl is available
    if ! command_exists curl; then
        log_warning "curl is not available, skipping URL validation"
        return 0
    fi
    
    echo ""
    log_step "Validating Deployment URLs"
    echo ""
    
    local api_ok=false
    local frontend_ok=false
    local frontend_is_html=false
    
    # Test API health endpoint
    if [ -n "$API_URL" ]; then
        log_info "Testing API endpoint: $API_URL/health"
        local api_status
        api_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$API_URL/health" 2>/dev/null || echo "000")
        
        if [ "$api_status" = "200" ]; then
            log_success "✓ API is responding (HTTP $api_status)"
            api_ok=true
            
            # Try to get actual response
            local health_response
            health_response=$(curl -s --max-time 10 "$API_URL/health" 2>/dev/null || echo "")
            if echo "$health_response" | grep -q '"status"'; then
                log_info "  Response preview: $(echo "$health_response" | head -c 100)..."
            fi
        elif [ "$api_status" = "503" ] || [ "$api_status" = "502" ] || [ "$api_status" = "504" ]; then
            log_warning "⚠ API endpoint is reachable but service is not ready (HTTP $api_status)"
            log_info "  This is normal if ECS tasks are still starting. Wait a few minutes and try again."
        elif [ "$api_status" = "000" ]; then
            log_warning "⚠ API endpoint is not reachable (connection failed or timed out)"
            log_info "  Check if the ALB is fully provisioned and ECS tasks are running."
        else
            log_warning "⚠ API endpoint returned HTTP $api_status"
            log_info "  Endpoint is reachable but may need configuration."
        fi
    elif [ -n "$ALB_DNS" ]; then
        log_info "Testing API endpoint: http://$ALB_DNS/health"
        local api_status
        api_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$ALB_DNS/health" 2>/dev/null || echo "000")
        
        if [ "$api_status" = "200" ]; then
            log_success "✓ API is responding (HTTP $api_status)"
            api_ok=true
        elif [ "$api_status" = "503" ] || [ "$api_status" = "502" ] || [ "$api_status" = "504" ]; then
            log_warning "⚠ API endpoint is reachable but service is not ready (HTTP $api_status)"
            log_info "  This is normal if ECS tasks are still starting. Wait a few minutes and try again."
        elif [ "$api_status" = "000" ]; then
            log_warning "⚠ API endpoint is not reachable (connection failed or timed out)"
        else
            log_warning "⚠ API endpoint returned HTTP $api_status"
        fi
    else
        log_info "API URL not available for validation"
    fi
    
    echo ""
    
    # Test Frontend URL
    if [ -n "$FRONTEND_URL" ]; then
        log_info "Testing Frontend endpoint: $FRONTEND_URL"
        local frontend_status frontend_content_type
        frontend_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$FRONTEND_URL" 2>/dev/null || echo "000")
        frontend_content_type=$(curl -s -o /dev/null -w "%{content_type}" --max-time 10 "$FRONTEND_URL" 2>/dev/null || echo "")
        
        if [ "$frontend_status" = "200" ]; then
            log_success "✓ Frontend is accessible (HTTP $frontend_status)"
            frontend_ok=true
            
            # Check if it's HTML
            local frontend_content
            frontend_content=$(curl -s --max-time 10 "$FRONTEND_URL" 2>/dev/null | head -c 500 || echo "")
            if echo "$frontend_content" | grep -qiE "<html|<head|<!DOCTYPE"; then
                log_success "  ✓ Content is HTML"
                frontend_is_html=true
            elif echo "$frontend_content_type" | grep -qi "text/html"; then
                log_success "  ✓ Content-Type indicates HTML"
                frontend_is_html=true
            else
                log_warning "  ⚠ Content may not be HTML (Content-Type: ${frontend_content_type:-unknown})"
            fi
        elif [ "$frontend_status" = "403" ] || [ "$frontend_status" = "404" ]; then
            log_warning "⚠ Frontend endpoint returned HTTP $frontend_status"
            log_info "  CloudFront distribution may need configuration or content may not be deployed yet."
        elif [ "$frontend_status" = "000" ]; then
            log_warning "⚠ Frontend endpoint is not reachable (connection failed or timed out)"
        else
            log_warning "⚠ Frontend endpoint returned HTTP $frontend_status"
        fi
    elif [ -n "$CLOUDFRONT_DOMAIN" ]; then
        log_info "Testing Frontend endpoint: https://$CLOUDFRONT_DOMAIN"
        local frontend_status frontend_content_type
        frontend_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://$CLOUDFRONT_DOMAIN" 2>/dev/null || echo "000")
        frontend_content_type=$(curl -s -o /dev/null -w "%{content_type}" --max-time 10 "https://$CLOUDFRONT_DOMAIN" 2>/dev/null || echo "")
        
        if [ "$frontend_status" = "200" ]; then
            log_success "✓ Frontend is accessible (HTTP $frontend_status)"
            frontend_ok=true
            
            # Check if it's HTML
            local frontend_content
            frontend_content=$(curl -s --max-time 10 "https://$CLOUDFRONT_DOMAIN" 2>/dev/null | head -c 500 || echo "")
            if echo "$frontend_content" | grep -qiE "<html|<head|<!DOCTYPE"; then
                log_success "  ✓ Content is HTML"
                frontend_is_html=true
            elif echo "$frontend_content_type" | grep -qi "text/html"; then
                log_success "  ✓ Content-Type indicates HTML"
                frontend_is_html=true
            else
                log_warning "  ⚠ Content may not be HTML (Content-Type: ${frontend_content_type:-unknown})"
            fi
        elif [ "$frontend_status" = "403" ] || [ "$frontend_status" = "404" ]; then
            log_warning "⚠ Frontend endpoint returned HTTP $frontend_status"
            log_info "  CloudFront distribution may need configuration or content may not be deployed yet."
        elif [ "$frontend_status" = "000" ]; then
            log_warning "⚠ Frontend endpoint is not reachable (connection failed or timed out)"
        else
            log_warning "⚠ Frontend endpoint returned HTTP $frontend_status"
        fi
    else
        log_info "Frontend URL not available for validation"
    fi
    
    echo ""
    
    # Summary
    if [ "$api_ok" = true ] && [ "$frontend_ok" = true ]; then
        log_success "✓ All endpoints are accessible!"
        if [ "$frontend_is_html" = true ]; then
            log_success "✓ Frontend is serving HTML content"
        fi
    elif [ "$api_ok" = true ]; then
        log_warning "⚠ API is accessible, but frontend needs attention"
    elif [ "$frontend_ok" = true ]; then
        log_warning "⚠ Frontend is accessible, but API needs attention"
    else
        log_warning "⚠ Some endpoints are not yet accessible"
        log_info "  This is normal immediately after deployment. Services may take a few minutes to be fully ready."
    fi
}

print_manual_test_hints() {
    # Fetch actual values from Terraform if not dry-run
    fetch_terraform_outputs
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
    
    if [ "$DEPLOYMENT_TYPE" = "ecs-full" ] || [ "$DEPLOYMENT_TYPE" = "ecs" ]; then
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
    log_info "     -d '{\"query\": \"Why are Samsung customers unhappy?\"}'${NC}"
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
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    
    # Validate URLs if not in dry-run mode
    if [ "$DRY_RUN" != "true" ]; then
        validate_urls || true  # Don't fail script if validation has issues
        echo ""
        echo "═══════════════════════════════════════════════════════════════════════════════"
        echo ""
    fi
}

print_manual_test_hints "$@"

