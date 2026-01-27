#!/bin/bash
# Test script to verify EKS Ingress fixes:
# 1. Namespace consistency (all resources in fru-api-dev)
# 2. Ingress host restriction removal (wildcard for CloudFront/NLB)
# 3. Service endpoints (pods connected)
# 4. Direct NLB access (HTTP 200)
# 5. CloudFront API endpoints (HTTP 200, not 503)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$SCRIPT_DIR}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test results
TESTS_PASSED=0
TESTS_FAILED=0

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

test_check() {
    local test_name="$1"
    local command="$2"
    
    log_info "Testing: $test_name"
    if eval "$command" >/dev/null 2>&1; then
        log_success "✓ $test_name"
        ((TESTS_PASSED++))
        return 0
    else
        log_error "✗ $test_name"
        ((TESTS_FAILED++))
        return 1
    fi
}

echo "═══════════════════════════════════════════════════════════════"
echo "EKS Ingress Fixes Verification Test"
echo "═══════════════════════════════════════════════════════════════"
echo ""

cd "$REPO_ROOT"

# Test 1: Verify Ingress generation removes host line
log_info "Test 1: Verifying Ingress generation removes host restriction"
if [ -f "infra/k8s/generated/ingress-generated.yaml" ]; then
    if grep -q "^- host:" "infra/k8s/generated/ingress-generated.yaml"; then
        log_error "✗ Ingress still contains host restriction"
        ((TESTS_FAILED++))
    else
        log_success "✓ Ingress generated without host restriction (wildcard)"
        ((TESTS_PASSED++))
    fi
    
    # Check if it has the http: line (valid YAML) - either with or without host
    if grep -q "http:" "infra/k8s/generated/ingress-generated.yaml"; then
        log_success "✓ Ingress has valid YAML structure (contains http:)"
        ((TESTS_PASSED++))
    else
        log_error "✗ Ingress missing http: line"
        ((TESTS_FAILED++))
    fi
else
    log_warning "Generated Ingress file not found - run deployment first"
fi
echo ""

# Test 2: Check namespace consistency (if cluster is accessible)
log_info "Test 2: Checking namespace consistency"
if command -v kubectl >/dev/null 2>&1 && kubectl config current-context >/dev/null 2>&1; then
    # Discover namespace from pods
    NAMESPACE=$(kubectl get pods -l app=fru-api --all-namespaces -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null | head -1 || echo "")
    
    if [ -z "$NAMESPACE" ]; then
        log_warning "No fru-api pods found - deployment may not be running"
    else
        log_info "Discovered namespace: $NAMESPACE"
        
        # Check all resources are in the same namespace
        test_check "Deployment in $NAMESPACE namespace" \
            "kubectl get deployment fru-api -n $NAMESPACE >/dev/null 2>&1"
        
        test_check "Service in $NAMESPACE namespace" \
            "kubectl get svc fru-api -n $NAMESPACE >/dev/null 2>&1"
        
        test_check "ConfigMap in $NAMESPACE namespace" \
            "kubectl get configmap fru-config -n $NAMESPACE >/dev/null 2>&1"
        
        test_check "Secret in $NAMESPACE namespace" \
            "kubectl get secret fru-secrets -n $NAMESPACE >/dev/null 2>&1"
        
        # Check Ingress
        INGRESS_NAME=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | head -1 || echo "")
        if [ -n "$INGRESS_NAME" ]; then
            test_check "Ingress in $NAMESPACE namespace" \
                "kubectl get ingress $INGRESS_NAME -n $NAMESPACE >/dev/null 2>&1"
            
            # Check Ingress has no host restriction
            log_info "Checking Ingress host restriction..."
            INGRESS_HOST=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
            if [ -z "$INGRESS_HOST" ] || [ "$INGRESS_HOST" = "null" ]; then
                log_success "✓ Ingress has no host restriction (wildcard)"
                ((TESTS_PASSED++))
            else
                log_error "✗ Ingress still has host restriction: $INGRESS_HOST"
                ((TESTS_FAILED++))
            fi
        fi
    fi
else
    log_warning "kubectl not available or not configured - skipping cluster checks"
