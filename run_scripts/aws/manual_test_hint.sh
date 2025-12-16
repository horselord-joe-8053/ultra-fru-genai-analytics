#!/bin/bash
# Manual test hints for AWS deployment
# Shows how to play with the application end-to-end after successful deployment
# Usage: ./manual_test_hint.sh <deployment-type> <environment> [api_url] [frontend_url] [dry-run]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"
# Load environment variables (AWS_PROFILE, AWS_REGION, TF_STATE_BUCKET, etc.)
# so that terragrunt/terraform commands have the same context as other scripts.
ENV_SCRIPT_DIR="$SCRIPT_DIR/../common"
source "$ENV_SCRIPT_DIR/load-env.sh"
# Best-effort load; don't fail the whole script if .env is missing
load_env_file || log_warning "Could not load .env; Terraform outputs may not be available"

# ============================================================================
# VALIDATION CONSTANTS
# ============================================================================
API_VALIDATION_TIMEOUT_SECONDS=300  # 5 minutes (upper bound)
FRONTEND_VALIDATION_TIMEOUT_SECONDS=60  # 1 minute
VALIDATION_RETRY_INTERVAL_SECONDS=5  # Check every 5 seconds
# Fail fast on API errors if we can diagnose a clear cause from ECS/logs
API_VALIDATION_FAIL_FAST="${API_VALIDATION_FAIL_FAST:-true}"

# Default ECS log group (can be overridden via env)
ECS_LOG_GROUP="${ECS_LOG_GROUP:-/ecs/fru-dev}"

# Expected HTML content keywords for frontend validation
# These should be present in a working frontend page
FRONTEND_EXPECTED_HTML_KEYWORDS=(
    "<html"
    "<head"
    "<body"
    "react"
    "root"
    "app"
)

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
            # Try to read outputs; on failure, log a warning instead of silently ignoring
            if ! ALB_DNS=$(terragrunt output -raw alb_dns_name 2>/dev/null); then
                ALB_DNS=""
                log_warning "Could not read Terraform output 'alb_dns_name' via terragrunt; API URL may be unavailable"
            fi
            if ! CLOUDFRONT_DOMAIN=$(terragrunt output -raw cloudfront_domain_name 2>/dev/null); then
                CLOUDFRONT_DOMAIN=""
                log_warning "Could not read Terraform output 'cloudfront_domain_name' via terragrunt; frontend URL may be unavailable"
            fi
            if ! ECS_CLUSTER_ID=$(terragrunt output -raw ecs_cluster_id 2>/dev/null); then
                ECS_CLUSTER_ID=""
                log_warning "Could not read Terraform output 'ecs_cluster_id' via terragrunt; ECS hints may be limited"
            fi
            if ! ECS_SERVICE_NAME=$(terragrunt output -raw ecs_service_name 2>/dev/null); then
                ECS_SERVICE_NAME=""
                log_warning "Could not read Terraform output 'ecs_service_name' via terragrunt; ECS hints may be limited"
            fi
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

