# NGINX Ingress Controller - Cloud-Agnostic Approach

## Overview

**NGINX Ingress Controller** provides a cloud-agnostic way to expose Kubernetes services via HTTP/HTTPS load balancing. Unlike AWS-specific LoadBalancer services, NGINX Ingress works identically on **EKS (AWS)**, **GKE (GCP)**, and **AKS (Azure)**.

## Architecture

```
Internet → CloudFront → NGINX Ingress Controller (Service: LoadBalancer) → Ingress Resource → Kubernetes Service → Pods
```

**Key Components:**
1. **NGINX Ingress Controller**: Pod that runs NGINX and watches for Ingress resources
2. **Ingress Resource**: Kubernetes manifest that defines routing rules
3. **Service (LoadBalancer)**: Exposes NGINX Ingress Controller (cloud creates LB automatically)
4. **Backend Service**: Your application service (ClusterIP)

## Implementation

### 1. Install NGINX Ingress Controller

**Using Helm (Recommended)**:
```bash
# Add NGINX Helm repo
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Install NGINX Ingress Controller
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"="nlb"  # AWS-specific, but optional
```

**Using Manifest (Cloud-Agnostic)**:
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
```

### 2. Create Ingress Resource

**File: `infra/k8s/ingress-nginx.yaml`**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: fru-api-ingress
  namespace: default
  annotations:
    # NGINX-specific annotations (cloud-agnostic)
    nginx.ingress.kubernetes.io/rewrite-target: /
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"  # For long-running queries
    nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
    # CORS (if needed)
    nginx.ingress.kubernetes.io/enable-cors: "true"
    nginx.ingress.kubernetes.io/cors-allow-origin: "https://d325mh0wy4je4e.cloudfront.net"
spec:
  ingressClassName: nginx  # Use NGINX Ingress Controller
  rules:
  - http:
      paths:
      # API endpoints - route to backend service
      - path: /query
        pathType: Prefix
        backend:
          service:
            name: fru-api
            port:
              number: 80
      - path: /query/stream
        pathType: Prefix
        backend:
          service:
            name: fru-api
            port:
              number: 80
      - path: /analytics
        pathType: Prefix
        backend:
          service:
            name: fru-api
            port:
              number: 80
      - path: /health
        pathType: Exact
        backend:
          service:
            name: fru-api
            port:
              number: 80
```

### 3. Backend Service (ClusterIP)

**File: `infra/k8s/service.yaml`**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: fru-api
  namespace: default
  labels:
    app: fru-api
spec:
  type: ClusterIP  # Changed back to ClusterIP - NGINX Ingress handles external access
  ports:
  - port: 80
    targetPort: 5000
    protocol: TCP
    name: http
  selector:
    app: fru-api
```

### 4. CloudFront Configuration

**Terraform: `infra/terraform/providers/aws/modules/frontend/main.tf`**
```hcl
# Get NGINX Ingress LoadBalancer DNS
# This is the LoadBalancer created for NGINX Ingress Controller service
data "kubernetes_service" "nginx_ingress" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }
}

# CloudFront origin points to NGINX Ingress LoadBalancer
origin {
  domain_name = data.kubernetes_service.nginx_ingress.status.0.load_balancer.0.ingress.0.hostname
  origin_id   = "NGINX-Ingress-${var.project_name}-${var.environment}"
  
  custom_origin_config {
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"
    origin_ssl_protocols   = ["TLSv1.2"]
  }
}
```

**Or use Terraform data source**:
```hcl
# Get NGINX Ingress LoadBalancer DNS from Kubernetes
data "external" "nginx_ingress_dns" {
  program = ["bash", "-c", <<-EOT
    kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo ""
  EOT
  ]
}