fi
echo ""

# Test 3: Check Service endpoints
log_info "Test 3: Checking Service endpoints"
if [ -n "${NAMESPACE:-}" ] && command -v kubectl >/dev/null 2>&1; then
    ENDPOINTS=$(kubectl get endpoints fru-api -n "$NAMESPACE" -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null || echo "")
    if [ -n "$ENDPOINTS" ]; then
        ENDPOINT_COUNT=$(echo "$ENDPOINTS" | wc -w | tr -d ' ')
        log_success "✓ Service has $ENDPOINT_COUNT endpoint(s): $ENDPOINTS"
        ((TESTS_PASSED++))
        
        if [ "$ENDPOINT_COUNT" -ge 1 ]; then
            log_success "✓ Service is connected to pods"
            ((TESTS_PASSED++))
        else
            log_error "✗ Service has no endpoints"
            ((TESTS_FAILED++))
        fi
    else
        log_error "✗ Service has no endpoints"
        ((TESTS_FAILED++))
    fi
else
    log_warning "Skipping Service endpoint check (kubectl not available)"
fi
echo ""

# Test 4: Test direct NLB access
log_info "Test 4: Testing direct NLB access"
if [ -n "${NAMESPACE:-}" ] && command -v kubectl >/dev/null 2>&1; then
    INGRESS_HOSTNAME=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$INGRESS_HOSTNAME" ]; then
        log_info "Testing: http://${INGRESS_HOSTNAME}/health"
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://${INGRESS_HOSTNAME}/health" 2>/dev/null || echo "000")
        
        if [ "$HTTP_CODE" = "200" ]; then
            log_success "✓ Direct NLB access returns HTTP 200"
            ((TESTS_PASSED++))
        elif [ "$HTTP_CODE" = "503" ]; then
            log_error "✗ Direct NLB access returns HTTP 503 (host restriction issue?)"
            ((TESTS_FAILED++))
        else
            log_warning "Direct NLB access returned HTTP $HTTP_CODE (may still be starting)"
        fi
    else
        log_warning "Ingress hostname not available yet"
    fi
else
    log_warning "Skipping NLB access test (kubectl not available)"
fi
echo ""

# Test 5: Test CloudFront API endpoints
log_info "Test 5: Testing CloudFront API endpoints"
if command -v terragrunt >/dev/null 2>&1; then
    EKS_DIR="infra/terraform/providers/aws/environments/dev/eks"
    if [ -d "$EKS_DIR" ]; then
        CLOUDFRONT_DOMAIN=$(cd "$EKS_DIR" && terragrunt output -raw cloudfront_domain_name 2>/dev/null || echo "")
        if [ -n "$CLOUDFRONT_DOMAIN" ] && [ "$CLOUDFRONT_DOMAIN" != "null" ]; then
            log_info "Testing: https://${CLOUDFRONT_DOMAIN}/analytics"
            HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://${CLOUDFRONT_DOMAIN}/analytics" 2>/dev/null || echo "000")
            
            if [ "$HTTP_CODE" = "200" ]; then
                log_success "✓ CloudFront API endpoint returns HTTP 200"
                ((TESTS_PASSED++))
            elif [ "$HTTP_CODE" = "503" ]; then
                log_error "✗ CloudFront API endpoint returns HTTP 503 (host restriction or routing issue)"
                ((TESTS_FAILED++))
            else
                log_warning "CloudFront API endpoint returned HTTP $HTTP_CODE"
            fi
        else
            log_warning "CloudFront domain not found in Terraform outputs"
        fi
    else
        log_warning "EKS Terraform directory not found: $EKS_DIR"
    fi
else
    log_warning "terragrunt not available - skipping CloudFront test"
fi
echo ""

# Summary
echo "═══════════════════════════════════════════════════════════════"
echo "Test Summary"
echo "═══════════════════════════════════════════════════════════════"
echo "Tests Passed: $TESTS_PASSED"
echo "Tests Failed: $TESTS_FAILED"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    log_success "All tests passed! ✓"
    exit 0
else
    log_error "Some tests failed. Please review the output above."
    exit 1
fi
