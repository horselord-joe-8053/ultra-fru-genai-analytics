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
#   - lib/logger.sh must be sourced by parent script
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
    source "$REPO_ROOT/lib/logger.sh" 2>/dev/null || true
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
            # Use set +e so that failed terragrunt output does not exit the script (set -e in caller).
            # Strip terragrunt log lines: use last non-empty line as value (terragrunt may mix logs into 2>&1).
            tg_clean() { printf '%s\n' "$1" | sed '/^$/d' | grep -vE '^\[0;|INFO |ERROR|WARN |DEBUG' | tail -1; }
            local terragrunt_error
            local tg_status
            local tg_output
            local tg_val
            set +e
            
            if [ -z "${ALB_DNS:-}" ]; then
                log_info "Fetching Terraform output: alb_dns_name"
                tg_output="$(terragrunt output -raw alb_dns_name 2>&1)"; tg_status=$?
                tg_val=$(tg_clean "$tg_output")
                if [ $tg_status -ne 0 ] || [ -z "$tg_val" ] || printf '%s\n' "$tg_output" | grep -q "Warning: No outputs found"; then
                    terragrunt_error="$tg_output"
                    ALB_DNS=""
                    log_warning "Could not read Terraform output 'alb_dns_name' via terragrunt; API URL may be unavailable"
                    if command -v log_info >/dev/null 2>&1 && [ -n "$terragrunt_error" ]; then
                        log_info "Terragrunt output (trimmed): ${terragrunt_error:0:200}"
                    fi
                else
                    ALB_DNS="$tg_val"
                    log_info "Output retrieved: alb_dns_name=$ALB_DNS"
                fi
            fi
            
            # cloudfront_domain_name is not in ECS root layer; fetched from frontend-ecs below
            if [ -z "${ECS_CLUSTER_ID:-}" ]; then
                log_info "Fetching Terraform output: ecs_cluster_id (fallback: cluster_id)"
                tg_output="$(terragrunt output -raw ecs_cluster_id 2>&1)"; tg_status=$?
                if [ $tg_status -ne 0 ] || [ -z "$tg_output" ] || printf '%s\n' "$tg_output" | grep -q "Warning: No outputs found\|not found"; then
                    tg_output="$(terragrunt output -raw cluster_id 2>&1)"; tg_status=$?
                fi
                tg_val=$(tg_clean "$tg_output")
                if [ $tg_status -eq 0 ] && [ -n "$tg_val" ] && ! printf '%s\n' "$tg_output" | grep -q "Warning: No outputs found\|not found"; then
                    ECS_CLUSTER_ID="$tg_val"
                    log_info "Output retrieved: ecs_cluster_id=${ECS_CLUSTER_ID:0:100}..."
                else
                    ECS_CLUSTER_ID=""
                    log_warning "Could not read ECS cluster ID from Terraform (tried ecs_cluster_id, cluster_id); ECS hints may be limited"
                fi
            fi
            
            if [ -z "${ECS_SERVICE_NAME:-}" ]; then
                log_info "Fetching Terraform output: ecs_service_name (fallback: service_name)"
                tg_output="$(terragrunt output -raw ecs_service_name 2>&1)"; tg_status=$?
                if [ $tg_status -ne 0 ] || [ -z "$tg_output" ] || printf '%s\n' "$tg_output" | grep -q "Warning: No outputs found\|not found"; then
                    tg_output="$(terragrunt output -raw service_name 2>&1)"; tg_status=$?
                fi
                tg_val=$(tg_clean "$tg_output")
                if [ $tg_status -eq 0 ] && [ -n "$tg_val" ] && ! printf '%s\n' "$tg_output" | grep -q "Warning: No outputs found\|not found"; then
                    ECS_SERVICE_NAME="$tg_val"
                    log_info "Output retrieved: ecs_service_name=$ECS_SERVICE_NAME"
                else
                    ECS_SERVICE_NAME=""
                    log_warning "Could not read ECS service name from Terraform (tried ecs_service_name, service_name); ECS hints may be limited"
                fi
            fi
            set -e
        cd "$orig_dir" 2>/dev/null || true
    fi

    # Fetch CloudFront domain from frontend-ecs layer (not from ECS root; same pattern as EKS/frontend-eks)
    local frontend_ecs_dir="$REPO_ROOT/module_infra_frontend/aws/terra/environments/$environment/frontend-ecs"
    if [ -d "$frontend_ecs_dir" ] && command_exists terragrunt && [ -z "${CLOUDFRONT_DOMAIN:-}" ]; then
        local _orig_dir _tg_out _tg_st
        _orig_dir=$(pwd)
        cd "$frontend_ecs_dir" 2>/dev/null || true
        if [ "$(pwd)" = "$frontend_ecs_dir" ]; then
            log_info "Fetching Terraform output: cloudfront_domain_name (from frontend-ecs layer)"
            set +e
            _tg_out="$(terragrunt output -raw cloudfront_domain_name 2>&1)"; _tg_st=$?
            set -e
            _tg_val=$(printf '%s\n' "$_tg_out" | sed '/^$/d' | grep -vE '^\[0;|INFO |ERROR|WARN |DEBUG' | tail -1)
            if [ $_tg_st -eq 0 ] && [ -n "$_tg_val" ] && ! printf '%s\n' "$_tg_out" | grep -q "Warning: No outputs found"; then
                CLOUDFRONT_DOMAIN="$_tg_val"
                log_info "Output retrieved: cloudfront_domain_name=$CLOUDFRONT_DOMAIN"
            else
                log_warning "Could not read Terraform output 'cloudfront_domain_name' from frontend-ecs; frontend URL may be unavailable"
            fi
        fi
        cd "$_orig_dir" 2>/dev/null || true
    fi

    # Extract cluster name from ARN if needed
    if [ -n "${ECS_CLUSTER_ID:-}" ]; then
        ECS_CLUSTER_NAME=$(echo "$ECS_CLUSTER_ID" | awk -F'/' '{print $NF}' || echo "")
    fi

    # Set API_URL and FRONTEND_URL from discovered values
    if [ -n "${ALB_DNS:-}" ]; then
        API_URL="http://$ALB_DNS"
    fi
    if [ -n "${CLOUDFRONT_DOMAIN:-}" ]; then
        FRONTEND_URL="https://$CLOUDFRONT_DOMAIN"
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
        TERRAFORM_DIR="$REPO_ROOT/module_infra_kubetypes/nonkube/aws/terra/environments/${ENVIRONMENT:-dev}"
    fi
    fetch_ecs_deployment_info
fi
