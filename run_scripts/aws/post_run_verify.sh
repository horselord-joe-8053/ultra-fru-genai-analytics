#!/bin/bash
# Post-run verification script for AWS deployment
# Automatically verifies services and provides instructions

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"
source "$SCRIPT_DIR/../common/load-env.sh"

# Load environment variables
load_env_file 2>/dev/null || true

# Get deployment type and environment from arguments
DEPLOYMENT_TYPE="${1:-ecs-full}"
ENVIRONMENT="${2:-dev}"

verify_aws_deployment() {
    log_step "Verifying AWS Deployment"
    log_info "Deployment Type: $DEPLOYMENT_TYPE"
    log_info "Environment: $ENVIRONMENT"
    echo ""
    
    # Get Terraform outputs
    TERRAFORM_DIR="$REPO_ROOT/infra/terraform/environments/$ENVIRONMENT"
    
    # Check if infrastructure was deployed
    if [ ! -d "$TERRAFORM_DIR" ]; then
        log_warning "Terraform directory not found: $TERRAFORM_DIR"
        log_info "Infrastructure may not be deployed yet"
        echo ""
        print_manual_instructions
        return 0
    fi
    
    # Try to get Terraform outputs
    log_info "Checking Terraform outputs..."
    cd "$TERRAFORM_DIR/application" 2>/dev/null || cd "$TERRAFORM_DIR/infrastructure" 2>/dev/null || {
        log_warning "Cannot access Terraform directory"
        echo ""
        print_manual_instructions
        return 0
    }
    
    # Get ALB DNS name (for ECS)
    if [ "$DEPLOYMENT_TYPE" = "ecs-full" ] || [ "$DEPLOYMENT_TYPE" = "ecs" ]; then
        log_info "Checking ECS deployment..."
        
        # Try to get ALB DNS from Terraform
        if command_exists terragrunt; then
            ALB_DNS=$(terragrunt output -raw alb_dns_name 2>/dev/null || echo "")
            if [ -n "$ALB_DNS" ]; then
                log_success "ALB DNS name: $ALB_DNS"
                API_URL="http://$ALB_DNS"
            else
                log_info "ALB DNS name not available yet (may still be deploying)"
                API_URL=""
            fi
        fi
        
        # Get CloudFront domain (for frontend)
        CLOUDFRONT_DOMAIN=$(terragrunt output -raw cloudfront_domain_name 2>/dev/null || echo "")
        if [ -n "$CLOUDFRONT_DOMAIN" ]; then
            log_success "CloudFront domain: $CLOUDFRONT_DOMAIN"
            FRONTEND_URL="https://$CLOUDFRONT_DOMAIN"
        else
            log_info "CloudFront domain not available yet"
            FRONTEND_URL=""
        fi
        
        # Check ECS service status
        if command_exists aws; then
            log_info "Checking ECS service status..."
            CLUSTER_NAME=$(aws ecs list-clusters --query "clusterArns[?contains(@, '$ENVIRONMENT')]" --output text 2>/dev/null | head -1 | awk -F'/' '{print $NF}' || echo "")
            if [ -n "$CLUSTER_NAME" ]; then
                SERVICE_NAME=$(aws ecs list-services --cluster "$CLUSTER_NAME" --query "serviceArns[0]" --output text 2>/dev/null | awk -F'/' '{print $NF}' || echo "")
                if [ -n "$SERVICE_NAME" ]; then
                    log_info "ECS Service: $SERVICE_NAME in cluster: $CLUSTER_NAME"
                    RUNNING_COUNT=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --query "services[0].runningCount" --output text 2>/dev/null || echo "0")
                    DESIRED_COUNT=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --query "services[0].desiredCount" --output text 2>/dev/null || echo "0")
                    if [ "$RUNNING_COUNT" = "$DESIRED_COUNT" ] && [ "$RUNNING_COUNT" -gt 0 ]; then
                        log_success "ECS service is running ($RUNNING_COUNT/$DESIRED_COUNT tasks)"
                    else
                        log_warning "ECS service may still be starting ($RUNNING_COUNT/$DESIRED_COUNT tasks)"
                    fi
                fi
            fi
        fi
    fi
    
    # Get Kubernetes info (for EKS)
    if [ "$DEPLOYMENT_TYPE" = "eks-full" ] || [ "$DEPLOYMENT_TYPE" = "eks" ]; then
        log_info "Checking EKS deployment..."
        
        if command_exists kubectl; then
            # Check if kubectl context is set
            if kubectl config current-context >/dev/null 2>&1; then
                log_success "kubectl context is configured"
                
                # Check pod status
                log_info "Checking pod status..."
                PODS_RUNNING=$(kubectl get pods -l app=fru-api --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
                PODS_TOTAL=$(kubectl get pods -l app=fru-api --no-headers 2>/dev/null | wc -l | tr -d ' ')
                
                if [ "$PODS_RUNNING" -gt 0 ]; then
                    log_success "Pods running: $PODS_RUNNING/$PODS_TOTAL"
                else
                    log_warning "No pods running yet (may still be deploying)"
                fi
                
                # Get service endpoint
                SERVICE_IP=$(kubectl get svc fru-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
                if [ -n "$SERVICE_IP" ]; then
                    log_success "Service endpoint: $SERVICE_IP"
                    API_URL="http://$SERVICE_IP"
                else
                    # Try to get ingress
                    INGRESS_HOST=$(kubectl get ingress fru-api-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
                    if [ -n "$INGRESS_HOST" ]; then
                        log_success "Ingress host: $INGRESS_HOST"
                        API_URL="https://$INGRESS_HOST"
                    else
                        log_info "Service endpoint not available yet (may still be deploying)"
                    fi
                fi
            else
                log_warning "kubectl context not configured"
            fi
        fi
    fi
    
    echo ""
    
    # Check API health if URL is available
    if [ -n "$API_URL" ] && command_exists curl; then
        log_info "Checking API health endpoint..."
        if curl -sf "$API_URL/health" >/dev/null 2>&1; then
            log_success "API is responding at $API_URL/health"
            
            # Get detailed health status
            local health_response=$(curl -sf "$API_URL/health" 2>/dev/null || echo "{}")
            if echo "$health_response" | grep -q '"status":"ok"'; then
                log_success "API health check passed"
            fi
        else
            log_warning "API is not responding yet (may still be deploying)"
            log_info "Wait a few minutes and try: curl $API_URL/health"
        fi
    fi
    
    echo ""
    print_manual_instructions
}

print_manual_instructions() {
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
    
    log_success "Verification complete! Your AWS deployment should be ready."
    log_info "Note: It may take a few minutes for all services to be fully available."
}

verify_aws_deployment "$@"

