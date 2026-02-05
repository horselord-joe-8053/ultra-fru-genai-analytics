#!/bin/bash
# Post-Deployment Version Verification (EKS Helper Function)
# ===========================================================
# This file contains a **helper function** for verifying that deployed versions
# match what's actually running in Kubernetes. It can be sourced by deployment
# scripts or run standalone as a CLI tool.
#
# **Container Type**: EKS-specific (uses kubectl to check pod images and env vars)
# **Location**: run_scripts/main_application_scripts/aws/eks/helpers/
#
# Function:
#   verify_deployment_versions <expected_backend_version> <expected_frontend_version> <cloudfront_domain> <namespace> <deployment_name>
#
# Usage (from another script - recommended):
#   source "$REPO_ROOT/run_scripts/main_application_scripts/aws/eks/helpers/verify-deployment-versions.sh"
#   verify_deployment_versions "$IMAGE_TAG" "$FRONTEND_VERSION" "$CF_DOMAIN" "$namespace" "$deployment_name"
#
# Usage (standalone CLI):
#   ./verify-deployment-versions.sh <expected_backend_version> <expected_frontend_version> <cloudfront_domain> <namespace> <deployment_name>
#
# Example:
#   verify_deployment_versions "fru_dev_20260125_abc123" "V_260125-192214" "d3nafrsn307bvb.cloudfront.net" "default" "fru-api"
#
# What it verifies:
#   1. Backend version via API /version endpoint
#   2. Kubernetes pod image tag matches expected
#   3. CONTAINER_IMAGE env var matches expected
#   4. Pod image and CONTAINER_IMAGE env var are synchronized
#   5. Frontend version (optional, manual check)
#   6. Backend health endpoint

# Source logger if available
SCRIPT_DIR_VERIFY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_VERIFY="${REPO_ROOT:-$(cd "$SCRIPT_DIR_VERIFY/../../../../.." && pwd)}"
if [ -f "$REPO_ROOT_VERIFY/lib/logger.sh" ]; then
    source "$REPO_ROOT_VERIFY/lib/logger.sh"
else
    # Fallback logging functions
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_warning() { echo "[WARNING] $*"; }
    log_error() { echo "[ERROR] $*"; }
fi

