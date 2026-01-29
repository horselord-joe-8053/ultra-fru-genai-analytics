#!/bin/bash
# ECS-specific deployment information fetching
# Called indirectly via the common verification dispatcher in:
#   run_scripts/main_application_scripts/aws/verification/fetch-deployment-info.sh
#
# Purpose: Fetch ECS-specific deployment information from Terraform outputs and AWS CLI
# Type: Helper library (meant to be sourced)
# Usage: source this file, then call fetch_ecs_deployment_info
#
# Prerequisites:
#   - logger.sh must be sourced by parent script
#   - TERRAFORM_DIR, ENVIRONMENT, REPO_ROOT must be set in parent scope
#   - terragrunt or aws CLI must be available
#
# Sets variables in parent scope:
#   - ALB_DNS: Application Load Balancer DNS name
#   - CLOUDFRONT_DOMAIN: CloudFront distribution domain name
#   - ECS_CLUSTER_ID: ECS cluster ARN
#   - ECS_CLUSTER_NAME: ECS cluster name (extracted from ARN)
#   - ECS_SERVICE_NAME: ECS service name
#   - API_URL: API endpoint URL (http://$ALB_DNS)
#   - FRONTEND_URL: Frontend URL (https://$CLOUDFRONT_DOMAIN)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"

# Source shared logger if not already available
if ! command -v log_info >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/run_scripts/shared/logger.sh" 2>/dev/null || true
fi

