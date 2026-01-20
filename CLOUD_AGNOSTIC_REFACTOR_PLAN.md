# Cloud-Agnostic Kubernetes Refactor Plan

## Executive Summary

**Goal**: Make Kubernetes-based deployment (`infra/k8s/`) as cloud-agnostic as possible while leveraging cloud-specific managed services (CloudFront, Aurora) for cost/performance benefits.

**Strategy**: Hybrid approach - containerize core application components (cloud-agnostic) while using cloud-specific services for infrastructure (cost-effective, managed).

## Current State Analysis

### Cloud-Specific Dependencies in `infra/k8s/`

#### 1. **ingress.yaml** (AWS-specific)
```yaml
annotations:
  kubernetes.io/ingress.class: alb              # AWS ALB Controller
  alb.ingress.kubernetes.io/scheme: internet-facing  # AWS-specific
  alb.ingress.kubernetes.io/target-type: ip     # AWS-specific
```
**Impact**: HIGH - Won't work on GKE/AKS without modification

#### 2. **configmap.yaml** (Cloud-specific references)
```yaml
pghost: "${PGHOST}"  # Aurora endpoint (AWS-specific)
aws-region: "${AWS_REGION}"  # AWS-specific
aws-bedrock-inference-profile-id: "${AWS_BEDROCK_INFERENCE_PROFILE_ID}"  # AWS-specific
```
**Impact**: MEDIUM - Environment variables can be abstracted

#### 3. **deployment.yaml** (Partially cloud-specific)
```yaml
dnsPolicy: None
dnsConfig:
  nameservers:
    - "169.254.169.253"  # AWS VPC DNS (AWS-specific)
```
**Impact**: MEDIUM - DNS config is AWS-specific

#### 4. **deployment.yaml** (Cloud-agnostic parts)
```yaml
# Container image: Cloud-agnostic (works anywhere)
image: ${CONTAINER_IMAGE}

# Resource limits: Cloud-agnostic
resources:
  requests:
    cpu: "500m"
    memory: "512Mi"
```
**Impact**: LOW - Standard Kubernetes

### External Dependencies (Terraform/IaC)

#### Cloud-Specific:
- **CloudFront**: AWS-specific (CDN)
- **Aurora**: AWS-specific (database)
- **ALB**: AWS-specific (load balancer)
- **ECR**: AWS-specific (container registry)
- **S3**: AWS-specific (object storage)

#### Cloud-Agnostic (in theory):
- **EKS Cluster**: Can use GKE/AKS instead
- **VPC/Networking**: Cloud-agnostic concepts (different implementations)
- **IAM Roles**: Cloud-agnostic concepts (different implementations)

## Proposed Architecture

### Principle: "Containerize Core, Leverage Managed Services"

#### Containerized (Cloud-Agnostic)
1. **Backend API** (`backend/api/app.py`)
   - Flask application
   - Runs in container
   - Works on EKS, GKE, AKS

2. **Analytics Scheduler** (`spark_jobs/scheduler.py`)
   - Python scheduler
   - Runs in container
   - Works on EKS, GKE, AKS

3. **Frontend** (React app)
   - Static assets
   - Can be containerized (nginx container)
   - Works on EKS, GKE, AKS

#### Cloud-Specific Managed Services (Cost/Performance Benefits)
1. **Database**: Aurora (AWS) / Cloud SQL (GCP) / Azure Database (Azure)
   - Managed service (high availability, backups, scaling)
   - Better than self-hosted PostgreSQL in Kubernetes

2. **CDN**: CloudFront (AWS) / Cloud CDN (GCP) / Azure CDN (Azure)
   - Global edge caching
   - Better performance than containerized nginx

3. **Load Balancer**: ALB (AWS) / Cloud Load Balancing (GCP) / Application Gateway (Azure)
   - Managed service (high availability, SSL termination)
   - Better than containerized ingress controller (for production)