# Diagnose ECS API service failures using awscli (service events, tasks, logs)
diagnose_api_failure() {
    # Require aws cli
    if ! command_exists aws; then
        log_warning "aws CLI not available; cannot auto-diagnose API failure"
        return 1
    fi

    local cluster_name="${ECS_CLUSTER_NAME:-fru-dev-cluster}"
    local service_name="${ECS_SERVICE_NAME:-fru-dev-api-service}"
    local region="${AWS_REGION:-us-east-1}"
    local profile="${AWS_PROFILE:-admin}"

    echo ""
    log_step "Diagnosing ECS API service failure (cluster: $cluster_name, service: $service_name)"

    # Recent ECS service events
    log_info "Fetching recent ECS service events..."
    aws ecs describe-services \
        --cluster "$cluster_name" \
        --services "$service_name" \
        --profile "$profile" \
        --region "$region" \
        --query 'services[0].events[0:5]' \
        --output table 2>/dev/null || log_warning "Could not fetch ECS service events"

    # Task statuses
    log_info "Fetching ECS task statuses..."
    aws ecs list-tasks \
        --cluster "$cluster_name" \
        --service-name "$service_name" \
        --profile "$profile" \
        --region "$region" \
        --desired-status RUNNING \
        --query 'taskArns' \
        --output text 2>/dev/null | \
        awk '{for(i=1;i<=NF;i++)print $i}' | \
        xargs -r aws ecs describe-tasks \
            --cluster "$cluster_name" \
            --profile "$profile" \
            --region "$region" \
            --tasks \
            --query 'tasks[].{lastStatus:lastStatus,healthStatus:healthStatus,stoppedReason:stoppedReason,containers:containers[].{name:name,lastStatus:lastStatus,reason:reason}}' \
            --output table 2>/dev/null || log_warning "Could not fetch ECS task details"

    # Recent logs from CloudWatch
    if [ -n "$ECS_LOG_GROUP" ]; then
        log_info "Fetching recent CloudWatch logs from $ECS_LOG_GROUP (last 10 minutes, tail)..."
        local logs_output
        logs_output=$(aws logs tail "$ECS_LOG_GROUP" --since 10m --profile "$profile" --region "$region" 2>/dev/null || echo "")
        if [ -n "$logs_output" ]; then
            echo "$logs_output" | tail -40

            # Highlight common database auth errors
            if echo "$logs_output" | grep -qi "password authentication failed for user"; then
                log_error "Detected database authentication failures in logs (e.g., 'password authentication failed for user')."
                log_error "This usually means the Aurora DB password/username used by the API does not match the actual database credentials."
            fi
        else
            log_warning "No recent logs found or unable to read CloudWatch logs"
        fi
    fi

    return 0
}

