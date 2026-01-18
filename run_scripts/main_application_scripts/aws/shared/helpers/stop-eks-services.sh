#!/bin/bash
# Stop EKS services (Kubernetes deployments/resources)
# Usage: stop_eks_services <cluster_name> [aws_profile] [aws_region] [dry_run]
#
# This function stops all Kubernetes deployments and services before Terraform destroy because:
# - Running pods may slow cluster deletion
# - Deployments/services should be gracefully terminated
# - Explicit cleanup provides cleaner teardown output

stop_eks_services() {
    local cluster_name="$1"
    local aws_profile="${2:-${AWS_PROFILE:-admin}}"
    local aws_region="${3:-${AWS_REGION:-us-east-1}}"
    local dry_run="${4:-${DRY_RUN:-false}}"
    
    log_step "Stopping EKS Services (Kubernetes deployments)"
    log_info "Cluster: $cluster_name"
    log_info "Profile: $aws_profile"
    log_info "Region: $aws_region"
    
    # Helper function to check if command exists
    command_exists() {
        command -v "$1" >/dev/null 2>&1
    }
    
    # Check kubectl availability
    if ! command_exists kubectl; then
        log_warning "kubectl not found - skipping Kubernetes cleanup"
        log_info "Kubernetes resources will be cleaned up when cluster is destroyed"
        log_info "Install kubectl: brew install kubectl"
        return 0
    fi
    
    # Check kubectl context
    if ! kubectl config current-context >/dev/null 2>&1; then
        log_warning "kubectl context not configured - skipping Kubernetes cleanup"
        log_info "Configure kubectl: aws eks update-kubeconfig --region $aws_region --name $cluster_name --profile $aws_profile"
        log_info "Kubernetes resources will be cleaned up when cluster is destroyed"
        return 0
    fi
    
    local current_context=$(kubectl config current-context)
    log_info "Using kubectl context: $current_context"
    
    if [ "$dry_run" = "true" ]; then
        log_info "[DRY-RUN] Would scale down Kubernetes deployments to 0"
        log_info "[DRY-RUN] Would delete Kubernetes deployments and services"
        return 0
    fi
    
    # Step 1: Scale down all deployments to 0
    log_info "  Step 1.1: Scaling down Kubernetes deployments..."
    local deployments
    deployments=$(kubectl get deployments -o name 2>/dev/null | sed 's|deployment.apps/||' || echo "")
    
    if [ -n "$deployments" ]; then
        while IFS= read -r deployment; do
            if [ -n "$deployment" ]; then
                log_info "    Scaling down deployment: $deployment"
                kubectl scale deployment "$deployment" --replicas=0 2>/dev/null || {
                    log_warning "      Failed to scale down deployment: $deployment"
                }
            fi
        done <<< "$deployments"
    else
        log_info "    No deployments found"
    fi
    
    # Step 2: Wait for pods to terminate
    log_info "  Step 1.2: Waiting for pods to terminate..."
    local max_wait=60  # 5 minutes (60 * 5 seconds)
    local wait_count=0
    
    while [ $wait_count -lt $max_wait ]; do
        local running_pods
        running_pods=$(kubectl get pods --field-selector=status.phase!=Succeeded,status.phase!=Failed -o name 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        
        if [ "${running_pods:-0}" -eq 0 ]; then
            log_success "    All pods have terminated"
            break
        fi
        
        wait_count=$((wait_count + 1))
        if [ $((wait_count % 6)) -eq 0 ]; then
            log_info "    Still waiting... ($running_pods pods running)"
        fi
        sleep 5
    done
    
    if [ $wait_count -ge $max_wait ]; then
        log_warning "    Timeout waiting for pods to terminate (some pods may still be running)"
        log_warning "    Cluster deletion will force-delete remaining pods"
    fi
    
    # Step 3: Delete deployments and services (optional - cluster deletion will handle it)
    # This step is optional - cluster deletion will force-delete all resources
    # But doing it explicitly can speed up teardown and provide cleaner output
    log_info "  Step 1.3: Deleting Kubernetes resources..."
    
    # Delete deployments
    local deleted_deployments
    deleted_deployments=$(kubectl delete deployment --all --grace-period=0 2>/dev/null | grep -c "deleted" || echo "0")
    if [ "${deleted_deployments:-0}" -gt 0 ]; then
        log_info "    Deleted $deleted_deployments deployment(s)"
    fi
    
    # Delete services (except kubernetes service)
    local deleted_services
    deleted_services=$(kubectl delete service --all --ignore-not-found 2>/dev/null | grep -c "deleted" || echo "0")
    if [ "${deleted_services:-0}" -gt 0 ]; then
        log_info "    Deleted $deleted_services service(s)"
    fi
    
    log_success "EKS services stopped and cleaned up"
    return 0
}