4. **Container Registry**: ECR (AWS) / GCR (GCP) / ACR (Azure)
   - Managed service (security scanning, lifecycle policies)
   - Standard across all clouds

### Detailed Refactor Plan

## Phase 1: Make Ingress Cloud-Agnostic

### Current: AWS ALB Controller
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
```

### Target: Multi-Cloud Ingress

**Option A: Ingress Classes (Recommended)**
```yaml
# infra/k8s/ingress.yaml (base, cloud-agnostic)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: fru-api-ingress
spec:
  ingressClassName: ${INGRESS_CLASS_NAME}  # Set via env: alb (AWS), gce (GCP), nginx (AKS)
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: fru-api
                port:
                  number: 80
```

**Cloud-Specific Annotations (Kustomize Overlays)**
```
infra/k8s/
  ├── base/
  │   ├── ingress.yaml          # Cloud-agnostic
  │   ├── deployment.yaml       # Cloud-agnostic
  │   ├── service.yaml          # Cloud-agnostic
  │   └── configmap.yaml        # Cloud-agnostic (templates)
  ├── overlays/
  │   ├── aws/
  │   │   └── ingress-patch.yaml    # AWS ALB annotations
  │   ├── gcp/
  │   │   └── ingress-patch.yaml    # GCP Load Balancer annotations
  │   └── azure/
  │       └── ingress-patch.yaml    # Azure Application Gateway annotations
```

**Implementation:**
```yaml
# infra/k8s/overlays/aws/ingress-patch.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: fru-api-ingress
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
```

**Option B: Separate Ingress Files (Simpler)**
```
infra/k8s/
  ├── ingress-aws.yaml      # AWS ALB annotations
  ├── ingress-gcp.yaml      # GCP Load Balancer annotations
  ├── ingress-azure.yaml    # Azure Application Gateway annotations
  └── ingress-generic.yaml  # Generic (nginx ingress)
```

**Recommendation: Option A (Kustomize)** - Better maintainability, single source of truth

## Phase 2: Abstract Cloud-Specific Config

### Current: Direct Cloud References
```yaml
# configmap.yaml
pghost: "${PGHOST}"  # Aurora endpoint
aws-region: "${AWS_REGION}"
```

### Target: Environment-Aware Config
```yaml
# configmap.yaml (cloud-agnostic)
database:
  host: "${DB_HOST}"           # Abstracted (Aurora/Cloud SQL/Azure DB)
  port: "${DB_PORT}"
  database: "${DB_NAME}"
  user: "${DB_USER}"

# Cloud provider config (optional, provider-specific)
cloud:
  provider: "${CLOUD_PROVIDER}"  # aws/gcp/azure
  region: "${CLOUD_REGION}"
  
# Provider-specific settings (via environment variables)
# AWS: AWS_REGION, AWS_BEDROCK_*
# GCP: GCP_REGION, GCP_AI_*
# Azure: AZURE_REGION, AZURE_AI_*
```

**Implementation:**
- Use environment variable abstraction (already done)
- Cloud provider detected at runtime (or via env var)
- Provider-specific features gated behind feature flags

## Phase 3: Abstract DNS Configuration

### Current: AWS VPC DNS
```yaml
dnsPolicy: None
dnsConfig:
  nameservers:
    - "169.254.169.253"  # AWS VPC DNS
```

### Target: Cloud-Agnostic DNS
```yaml
# Option A: Use cluster DNS (CoreDNS/Kube-DNS)
dnsPolicy: ClusterFirst  # Default, works everywhere
# No dnsConfig needed

# Option B: Conditional DNS (via Kustomize)
# overlays/aws/deployment-patch.yaml
dnsPolicy: None
dnsConfig:
  nameservers:
    - "169.254.169.253"  # AWS VPC DNS