# Validate API endpoint with retry logic
validate_api_endpoint() {
    local api_endpoint="$1"
    local timeout_seconds="$API_VALIDATION_TIMEOUT_SECONDS"
    local start_time=$(date +%s)
    local elapsed=0
    local last_status=""
    local diagnosed=false
    
    log_info "Testing API endpoint: $api_endpoint/health"
    log_info "  Will retry for up to $((timeout_seconds / 60)) minutes..."
    
    while [ $elapsed -lt $timeout_seconds ]; do
        local api_status
        api_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$api_endpoint/health" 2>/dev/null || echo "000")
        last_status="$api_status"
        
        if [ "$api_status" = "200" ]; then
            log_success "✓ API is responding (HTTP $api_status) after ${elapsed}s"
            
            # Get actual response
            local health_response
            health_response=$(curl -s --max-time 10 "$api_endpoint/health" 2>/dev/null || echo "")
            if echo "$health_response" | grep -q '"status"'; then
                log_info "  Response preview: $(echo "$health_response" | head -c 100)..."
            fi
            return 0
        elif [ "$api_status" = "503" ] || [ "$api_status" = "502" ] || [ "$api_status" = "504" ]; then
            # Service is starting or has a backend error
            if [ "$API_VALIDATION_FAIL_FAST" = "true" ] && [ "$diagnosed" = false ]; then
                log_warning "API returned HTTP $api_status. Attempting to diagnose ECS/logs and fail fast..."
                diagnose_api_failure || true
                diagnosed=true
                # Fail fast after diagnosis to avoid waiting full timeout when clear errors exist
                return 1
            fi
            if [ $((elapsed % 30)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                log_info "  Still waiting... (${elapsed}s elapsed, HTTP $api_status)"
            fi
        elif [ "$api_status" = "000" ]; then
            # Connection failed, continue retrying
            if [ $((elapsed % 30)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                log_info "  Connection failed, retrying... (${elapsed}s elapsed)"
            fi
        else
            # Unexpected status code
            log_warning "⚠ API endpoint returned HTTP $api_status"
            log_info "  Endpoint is reachable but may need configuration."
            return 1
        fi
        
        sleep "$VALIDATION_RETRY_INTERVAL_SECONDS"
        elapsed=$(($(date +%s) - start_time))
    done
    
    # Timeout reached
    log_error "✗ API endpoint validation failed after ${elapsed}s"
    log_error "  Last HTTP status: $last_status"
    log_error "  Endpoint: $api_endpoint/health"
    if [ "$last_status" = "503" ] || [ "$last_status" = "502" ] || [ "$last_status" = "504" ]; then
        log_error "  The service appears to be starting but did not become ready within the timeout period."
        log_info "  Troubleshooting steps:"
        log_info "    1. Check ECS service status: aws ecs describe-services --cluster <cluster> --services <service>"
        log_info "    2. Check ECS task logs: aws logs tail /ecs/fru-dev --follow"
        log_info "    3. Verify ALB target group health: aws elbv2 describe-target-health --target-group-arn <arn>"
    elif [ "$last_status" = "000" ]; then
        log_error "  The endpoint is not reachable (connection failed or timed out)."
        log_info "  Troubleshooting steps:"
        log_info "    1. Verify ALB is fully provisioned: aws elbv2 describe-load-balancers"
        log_info "    2. Check security groups allow traffic"
        log_info "    3. Verify DNS resolution: nslookup $(echo "$api_endpoint" | sed 's|http://||' | sed 's|https://||')"
    fi
    return 1
}

# Validate frontend endpoint with retry logic and HTML content check
validate_frontend_endpoint() {
    local frontend_endpoint="$1"
    local timeout_seconds="$FRONTEND_VALIDATION_TIMEOUT_SECONDS"
    local start_time=$(date +%s)
    local elapsed=0
    local last_status=""
    
    log_info "Testing Frontend endpoint: $frontend_endpoint"
    log_info "  Will retry for up to $((timeout_seconds / 60)) minute(s)..."
    
    while [ $elapsed -lt $timeout_seconds ]; do
        local frontend_status frontend_content_type
        frontend_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$frontend_endpoint" 2>/dev/null || echo "000")
        frontend_content_type=$(curl -s -o /dev/null -w "%{content_type}" --max-time 10 "$frontend_endpoint" 2>/dev/null || echo "")
        last_status="$frontend_status"
        
        if [ "$frontend_status" = "200" ]; then
            # Check if it's HTML
            local frontend_content
            frontend_content=$(curl -s --max-time 10 "$frontend_endpoint" 2>/dev/null | head -c 2000 || echo "")
            
            local html_verified=false
            if echo "$frontend_content" | grep -qiE "<html|<head|<!DOCTYPE"; then
                html_verified=true
            elif echo "$frontend_content_type" | grep -qi "text/html"; then
                html_verified=true
            fi
            
            # Check for expected HTML keywords
            local found_keywords=0
            for keyword in "${FRONTEND_EXPECTED_HTML_KEYWORDS[@]}"; do
                if echo "$frontend_content" | grep -qi "$keyword"; then
                    found_keywords=$((found_keywords + 1))
                fi
            done
            
            if [ "$html_verified" = true ] && [ $found_keywords -ge 2 ]; then
                log_success "✓ Frontend is accessible (HTTP $frontend_status) after ${elapsed}s"
                log_success "  ✓ Content is HTML with expected keywords"
                return 0
            elif [ "$html_verified" = true ]; then
                log_success "✓ Frontend is accessible (HTTP $frontend_status) after ${elapsed}s"
                log_warning "  ⚠ Content is HTML but missing some expected keywords"
                return 0
            else
                log_warning "⚠ Frontend returned HTTP 200 but content may not be HTML"
                log_info "  Content-Type: ${frontend_content_type:-unknown}"
                return 0
            fi
        elif [ "$frontend_status" = "403" ] || [ "$frontend_status" = "404" ]; then
            # CloudFront may still be deploying or S3 bucket may be empty
            if [ $((elapsed % 15)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                log_info "  Still waiting... (${elapsed}s elapsed, HTTP $frontend_status)"
            fi
        elif [ "$frontend_status" = "000" ]; then
            # Connection failed, continue retrying
            if [ $((elapsed % 15)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                log_info "  Connection failed, retrying... (${elapsed}s elapsed)"
            fi
        else
            # Unexpected status code
            log_warning "⚠ Frontend endpoint returned HTTP $frontend_status"
            return 1
        fi
        
        sleep "$VALIDATION_RETRY_INTERVAL_SECONDS"
        elapsed=$(($(date +%s) - start_time))
    done
    
    # Timeout reached
    log_error "✗ Frontend endpoint validation failed after ${elapsed}s"
    log_error "  Last HTTP status: $last_status"
    log_error "  Endpoint: $frontend_endpoint"
    if [ "$last_status" = "403" ]; then
        log_error "  CloudFront returned 403 Forbidden. Possible causes:"
        log_info "    1. CloudFront distribution is still deploying (can take 15-20 minutes)"
        log_info "    2. S3 bucket is empty or content not synced"
        log_info "    3. CloudFront origin access configuration issue"
        log_info "    4. CloudFront custom error responses not configured"
        log_info "  Troubleshooting steps:"
        log_info "    1. Check CloudFront status: aws cloudfront get-distribution --id <distribution-id>"
        log_info "    2. Verify S3 bucket has content: aws s3 ls s3://<bucket-name>/"
        log_info "    3. Check CloudFront origin: aws cloudfront get-distribution-config --id <distribution-id>"
    elif [ "$last_status" = "404" ]; then
        log_error "  CloudFront returned 404 Not Found."
        log_info "  Troubleshooting steps:"
        log_info "    1. Verify S3 bucket has index.html: aws s3 ls s3://<bucket-name>/"
        log_info "    2. Check CloudFront default root object configuration"
    elif [ "$last_status" = "000" ]; then
        log_error "  The endpoint is not reachable (connection failed or timed out)."
        log_info "  Troubleshooting steps:"
        log_info "    1. Verify CloudFront distribution is deployed: aws cloudfront list-distributions"
        log_info "    2. Check DNS resolution: nslookup $(echo "$frontend_endpoint" | sed 's|https://||' | sed 's|http://||')"
    fi
    return 1
}

# Validate URLs by testing connectivity with retry logic
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
    
    # Test API health endpoint with retry
    if [ -n "$API_URL" ]; then
        if validate_api_endpoint "$API_URL"; then
            api_ok=true
        fi
    elif [ -n "$ALB_DNS" ]; then
        if validate_api_endpoint "http://$ALB_DNS"; then
            api_ok=true
        fi
    else
        log_info "API URL not available for validation"
    fi
    
    echo ""
    
    # Test Frontend URL with retry
    if [ -n "$FRONTEND_URL" ]; then
        if validate_frontend_endpoint "$FRONTEND_URL"; then
            frontend_ok=true
        fi
    elif [ -n "$CLOUDFRONT_DOMAIN" ]; then
        if validate_frontend_endpoint "https://$CLOUDFRONT_DOMAIN"; then
            frontend_ok=true
        fi
    else
        log_info "Frontend URL not available for validation"
    fi
    
    echo ""
    
    # Summary
    if [ "$api_ok" = true ] && [ "$frontend_ok" = true ]; then
        log_success "✓ All endpoints are accessible and working!"
    elif [ "$api_ok" = true ]; then
        log_warning "⚠ API is accessible, but frontend needs attention"
    elif [ "$frontend_ok" = true ]; then
        log_warning "⚠ Frontend is accessible, but API needs attention"
    else
        log_warning "⚠ Some endpoints are not yet accessible"
        log_info "  Check the error messages above for troubleshooting steps."
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

