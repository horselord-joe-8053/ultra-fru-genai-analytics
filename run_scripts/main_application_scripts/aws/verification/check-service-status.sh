#!/bin/bash
# Quick service status checks (ECS/EKS running status, basic API health)
# Usage: source check-service-status.sh
#        check_service_status <deployment-type> <environment>

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

# Check EKS pod status
check_eks_pod_status() {
    if ! command_exists kubectl; then
        log_warning "kubectl not available; cannot check EKS pod status"
        return 1
    fi
    
    # Check if kubectl context is set
    if ! kubectl config current-context >/dev/null 2>&1; then
        log_warning "kubectl context not configured"
        return 1
    fi
    
    log_success "kubectl context is configured"
    
    # Check pod status
    log_info "Checking pod status..."
    local pods_running pods_total
    pods_running=$(kubectl get pods -l app=fru-api --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    pods_total=$(kubectl get pods -l app=fru-api --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "$pods_running" -gt 0 ]; then
        log_success "Pods running: $pods_running/$pods_total"
    else
        log_warning "No pods running yet (may still be deploying)"
    fi
}

# Basic API health check (quick, no retry)
check_api_health_basic() {
    local api_url="${1:-${API_URL:-}}"
    
    if [ -z "$api_url" ]; then
        return 0  # Skip if no API URL
    fi
    
    if ! command_exists curl; then
        log_warning "curl not available; cannot check API health"
        return 1
    fi
    
    log_info "Checking API health endpoint..."
    if curl -sf "$api_url/health" >/dev/null 2>&1; then
        log_success "API is responding at $api_url/health"
        
        # Get detailed health status
        local health_response
        health_response=$(curl -sf "$api_url/health" 2>/dev/null || echo "{}")
        if echo "$health_response" | grep -q '"status":"ok"'; then
            log_success "API health check passed"
        fi
    else
        log_warning "API is not responding yet (may still be deploying)"
        log_info "Wait a few minutes and try: curl $api_url/health"
    fi
}

# Main function to check service status
check_service_status() {
    local container_type="${1:-${CONTAINER_TYPE:-ecs}}"  # Accept container type directly
    local environment="${2:-${ENVIRONMENT:-dev}}"
    
    # Default to ecs if not specified
    container_type="${container_type:-ecs}"
    
    # Check ECS service status
    if [ "$container_type" = "ecs" ]; then
        check_ecs_service_status "$environment"
    fi
    
    # Check EKS pod status
    if [ "$container_type" = "eks" ]; then
        check_eks_pod_status
    fi
    
    # Basic API health check
    check_api_health_basic
}

# Main execution (if run standalone)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Source logger if not already sourced
    if [ -z "${log_info:-}" ]; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        source "$REPO_ROOT/run_scripts/shared/logger.sh" 2>/dev/null || true
    fi
    
    check_service_status "$@"
else
    # If sourced, just define the functions
    true  # Functions are already defined above
fi