# Helper function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Fetch ECS deployment information from Terraform outputs and AWS CLI
fetch_ecs_deployment_info() {
    # TERRAFORM_DIR and ENVIRONMENT should be set by parent function
    local terraform_dir="${TERRAFORM_DIR:-}"
    local environment="${ENVIRONMENT:-dev}"
    
    if [ -z "$terraform_dir" ]; then
        log_warning "TERRAFORM_DIR not set, cannot fetch ECS deployment info"
        return 1
    fi
    
    local app_dir="$terraform_dir/ecs"
    
        # Fetch from Terraform outputs if available
        if [ -d "$app_dir" ] && command_exists terragrunt; then
            local orig_dir
            orig_dir=$(pwd)
            cd "$app_dir" 2>/dev/null || return 0
            
            # Debug: Verify variables are still set before calling terragrunt
            if command -v log_info >/dev/null 2>&1; then
                log_info "About to run terragrunt in $app_dir:"
                log_info "  TF_STATE_BUCKET=[${TF_STATE_BUCKET:-NOT SET}]"
                log_info "  AWS_PROFILE=[${AWS_PROFILE:-NOT SET}]"
            fi
            
            # Try to read outputs; on failure, log a concise warning instead of
            # treating Terraform's \"Warning: No outputs found\" as a real value.
            # Only fetch if not already set (skip expensive terragrunt calls if we already have the value).
            local terragrunt_error
            local tg_status
            local tg_output
            
            if [ -z "${ALB_DNS:-}" ]; then
                log_info "Fetching Terraform output: alb_dns_name"
                tg_output="$(terragrunt output -raw alb_dns_name 2>&1)"; tg_status=$?
                if [ $tg_status -ne 0 ] || printf '%s\n' "$tg_output" | grep -q "Warning: No outputs found"; then
                    terragrunt_error="$tg_output"
                    ALB_DNS=""
                    log_warning "Could not read Terraform output 'alb_dns_name' via terragrunt; API URL may be unavailable"
                    if command -v log_info >/dev/null 2>&1 && [ -n "$terragrunt_error" ]; then
                        log_info "Terragrunt output (trimmed): ${terragrunt_error:0:200}"
                    fi
                else
                    ALB_DNS="$tg_output"
                    log_info "Output retrieved: alb_dns_name=$ALB_DNS"
                fi
            fi
            
            if [ -z "${CLOUDFRONT_DOMAIN:-}" ]; then
                log_info "Fetching Terraform output: cloudfront_domain_name"
                tg_output="$(terragrunt output -raw cloudfront_domain_name 2>&1)"; tg_status=$?
                if [ $tg_status -ne 0 ] || printf '%s\n' "$tg_output" | grep -q "Warning: No outputs found"; then
                    terragrunt_error="$tg_output"
                    CLOUDFRONT_DOMAIN=""
                    log_warning "Could not read Terraform output 'cloudfront_domain_name' via terragrunt; frontend URL may be unavailable"
                    if command -v log_info >/dev/null 2>&1 && [ -n "$terragrunt_error" ]; then
                        log_info "Terragrunt output (trimmed): ${terragrunt_error:0:200}"
                    fi
                else
                    CLOUDFRONT_DOMAIN="$tg_output"
                    log_info "Output retrieved: cloudfront_domain_name=$CLOUDFRONT_DOMAIN"
                fi
            fi
            
            if [ -z "${ECS_CLUSTER_ID:-}" ]; then
                log_info "Fetching Terraform output: ecs_cluster_id"
                tg_output="$(terragrunt output -raw ecs_cluster_id 2>&1)"; tg_status=$?
                if [ $tg_status -ne 0 ] || printf '%s\n' "$tg_output" | grep -q "Warning: No outputs found"; then
                    terragrunt_error="$tg_output"
                    ECS_CLUSTER_ID=""
                    log_warning "Could not read Terraform output 'ecs_cluster_id' via terragrunt; ECS hints may be limited"
                    if command -v log_info >/dev/null 2>&1 && [ -n "$terragrunt_error" ]; then
                        log_info "Terragrunt output (trimmed): ${terragrunt_error:0:200}"
                    fi
                else
                    ECS_CLUSTER_ID="$tg_output"
                    log_info "Output retrieved: ecs_cluster_id=${ECS_CLUSTER_ID:0:100}..."
                fi
            fi
            
            if [ -z "${ECS_SERVICE_NAME:-}" ]; then
                log_info "Fetching Terraform output: ecs_service_name"
                tg_output="$(terragrunt output -raw ecs_service_name 2>&1)"; tg_status=$?
                if [ $tg_status -ne 0 ] || printf '%s\n' "$tg_output" | grep -q "Warning: No outputs found"; then
                    terragrunt_error="$tg_output"
                    ECS_SERVICE_NAME=""
                    log_warning "Could not read Terraform output 'ecs_service_name' via terragrunt; ECS hints may be limited"
                    if command -v log_info >/dev/null 2>&1 && [ -n "$terragrunt_error" ]; then
                        log_info "Terragrunt output (trimmed): ${terragrunt_error:0:200}"
                    fi
                else
                    ECS_SERVICE_NAME="$tg_output"
                    log_info "Output retrieved: ecs_service_name=$ECS_SERVICE_NAME"
                fi
            fi
        cd "$orig_dir" 2>/dev/null || true
        
        # Extract cluster name from ARN if needed
        if [ -n "$ECS_CLUSTER_ID" ]; then
            ECS_CLUSTER_NAME=$(echo "$ECS_CLUSTER_ID" | awk -F'/' '{print $NF}' || echo "")
        fi
        
        # Set API_URL and FRONTEND_URL from discovered values
        if [ -n "$ALB_DNS" ]; then
            API_URL="http://$ALB_DNS"
        fi
        if [ -n "$CLOUDFRONT_DOMAIN" ]; then
            FRONTEND_URL="https://$CLOUDFRONT_DOMAIN"
        fi
    fi

    # Fallback: if Terragrunt outputs are unavailable, try AWS CLI to infer ALB DNS
    if [ -z "$ALB_DNS" ] && command_exists aws; then
        log_info "Attempting to discover ECS cluster/service and ALB DNS via AWS CLI (fallback)..."
        
        # Find an ECS cluster whose ARN contains the environment name
        # Use same pattern as check-service-status.sh: let AWS CLI use defaults for region/profile
        ECS_CLUSTER_ID=$(aws ecs list-clusters \
            --query "clusterArns[?contains(@, '$environment')]" \
            --output text 2>/dev/null | head -1 || echo "")
        
        if [ -n "$ECS_CLUSTER_ID" ] && [ "$ECS_CLUSTER_ID" != "None" ]; then
            ECS_CLUSTER_NAME=$(echo "$ECS_CLUSTER_ID" | awk -F'/' '{print $NF}' || echo "")
            log_info "Discovered ECS cluster via AWS CLI: $ECS_CLUSTER_NAME"
            
            # Find first service in that cluster
            local service_arn
            service_arn=$(aws ecs list-services \
                --cluster "$ECS_CLUSTER_ID" \
                --query "serviceArns[0]" \
                --output text 2>/dev/null || echo "")
            
            if [ -n "$service_arn" ] && [ "$service_arn" != "None" ]; then
                ECS_SERVICE_NAME=$(echo "$service_arn" | awk -F'/' '{print $NF}' || echo "")
                log_info "Discovered ECS service via AWS CLI: $ECS_SERVICE_NAME"
                
                # From the ECS service, get target group ARN
                local target_group_arn
                target_group_arn=$(aws ecs describe-services \
                    --cluster "$ECS_CLUSTER_ID" \
                    --services "$ECS_SERVICE_NAME" \
                    --query "services[0].loadBalancers[0].targetGroupArn" \
                    --output text 2>/dev/null || echo "")
                
                if [ -n "$target_group_arn" ] && [ "$target_group_arn" != "None" ]; then
                    # From target group, get load balancer ARN
                    local lb_arn
                    lb_arn=$(aws elbv2 describe-target-groups \
                        --target-group-arns "$target_group_arn" \
                        --query "TargetGroups[0].LoadBalancerArns[0]" \
                        --output text 2>/dev/null || echo "")
                    
                    if [ -n "$lb_arn" ] && [ "$lb_arn" != "None" ]; then
                        ALB_DNS=$(aws elbv2 describe-load-balancers \
                            --load-balancer-arns "$lb_arn" \
                            --query "LoadBalancers[0].DNSName" \
                            --output text 2>/dev/null || echo "")
                        
                        if [ -n "$ALB_DNS" ] && [ "$ALB_DNS" != "None" ]; then
                            log_info "Discovered ALB DNS via AWS CLI fallback: $ALB_DNS"
                            API_URL="http://$ALB_DNS"
                        else
                            log_warning "AWS CLI fallback could not determine ALB DNS."
                        fi
                    fi
                fi
            fi
        else
            log_warning "AWS CLI fallback could not find an ECS cluster for environment '$environment'."
        fi
    fi
    
    return 0
}

# Main execution (if run standalone)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Set up minimal environment for standalone execution
    if [ -z "${REPO_ROOT:-}" ]; then
        REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
    fi
    if [ -z "${TERRAFORM_DIR:-}" ]; then
        TERRAFORM_DIR="$REPO_ROOT/infra/terraform/providers/aws/environments/${ENVIRONMENT:-dev}"
    fi
    fetch_ecs_deployment_info
fi
