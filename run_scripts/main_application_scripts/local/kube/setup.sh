#!/bin/bash
# Setup local Kubernetes cluster for development
# Supports: minikube, kind, docker-desktop
# Usage: ./setup.sh [minikube|kind|docker-desktop]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"

K8S_TYPE="${1:-minikube}"  # minikube, kind, or docker-desktop

log_step "Setting up local Kubernetes cluster: $K8S_TYPE"

case "$K8S_TYPE" in
  minikube)
    log_info "Setting up minikube..."
    if ! command -v minikube >/dev/null 2>&1; then
      log_error "minikube not installed. Install via: brew install minikube"
      exit 1
    fi
    
    if minikube status >/dev/null 2>&1; then
      log_info "Minikube cluster already running"
    else
      log_info "Starting minikube cluster..."
      minikube start --driver=docker --memory=4096 --cpus=2
    fi
    
    kubectl config use-context minikube
    log_success "Minikube cluster ready"
    ;;
    
  kind)
    log_info "Setting up kind..."
    if ! command -v kind >/dev/null 2>&1; then
      log_error "kind not installed. Install via: brew install kind"
      exit 1
    fi
    
    if kind get clusters 2>/dev/null | grep -q "^fru-local$"; then
      log_info "Kind cluster 'fru-local' already exists"
    else
      log_info "Creating kind cluster 'fru-local'..."
      kind create cluster --name fru-local --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "role=ingress"
EOF
    fi
    
    kubectl config use-context kind-fru-local
    log_success "Kind cluster ready"
    ;;
    
  docker-desktop)
    log_info "Using Docker Desktop Kubernetes..."
    if ! kubectl config current-context 2>/dev/null | grep -q "docker-desktop"; then
      log_error "Docker Desktop Kubernetes not enabled or not selected"
      log_info "Enable it in Docker Desktop → Settings → Kubernetes"
      exit 1
    fi
    kubectl config use-context docker-desktop
    log_success "Docker Desktop Kubernetes ready"
    ;;
    
  *)
    log_error "Unknown Kubernetes type: $K8S_TYPE"
    log_info "Usage: $0 [minikube|kind|docker-desktop]"
    exit 1
    ;;
esac

log_info "Verifying cluster..."
kubectl get nodes

log_success "Local Kubernetes cluster ready: $K8S_TYPE"