# overlays/gcp/deployment-patch.yaml
dnsPolicy: ClusterFirst  # Use GKE DNS
```

**Recommendation: Option A (ClusterFirst)** - Simpler, works everywhere  
**Note**: May require CoreDNS configuration for external DNS resolution (but standard K8s approach)

## Phase 4: Containerize Frontend (Optional)

### Current: S3 + CloudFront
- Static files in S3
- CloudFront CDN

### Target: Containerized Frontend (Cloud-Agnostic)
```dockerfile
# Dockerfile.frontend
FROM nginx:alpine
COPY dist/ /usr/share/nginx/html/
EXPOSE 80
```

**Deployment:**
```yaml
# deployment-frontend.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fru-frontend
spec:
  replicas: 2
  template:
    spec:
      containers:
      - name: frontend
        image: ${FRONTEND_IMAGE}
        ports:
        - containerPort: 80
```

**Ingress:**
```yaml
# Ingress routes frontend (/) and backend (/api)
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: fru-frontend
            port:
              number: 80
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: fru-api
            port:
              number: 80
```

**Cost Comparison:**
- **Containerized**: ~$30-50/month (2 pods, minimal resources)
- **S3 + CloudFront**: ~$5-10/month (storage + requests)
- **Verdict**: S3 + CloudFront is cheaper, but containerized is cloud-agnostic

**Recommendation**: Keep S3 + CloudFront for AWS (cost-effective), but support containerized for multi-cloud

## Phase 5: Multi-Cloud Deployment Structure

### Proposed Structure
```
infra/
  ├── k8s/
  │   ├── base/                    # Cloud-agnostic manifests
  │   │   ├── deployment.yaml
  │   │   ├── service.yaml
  │   │   ├── configmap.yaml.template
  │   │   └── kustomization.yaml
  │   └── overlays/                # Cloud-specific patches
  │       ├── aws/
  │       │   ├── ingress-patch.yaml
  │       │   ├── deployment-patch.yaml (DNS)
  │       │   └── kustomization.yaml
  │       ├── gcp/
  │       │   ├── ingress-patch.yaml
  │       │   └── kustomization.yaml
  │       └── azure/
  │           ├── ingress-patch.yaml
  │           └── kustomization.yaml
  └── terraform/
      ├── providers/
      │   ├── aws/
      │   │   ├── modules/
      │   │   │   ├── aurora/         # AWS-specific
      │   │   │   ├── cloudfront/     # AWS-specific
      │   │   │   └── eks/            # AWS-specific
      │   │   └── environments/
      │   ├── gcp/
      │   │   ├── modules/
      │   │   │   ├── cloud-sql/      # GCP-specific
      │   │   │   ├── cloud-cdn/      # GCP-specific
      │   │   │   └── gke/            # GCP-specific
      │   │   └── environments/
      │   └── azure/
      │       ├── modules/
      │       │   ├── azure-db/       # Azure-specific
      │       │   ├── azure-cdn/      # Azure-specific
      │       │   └── aks/            # Azure-specific
      │       └── environments/
```

### Deployment Scripts
```
run_scripts/main_application_scripts/
  ├── aws/
  │   └── run.sh                    # AWS-specific orchestration
  ├── gcp/
  │   └── run.sh                    # GCP-specific orchestration
  ├── azure/
  │   └── run.sh                    # Azure-specific orchestration
  └── shared/
      ├── kubernetes-manifests.sh   # Cloud-agnostic K8s operations
      └── container-deploy-common.sh # Common deployment logic
```

## Phase 6: Cloud Provider Abstraction Layer

### Environment Detection
```bash
# run_scripts/shared/cloud-provider.sh
detect_cloud_provider() {
  # Detect based on:
  # 1. CLOUD_PROVIDER env var (explicit)
  # 2. kubectl context (eks, gke, aks)
  # 3. Terraform provider
}

