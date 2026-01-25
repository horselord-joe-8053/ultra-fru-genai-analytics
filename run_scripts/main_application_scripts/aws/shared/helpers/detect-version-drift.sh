#!/bin/bash
# Version Drift Detection
# Phase 6: Detects when running versions don't match expected deployment state
# Usage: detect-version-drift.sh [--namespace <namespace>] [--deployment <name>] [--environment <env>]

# Source logger if available
if [ -f "$(dirname "${BASH_SOURCE[0]}")/../../../../shared/logger.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../../../../shared/logger.sh"
else
    # Fallback logging functions
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_warning() { echo "[WARNING] $*"; }
    log_error() { echo "[ERROR] $*"; }
fi

detect_version_drift() {
    local namespace="${1:-default}"
    local deployment_name="${2:-fru-api}"
    local environment="${3:-dev}"
    
    local repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)}"
    local state_file="$repo_root/.deployment-state.json"
    
    log_step "Detecting version drift"
    log_info "  Namespace: $namespace"
    log_info "  Deployment: $deployment_name"
    log_info "  Environment: $environment"
    
    local drift_detected=false
    
    # Get expected version from deployment state
    local expected_backend=""
    if [ -f "$state_file" ] && command -v jq >/dev/null 2>&1; then
        expected_backend=$(jq -r '.last_deployment.backend_version' "$state_file" 2>/dev/null || echo "")
        if [ "$expected_backend" = "null" ] || [ -z "$expected_backend" ]; then
            expected_backend=""
        fi
    fi
    
    if [ -z "$expected_backend" ]; then
        log_warning "Could not get expected backend version from deployment state"
        log_info "State file: $state_file"
        log_info "Run a deployment first to create deployment state"
        return 1
    fi
    
    log_info "Expected backend version: $expected_backend"
    
    # Get actual running version from Kubernetes
    if ! command -v kubectl >/dev/null 2>&1; then
        log_error "kubectl not available - cannot check running versions"
        return 1
    fi
    
    # Check pod image
    local actual_pod_image_full
    actual_pod_image_full=$(kubectl get pods -n "$namespace" -l app="$deployment_name" \
        -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || echo "")
    
    local actual_pod_image_tag=""
    if [[ "$actual_pod_image_full" == *":"* ]]; then
        actual_pod_image_tag="${actual_pod_image_full#*:}"
    else
        actual_pod_image_tag="$actual_pod_image_full"
    fi
    
    # Check CONTAINER_IMAGE env var
    local actual_env_image_full
    actual_env_image_full=$(kubectl get pods -n "$namespace" -l app="$deployment_name" \
        -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="CONTAINER_IMAGE")].value}' 2>/dev/null || echo "")
    
    local actual_env_image_tag=""
    if [[ "$actual_env_image_full" == *":"* ]]; then
        actual_env_image_tag="${actual_env_image_full#*:}"
    else
        actual_env_image_tag="$actual_env_image_full"
    fi
    
    # Compare versions
    echo ""
    log_info "Version Comparison:"
    log_info "  Expected: $expected_backend"
    log_info "  Pod Image: ${actual_pod_image_tag:-not found}"
    log_info "  CONTAINER_IMAGE: ${actual_env_image_tag:-not found}"
    echo ""
    
    # Check pod image drift
    if [ -n "$actual_pod_image_tag" ]; then
        if [ "$actual_pod_image_tag" != "$expected_backend" ]; then
            log_warning "⚠ Version drift detected in pod image!"
            log_warning "  Expected: $expected_backend"
            log_warning "  Actual: $actual_pod_image_tag"
            drift_detected=true
        else
            log_success "✓ Pod image matches expected version"
        fi
    else
        log_warning "⚠ Could not get pod image - pods may not exist"
    fi
    
    # Check CONTAINER_IMAGE env var drift
    if [ -n "$actual_env_image_tag" ]; then
        if [ "$actual_env_image_tag" != "$expected_backend" ]; then
            log_warning "⚠ Version drift detected in CONTAINER_IMAGE env var!"
            log_warning "  Expected: $expected_backend"
            log_warning "  Actual: $actual_env_image_tag"
            log_info "This will cause /version endpoint to return incorrect version"
            drift_detected=true
        else
            log_success "✓ CONTAINER_IMAGE env var matches expected version"
        fi
    else
        log_warning "⚠ CONTAINER_IMAGE env var not found in pod spec"
        log_info "This may cause /version endpoint to not work correctly"
    fi
    
    # Check if image and env var are in sync
    if [ -n "$actual_pod_image_tag" ] && [ -n "$actual_env_image_tag" ]; then
        if [ "$actual_pod_image_tag" != "$actual_env_image_tag" ]; then
            log_warning "⚠ Pod image and CONTAINER_IMAGE env var are out of sync!"
            log_warning "  Pod image: $actual_pod_image_tag"
            log_warning "  CONTAINER_IMAGE: $actual_env_image_tag"
            drift_detected=true
        else
            log_success "✓ Pod image and CONTAINER_IMAGE env var are synchronized"
        fi
    fi
    
    echo ""
    if [ "$drift_detected" = true ]; then
        log_warning "════════════════════════════════════════════════════════════════"
        log_warning "Version drift detected!"
        log_warning "════════════════════════════════════════════════════════════════"
        log_info "To fix, run a new deployment or manually sync:"
        log_info "  kubectl set env deployment/$deployment_name CONTAINER_IMAGE=<expected-image-uri> -n $namespace"
        return 1
    else
        log_success "No version drift detected - all versions match expected state"
        return 0
    fi
}

# If script is run directly, parse arguments
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    local namespace="default"
    local deployment_name="fru-api"
    local environment="dev"
    
    while [ $# -gt 0 ]; do
        case "$1" in
            --namespace|-n)
                namespace="$2"
                shift 2
                ;;
            --deployment|-d)
                deployment_name="$2"
                shift 2
                ;;
            --environment|-e)
                environment="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [--namespace <ns>] [--deployment <name>] [--environment <env>]"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Usage: $0 [--namespace <ns>] [--deployment <name>] [--environment <env>]"
                exit 1
                ;;
        esac
    done
    
    detect_version_drift "$namespace" "$deployment_name" "$environment"
fi
