#!/bin/bash
# ECS-specific service status check functions
# Called indirectly via the common verification dispatcher in:
#   run_scripts/main_application_scripts/aws/verification/check-service-status.sh
#
# Purpose: Check ECS service status (running tasks, deployments, etc.)
# Type: Helper library (meant to be sourced)
# Usage: source this file, then call check_ecs_service_status <environment>
#
# Prerequisites:
#   - logger.sh must be sourced by parent script
#   - AWS CLI must be installed and configured
#   - ECS_CLUSTER_ID and ECS_SERVICE_NAME environment variables (optional, will be discovered if not set)

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

# Check ECS service status
check_ecs_service_status() {
    local environment="${1:-${ENVIRONMENT:-dev}}"
    local region="${AWS_REGION:-us-east-1}"
    local profile="${AWS_PROFILE:-admin}"
    
    if ! command_exists aws; then
        log_warning "AWS CLI not available; cannot check ECS service status"
        return 1
    fi
    
    log_info "Checking ECS service status..."
    
    # Use cached values if available (from test cache or environment)
    local cluster_id="${ECS_CLUSTER_ID:-}"
    local service_name="${ECS_SERVICE_NAME:-}"
    local cluster_name=""
    
    # Extract cluster name from cached cluster ID if available
    if [ -n "$cluster_id" ]; then
        cluster_name=$(echo "$cluster_id" | awk -F'/' '{print $NF}' || echo "")
        log_info "Using cached ECS cluster: $cluster_name"
    fi
    
    # Fallback: find cluster via AWS CLI if not cached
    if [ -z "$cluster_name" ]; then
        cluster_id=$(aws ecs list-clusters --query "clusterArns[?contains(@, '$environment')]" --output text 2>/dev/null | head -1 || echo "")
        if [ -n "$cluster_id" ]; then
            cluster_name=$(echo "$cluster_id" | awk -F'/' '{print $NF}' || echo "")
        fi
    fi
    
    if [ -z "$cluster_name" ]; then
        log_info "No ECS cluster found for environment: $environment"
        return 0
    fi
    
    # Use cached service name if available
    if [ -z "$service_name" ]; then
        # Fallback: find service via AWS CLI if not cached
        local service_arn
        service_arn=$(aws ecs list-services --cluster "$cluster_name" --query "serviceArns[0]" --output text 2>/dev/null || echo "")
        if [ -n "$service_arn" ] && [ "$service_arn" != "None" ]; then
            service_name=$(echo "$service_arn" | awk -F'/' '{print $NF}' || echo "")
        fi
    else
        log_info "Using cached ECS service: $service_name"
    fi
    
    if [ -n "$service_name" ]; then
        log_info "ECS Service: $service_name in cluster: $cluster_name"
        
        # Make a single describe-services call and extract all needed values
        # This is more efficient than making 4 separate calls
        local service_info
        service_info=$(aws ecs describe-services \
            --cluster "$cluster_name" \
            --services "$service_name" \
            --query "services[0]" \
            --output json 2>/dev/null || echo "{}")
        
        # Extract values from the single response
        local running_count desired_count primary_deployment running_deployment
        
        # Use jq if available for JSON parsing, otherwise fallback to multiple queries
        if command_exists jq && [ "$service_info" != "{}" ]; then
            running_count=$(echo "$service_info" | jq -r '.runningCount // 0' 2>/dev/null || echo "0")
            desired_count=$(echo "$service_info" | jq -r '.desiredCount // 0' 2>/dev/null || echo "0")
            primary_deployment=$(echo "$service_info" | jq -r '.deployments[] | select(.status=="PRIMARY") | .runningCount // 0' 2>/dev/null | head -1 || echo "0")
            running_deployment=$(echo "$service_info" | jq -r '.deployments[] | select(.status=="PRIMARY") | .desiredCount // 0' 2>/dev/null | head -1 || echo "0")
        else
            # Fallback: make individual queries if jq is not available
            running_count=$(aws ecs describe-services --cluster "$cluster_name" --services "$service_name" --query "services[0].runningCount" --output text 2>/dev/null || echo "0")
            desired_count=$(aws ecs describe-services --cluster "$cluster_name" --services "$service_name" --query "services[0].desiredCount" --output text 2>/dev/null || echo "0")
            primary_deployment=$(aws ecs describe-services --cluster "$cluster_name" --services "$service_name" --query "services[0].deployments[?status=='PRIMARY'].runningCount | [0]" --output text 2>/dev/null || echo "0")
            running_deployment=$(aws ecs describe-services --cluster "$cluster_name" --services "$service_name" --query "services[0].deployments[?status=='PRIMARY'].desiredCount | [0]" --output text 2>/dev/null || echo "0")
        fi
        
        if [ "$running_count" = "$desired_count" ] && [ "$running_count" -gt 0 ]; then
            log_success "ECS service is running ($running_count/$desired_count tasks)"
            if [ "$primary_deployment" = "$running_deployment" ] && [ "$primary_deployment" -gt 0 ]; then
                log_success "Primary deployment is stable ($primary_deployment/$running_deployment tasks)"
            else
                log_info "Primary deployment: $primary_deployment/$running_deployment tasks (may still be rolling out)"
            fi
        else
            log_warning "ECS service may still be starting ($running_count/$desired_count tasks)"
            log_info "Primary deployment: $primary_deployment/$running_deployment tasks"
        fi
    else
        log_info "No ECS services found in cluster: $cluster_name"
    fi
}

# Main execution (if run standalone)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    check_ecs_service_status "$@"
fi