# Use in CloudFront origin
origin {
  domain_name = data.external.nginx_ingress_dns.result.result != "" ? data.external.nginx_ingress_dns.result.result : var.nginx_ingress_dns
  origin_id   = "NGINX-Ingress-${var.project_name}-${var.environment}"
  # ...
}
```

## Comparison: NGINX Ingress vs AWS LoadBalancer

| Aspect | AWS LoadBalancer (Current) | NGINX Ingress Controller |
|--------|---------------------------|-------------------------|
| **Cloud-Agnostic** | ❌ AWS-specific annotations | ✅ Works on EKS, GKE, AKS |
| **Path Routing** | ❌ Requires CloudFront cache behaviors | ✅ Native Ingress path routing |
| **SSL Termination** | ✅ ALB/NLB handles SSL | ✅ NGINX handles SSL (cert-manager) |
| **Complexity** | Medium (CloudFront + LB) | Low (Ingress only) |
| **Cost** | ~$16/month (LB) + CloudFront | ~$16/month (LB for NGINX) + CloudFront |
| **Features** | Basic load balancing | Advanced routing, rate limiting, auth |
| **Deployment** | Service type=LoadBalancer | Ingress Controller + Ingress resource |

## Benefits of NGINX Ingress

### 1. Cloud-Agnostic
- ✅ Same Ingress manifest works on **EKS**, **GKE**, **AKS**
- ✅ No cloud-specific annotations needed
- ✅ Portable across cloud providers

### 2. Advanced Routing
- ✅ Path-based routing (`/query`, `/analytics`)
- ✅ Host-based routing (multiple domains)
- ✅ Header-based routing
- ✅ Weighted routing (A/B testing)

### 3. Additional Features
- ✅ **Rate Limiting**: Protect backend from overload
- ✅ **Authentication**: Basic auth, OAuth2, etc.
- ✅ **SSL/TLS**: Automatic cert management (cert-manager)
- ✅ **WebSockets**: Native support
- ✅ **Load Balancing**: Round-robin, least-conn, IP hash

### 4. Simpler CloudFront Setup
- ✅ Single origin (NGINX Ingress LoadBalancer)
- ✅ No need for multiple cache behaviors
- ✅ NGINX handles path routing internally

## Migration Path

### Step 1: Install NGINX Ingress Controller
```bash
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace
```

### Step 2: Change Service Back to ClusterIP
```yaml
# infra/k8s/service.yaml
spec:
  type: ClusterIP  # No longer need LoadBalancer
```

### Step 3: Create Ingress Resource
```bash
kubectl apply -f infra/k8s/ingress-nginx.yaml
```

### Step 4: Get NGINX Ingress LoadBalancer DNS
```bash
NGINX_LB_DNS=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
```

### Step 5: Update CloudFront
- Update Terraform with NGINX Ingress LoadBalancer DNS
- Simplify CloudFront cache behaviors (single origin)

### Step 6: Clean Up
- Remove old LoadBalancer service
- Remove CloudFront cache behaviors (NGINX handles routing)

## Example: Complete Setup

**1. NGINX Ingress Controller Service** (created by Helm):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
spec:
  type: LoadBalancer  # Cloud creates LB automatically
  ports:
  - port: 80
    targetPort: 80
  selector:
    app.kubernetes.io/name: ingress-nginx
```

**2. Ingress Resource**:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: fru-api-ingress
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /query
        pathType: Prefix
        backend:
          service:
            name: fru-api
            port:
              number: 80
```

**3. CloudFront Origin**:
```
CloudFront → NGINX Ingress LoadBalancer (single origin)
         ↓
    NGINX Ingress Controller (routes based on path)
         ↓
    /query → fru-api service → pods
    /analytics → fru-api service → pods
```

## Cost Comparison

| Component | AWS LoadBalancer | NGINX Ingress |
|-----------|-----------------|---------------|
| **Load Balancer** | ~$16/month (direct to app) | ~$16/month (for NGINX) |
| **Controller Pods** | $0 (no controller) | ~$10/month (Fargate) |
| **CloudFront** | Required (for path routing) | Optional (for CDN) |
| **Total** | ~$16/month | ~$26/month |

**Note**: NGINX Ingress adds controller pod cost, but provides more features and cloud-agnostic approach.

## Recommendation

**For Cloud-Agnostic Approach**: Use **NGINX Ingress Controller**

**Benefits**:
- ✅ Truly cloud-agnostic (works on EKS, GKE, AKS)
- ✅ Advanced routing features
- ✅ Simpler CloudFront setup
- ✅ Better for multi-cloud deployments

**Trade-offs**:
- ❌ Additional controller pods (~$10/month)
- ❌ Slightly more complex setup
- ❌ Need to manage NGINX Ingress Controller

**For AWS-Only**: Current LoadBalancer approach is simpler and cheaper.

