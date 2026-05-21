# Local Kubernetes Setup

This directory contains scripts for setting up and managing local Kubernetes clusters for development.

## Supported Kubernetes Types

- **minikube**: Single-node Kubernetes cluster (recommended for macOS/Linux)
- **kind**: Kubernetes in Docker (lightweight, fast)
- **docker-desktop**: Docker Desktop's built-in Kubernetes

## Quick Start

### 1. Setup Local Kubernetes

```bash
# Using minikube (recommended)
./orchestration/local/kube/setup.sh minikube

# Using kind
./orchestration/local/kube/setup.sh kind

# Using Docker Desktop
./orchestration/local/kube/setup.sh docker-desktop
```

### 2. Install NGINX Ingress Controller

```bash
./orchestration/local/kube/install-ingress.sh minikube
```

### 3. Deploy Application

```bash
./orchestration/local/deploy.sh minikube
```

## Access Methods

### minikube
- **LoadBalancer**: `minikube tunnel` → `http://localhost`
- **NodePort**: `http://$(minikube ip):<nodeport>`

### kind
- **NodePort**: `http://localhost:<nodeport>`
- **Port Forward**: `kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80`

### docker-desktop
- **LoadBalancer**: `http://localhost` (if LoadBalancer IP assigned)
- **Port Forward**: `kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80`

## Prerequisites

- **minikube**: `brew install minikube`
- **kind**: `brew install kind`
- **Docker Desktop**: Enable Kubernetes in Settings
- **Helm**: `brew install helm`
- **kubectl**: Usually comes with Docker Desktop or install separately

## Notes

- Local Kubernetes uses **NodePort** for NGINX Ingress (no LoadBalancer support in most local setups)
- Same Kubernetes manifests (`module_infra_kubetypes/kube/common/`) work identically on local and cloud
- Database can be run in Docker Compose (`module_infra_kubetypes/nonkube/local/docker-compose.yml`) or in Kubernetes