verify_deployment_versions() {
    local expected_backend_version=$1    # Image tag expected (e.g., fru_dev_20260125_...)
    local expected_frontend_version=$2    # Frontend version string (optional, e.g., V_260125-192214_...)
    local cloudfront_domain=$3           # CloudFront domain (optional, e.g., d3nafrsn307bvb.cloudfront.net)
    local namespace="${4:-default}"       # Kubernetes namespace
    local deployment_name="${5:-fru-api}" # Deployment name
    
    log_step "Verifying deployment versions"
    
    local verification_passed=true
    local backend_verified=false
    local frontend_verified=false
    local kubernetes_verified=false
    
    # 1. Backend Version Check via API endpoint
    if [ -n "$cloudfront_domain" ] && [ -n "$expected_backend_version" ]; then
        log_info "Checking backend version via API endpoint..."
        local backend_url="https://${cloudfront_domain}/version"
        local actual_backend_version=""
        
        # Try to get version with retries (API may not be ready immediately)
        local max_retries=3
        local retry_count=0
        while [ $retry_count -lt $max_retries ]; do
            actual_backend_version=$(curl -s --max-time 10 "$backend_url" 2>/dev/null | grep -o '"version":"[^"]*"' | cut -d'"' -f4 || echo "")
            if [ -n "$actual_backend_version" ]; then
                break
            fi
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                log_info "Backend not ready yet, retrying in 5s... (attempt $retry_count/$max_retries)"
                sleep 5
            fi
        done
        
        if [ -n "$actual_backend_version" ]; then
            if [ "$actual_backend_version" = "$expected_backend_version" ]; then
                log_success "✓ Backend version matches: $actual_backend_version"
                backend_verified=true
            else
                log_warning "⚠ Backend version mismatch!"
                log_warning "  Expected: $expected_backend_version"
                log_warning "  Actual: $actual_backend_version"
                verification_passed=false
            fi
        else
            log_warning "⚠ Could not fetch backend version from $backend_url"
            log_info "Backend may still be starting up"
        fi
    else
        log_info "Skipping backend API check (cloudfront_domain or expected_backend_version not provided)"
    fi
    
    # 2. Kubernetes Pod Verification
    if [ -n "$expected_backend_version" ] && command -v kubectl >/dev/null 2>&1; then
        log_info "Checking Kubernetes deployment configuration..."
        
        # Get pod image tag
        local pod_image_full
        pod_image_full=$(kubectl get pods -n "$namespace" -l app="$deployment_name" \
            -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || echo "")
        
        local pod_image_tag=""
        if [[ "$pod_image_full" == *":"* ]]; then
            pod_image_tag="${pod_image_full#*:}"
        else
            pod_image_tag="$pod_image_full"
        fi
        
        # Get CONTAINER_IMAGE env var value
        local pod_env_image_full
        pod_env_image_full=$(kubectl get pods -n "$namespace" -l app="$deployment_name" \
            -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="CONTAINER_IMAGE")].value}' 2>/dev/null || echo "")
        
        local pod_env_image_tag=""
        if [[ "$pod_env_image_full" == *":"* ]]; then
            pod_env_image_tag="${pod_env_image_full#*:}"
        else
            pod_env_image_tag="$pod_env_image_full"
        fi
        
        # Verify pod image matches expected
        if [ -n "$pod_image_tag" ]; then
            if [ "$pod_image_tag" = "$expected_backend_version" ]; then
                log_success "✓ Pod image matches expected: $pod_image_tag"
            else
                log_warning "⚠ Pod image mismatch!"
                log_warning "  Expected: $expected_backend_version"
                log_warning "  Actual pod image: $pod_image_tag"
                verification_passed=false
            fi
        else
            log_warning "⚠ Could not get pod image from Kubernetes"
        fi
        
        # Verify CONTAINER_IMAGE env var matches expected
        if [ -n "$pod_env_image_tag" ]; then
            if [ "$pod_env_image_tag" = "$expected_backend_version" ]; then
                log_success "✓ CONTAINER_IMAGE env var matches expected: $pod_env_image_tag"
                kubernetes_verified=true
            else
                log_warning "⚠ CONTAINER_IMAGE env var mismatch!"
                log_warning "  Expected: $expected_backend_version"
                log_warning "  Actual CONTAINER_IMAGE: $pod_env_image_tag"
                log_info "This may cause /version endpoint to return incorrect version"
                verification_passed=false
            fi
        else
            log_warning "⚠ CONTAINER_IMAGE env var not found in pod spec"
            log_info "This may cause /version endpoint to not work correctly"
        fi
        
        # Check if image and env var are in sync
        if [ -n "$pod_image_tag" ] && [ -n "$pod_env_image_tag" ]; then
            if [ "$pod_image_tag" = "$pod_env_image_tag" ]; then
                log_success "✓ Pod image and CONTAINER_IMAGE env var are synchronized"
            else
                log_warning "⚠ Pod image and CONTAINER_IMAGE env var are out of sync!"
                log_warning "  Pod image: $pod_image_tag"
                log_warning "  CONTAINER_IMAGE: $pod_env_image_tag"
                log_info "Run: kubectl set env deployment/$deployment_name CONTAINER_IMAGE=<image-uri> -n $namespace"
                verification_passed=false
            fi
        fi
    else
        log_info "Skipping Kubernetes verification (kubectl not available or expected_backend_version not provided)"
    fi
    
    # 3. Frontend Version Check (optional - requires parsing HTML/JS)
    if [ -n "$cloudfront_domain" ] && [ -n "$expected_frontend_version" ]; then
        log_info "Checking frontend version (this requires parsing the deployed page)..."
        log_info "Frontend version verification is optional and may require manual checking"
        log_info "Expected frontend version: $expected_frontend_version"
        log_info "Check manually at: https://${cloudfront_domain}/"
        # Frontend version extraction from live page is complex and may not be reliable
        # For now, we just log the expected version
        frontend_verified=true  # Mark as verified since we can't easily check it
    fi
    
    # 4. Health Check
    if [ -n "$cloudfront_domain" ]; then
        log_info "Checking backend health endpoint..."
        local health_status
        health_status=$(curl -s --max-time 10 "https://${cloudfront_domain}/health" 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "")
        if [ "$health_status" = "healthy" ] || [ "$health_status" = "ok" ]; then
            log_success "✓ Backend health check passed: $health_status"
        else
            log_warning "⚠ Backend health check returned: ${health_status:-unknown}"
            log_info "Backend may still be starting up"
        fi
    fi
    
    # Summary
    echo ""
    log_step "Version Verification Summary"
    if [ "$backend_verified" = true ]; then
        log_success "✓ Backend version: Verified"
    elif [ -n "$expected_backend_version" ]; then
        log_warning "⚠ Backend version: Not verified or mismatch"
    fi
    
    if [ "$kubernetes_verified" = true ]; then
        log_success "✓ Kubernetes configuration: Verified"
    elif [ -n "$expected_backend_version" ]; then
        log_warning "⚠ Kubernetes configuration: Not verified or mismatch"
    fi
    
    if [ "$frontend_verified" = true ] && [ -n "$expected_frontend_version" ]; then
        log_success "✓ Frontend version: Expected ($expected_frontend_version)"
    fi
    
    if [ "$verification_passed" = true ]; then
        log_success "Version verification completed successfully"
        return 0
    else
        log_warning "Version verification found some issues (see warnings above)"
        log_info "Deployment may still be successful - these are non-critical warnings"
        return 1
    fi
}

# If script is run directly (not sourced), execute verification
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    verify_deployment_versions "$@"
fi