get_cloud_provider_config() {
  local provider=$1
  case "$provider" in
    aws)
      echo "INGRESS_CLASS=alb"
      echo "DB_TYPE=aurora"
      echo "CDN_TYPE=cloudfront"
      ;;
    gcp)
      echo "INGRESS_CLASS=gce"
      echo "DB_TYPE=cloud-sql"
      echo "CDN_TYPE=cloud-cdn"
      ;;
    azure)
      echo "INGRESS_CLASS=azure"
      echo "DB_TYPE=azure-db"
      echo "CDN_TYPE=azure-cdn"
      ;;
  esac
}
```

### Deployment Orchestration
```bash
# run_scripts/main_application_scripts/aws/run.sh
deploy_eks_full() {
  # 1. Deploy cloud-specific infrastructure (Terraform)
  deploy_phase_deploy_infrastructure
  
  # 2. Deploy cloud-agnostic Kubernetes manifests
  deploy_phase_deploy_application
  
  # 3. Configure cloud-specific integrations (CloudFront, ALB)
  deploy_phase_configure_cloud_services
}

# run_scripts/shared/container-deploy-common.sh
deploy_phase_deploy_application() {
  # Cloud-agnostic: Works for AWS, GCP, Azure
  local provider="${CLOUD_PROVIDER:-aws}"
  local manifests_dir="infra/k8s"
  
  # Apply base manifests
  kubectl apply -k "$manifests_dir/base"
  
  # Apply cloud-specific overlay
  kubectl apply -k "$manifests_dir/overlays/$provider"
}
```

## Recommendations Summary

### ✅ Containerize (Cloud-Agnostic)
1. **Backend API** - Already containerized ✅
2. **Analytics Scheduler** - Already containerized ✅
3. **Frontend** - Optionally containerize (but keep S3+CloudFront for AWS)

### ✅ Use Managed Services (Cloud-Specific, Cost-Effective)
1. **Database**: Aurora (AWS) / Cloud SQL (GCP) / Azure Database (Azure)
   - **Why**: Managed HA, backups, scaling
   - **Cost**: Similar or cheaper than self-hosted
   - **Benefit**: Lower operational overhead

2. **CDN**: CloudFront (AWS) / Cloud CDN (GCP) / Azure CDN (Azure)
   - **Why**: Global edge caching, low latency
   - **Cost**: Very cheap (~$5-10/month)
   - **Benefit**: Better performance than containerized nginx

3. **Load Balancer**: ALB (AWS) / Cloud Load Balancing (GCP) / Application Gateway (Azure)
   - **Why**: Managed HA, SSL termination, advanced routing
   - **Cost**: Similar to self-hosted ingress controller
   - **Benefit**: Lower operational overhead

### ✅ Abstraction Strategy
1. **Kubernetes Manifests**: Use Kustomize overlays (cloud-agnostic base + cloud-specific patches)
2. **Configuration**: Environment variable abstraction (already done)
3. **DNS**: Use ClusterFirst (cloud-agnostic) unless AWS-specific DNS required
4. **Deployment Scripts**: Provider-specific orchestration, shared K8s operations

## Migration Path

### Step 1: Refactor Ingress (Low Risk)
- Create base Ingress (cloud-agnostic)
- Create AWS overlay (ALB annotations)
- Test on existing EKS deployment

### Step 2: Refactor DNS Config (Low Risk)
- Change to ClusterFirst (or conditional via Kustomize)
- Test DNS resolution for Aurora

### Step 3: Abstract Configuration (Low Risk)
- Move cloud-specific config to environment variables
- Update ConfigMap generation

### Step 4: Multi-Cloud Support (Medium Risk)
- Create GCP/Azure overlays (when needed)
- Test on GKE/AKS (when available)

### Step 5: Containerize Frontend (Optional, High Risk)
- Create frontend container
- Update Ingress routing
- A/B test S3+CloudFront vs containerized

## Success Criteria

✅ `infra/k8s/base/` contains cloud-agnostic manifests  
✅ Cloud-specific config isolated in `overlays/`  
✅ Same K8s manifests work on EKS, GKE, AKS (with overlays)  
✅ Cloud-specific services (Aurora, CloudFront) abstracted via env vars  
✅ Deployment scripts support multiple cloud providers  
✅ No manual changes needed when switching providers (just overlay)

