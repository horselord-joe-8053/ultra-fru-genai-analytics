#!/bin/bash
# EKS-specific diagnostics for API failures.
# Called indirectly via the common verification dispatcher in:
#   run_scripts/main_application_scripts/aws/verification/diagnose-failures.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"

if ! command -v log_info >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$REPO_ROOT/run_scripts/shared/logger.sh" 2>/dev/null || true
fi

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

eks_diagnose_api_failure() {
  if ! command_exists kubectl; then
    log_warning "kubectl not available; cannot auto-diagnose EKS API failure"
    return 1
  fi

  # Determine namespace from environment or discover from resources
  local namespace="${NAMESPACE:-}"
  if [ -z "$namespace" ]; then
    # Try to discover namespace from existing pods (across all namespaces)
    namespace=$(kubectl get pods -l app=fru-api --all-namespaces -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null | head -1 || echo "")
    if [ -z "$namespace" ]; then
      # Fallback: try to find from deployments
      namespace=$(kubectl get deployment -l app=fru-api --all-namespaces -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null | head -1 || echo "")
    fi
    if [ -z "$namespace" ]; then
      # Fallback: try to find from services
      namespace=$(kubectl get svc fru-api --all-namespaces -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null | head -1 || echo "")
    fi
    if [ -z "$namespace" ]; then
      # Last fallback: try to find from ingress
      namespace=$(kubectl get ingress -l app=fru-api --all-namespaces -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null | head -1 || echo "")
      # Also try ingress by name pattern
      if [ -z "$namespace" ]; then
        namespace=$(kubectl get ingress --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | grep -E "(fru-api|default)" | head -1 || echo "")
      fi
    fi
    if [ -z "$namespace" ]; then
      namespace="default"
      log_warning "Could not determine namespace, using default"
    else
      log_info "Discovered namespace: $namespace"
    fi
  else
    log_info "Using namespace from environment: $namespace"
  fi

  # Determine ingress name from environment or discover from namespace
  local ingress_name="${INGRESS_NAME:-}"
  if [ -z "$ingress_name" ]; then
    # Try to find ingress in the discovered namespace
    ingress_name=$(kubectl get ingress -n "$namespace" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | head -1 || echo "")
    if [ -z "$ingress_name" ]; then
      # Try namespace-specific pattern
      if [ "$namespace" != "default" ]; then
        local namespace_suffix="${namespace#fru-api-}"
        if kubectl get ingress "fru-api-ingress-${namespace_suffix}" -n "$namespace" >/dev/null 2>&1; then
          ingress_name="fru-api-ingress-${namespace_suffix}"
        fi
      fi
      # Fallback to default name
      if [ -z "$ingress_name" ]; then
        ingress_name="fru-api-ingress"
      fi
    fi
  fi

  echo ""
  log_step "Diagnosing EKS API failure (namespace: $namespace, app=fru-api)"

  log_info "Getting pods and their status..."
  kubectl get pods -l app=fru-api -n "$namespace" -o wide || log_warning "Could not list fru-api pods in namespace $namespace"

  log_info "Describing one fru-api pod (for events and container status)..."
  local pod_name
  pod_name=$(kubectl get pods -l app=fru-api -n "$namespace" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -n "$pod_name" ]; then
    kubectl describe pod "$pod_name" -n "$namespace" || log_warning "Could not describe pod $pod_name"
    log_info "Recent logs from $pod_name:"
    kubectl logs "$pod_name" -n "$namespace" --tail=80 || log_warning "Could not fetch logs for $pod_name"
  else
    log_warning "No fru-api pods found to describe/log in namespace $namespace"
  fi

  log_info "Describing Service and Ingress for fru-api..."
  kubectl get svc fru-api -n "$namespace" -o wide || log_warning "Could not get Service fru-api in namespace $namespace"
  kubectl describe svc fru-api -n "$namespace" || log_warning "Could not describe Service fru-api in namespace $namespace"
  kubectl get ingress "$ingress_name" -n "$namespace" -o wide || log_warning "Could not get Ingress $ingress_name in namespace $namespace"
  kubectl describe ingress "$ingress_name" -n "$namespace" || log_warning "Could not describe Ingress $ingress_name in namespace $namespace"

  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  eks_diagnose_api_failure
fi


