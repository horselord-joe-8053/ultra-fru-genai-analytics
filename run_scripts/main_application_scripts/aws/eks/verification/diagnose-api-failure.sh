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

  echo ""
  log_step "Diagnosing EKS API failure (namespace: default, app=fru-api)"

  log_info "Getting pods and their status..."
  kubectl get pods -l app=fru-api -o wide || log_warning "Could not list fru-api pods"

  log_info "Describing one fru-api pod (for events and container status)..."
  local pod_name
  pod_name=$(kubectl get pods -l app=fru-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -n "$pod_name" ]; then
    kubectl describe pod "$pod_name" || log_warning "Could not describe pod $pod_name"
    log_info "Recent logs from $pod_name:"
    kubectl logs "$pod_name" --tail=80 || log_warning "Could not fetch logs for $pod_name"
  else
    log_warning "No fru-api pods found to describe/log"
  fi

  log_info "Describing Service and Ingress for fru-api..."
  kubectl get svc fru-api -o wide || log_warning "Could not get Service fru-api"
  kubectl describe svc fru-api || log_warning "Could not describe Service fru-api"
  kubectl get ingress fru-api-ingress -o wide || log_warning "Could not get Ingress fru-api-ingress"
  kubectl describe ingress fru-api-ingress || log_warning "Could not describe Ingress fru-api-ingress"

  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  eks_diagnose_api_failure
fi


