# Multi-Cloud Infrastructure Architecture

This document outlines the multi-cloud infrastructure structure for FRU-GenAI Analytics, supporting deployments across **AWS**, **GCP**, **Azure**, and **Local** Kubernetes environments.

## 🎯 Overview

The infrastructure is designed with **maximum portability** in mind:
- **100% Portable Kubernetes Layer**: Same Kubernetes manifests (`infra/k8s/`) work identically across all providers
- **Provider-Specific Infrastructure**: Terraform modules for each cloud provider's native services
- **Unified Deployment Workflow**: Same deployment scripts pattern across all providers

---

## 📁 Directory Structure

### ✅ Implemented: AWS

```
infra/terraform/providers/aws/
├── environments/
│   ├── _component/                    ✅ Shared Terragrunt base templates
│   │   ├── infrastructure-base.hcl
│   │   ├── ecs-base.hcl
│   │   └── eks-base.hcl
│   ├── dev/
│   │   ├── env.hcl                    ✅ Dev environment config
│   │   ├── infrastructure/            ✅ Base infrastructure (VPC, Aurora, etc.)
│   │   ├── ecs/                       ✅ ECS deployment config
│   │   └── eks/                       ✅ EKS deployment config
│   └── prod/
│       ├── env.hcl                    ✅ Prod environment config
│       ├── infrastructure/            ✅ Base infrastructure
│       ├── ecs/                       ✅ ECS deployment config
│       └── eks/                       ✅ EKS deployment config
└── modules/
    ├── infrastructure/                ✅ VPC, Aurora, IAM, Secrets
    ├── vpc/                          ✅ VPC module
    ├── aurora/                       ✅ Aurora PostgreSQL module
    ├── iam/                          ✅ IAM roles and policies
    ├── secrets-manager/              ✅ AWS Secrets Manager
    ├── s3-data/                      ✅ S3 data lake bucket
    ├── ecs/                          ✅ ECS Fargate module
    ├── eks/                          ✅ EKS module (with ingress node group)
    ├── alb/                          ✅ Application Load Balancer
    └── frontend/                     ✅ S3 + CloudFront frontend

run_scripts/main_application_scripts/aws/
├── run.sh                           ✅ Main AWS deployment script
├── shared/                          ✅ Shared AWS deployment helpers
│   ├── container-deploy-common.sh
│   └── helpers/
│       ├── kubernetes-manifests.sh
│       ├── update-cloudfront-alb.sh
│       └── install-aws-load-balancer-controller.sh
├── ecs/                             ✅ ECS-specific deployment
└── eks/                             ✅ EKS-specific deployment
```

### 🚧 Pending: GCP (Google Cloud Platform)

```
infra/terraform/providers/gcp/
├── environments/
│   ├── _component/                    🚧 TODO: Shared Terragrunt base templates
│   │   └── .gitkeep
│   ├── dev/
│   │   ├── env.hcl                    🚧 TODO: Dev environment config
│   │   ├── infrastructure/            🚧 TODO: Base infrastructure (VPC, Cloud SQL, etc.)
│   │   │   └── .gitkeep
│   │   └── gke/                       🚧 TODO: GKE deployment config
│   │       └── .gitkeep
│   └── prod/
│       ├── env.hcl                    🚧 TODO: Prod environment config
│       ├── infrastructure/            🚧 TODO: Base infrastructure
│       │   └── .gitkeep
│       └── gke/                       🚧 TODO: GKE deployment config
│           └── .gitkeep
└── modules/
    ├── infrastructure/                🚧 TODO: VPC, Cloud SQL, IAM, Secret Manager
    ├── vpc/                          🚧 TODO: VPC network module
    ├── cloud-sql/                    🚧 TODO: Cloud SQL PostgreSQL module
    ├── iam/                          🚧 TODO: IAM roles and service accounts
    ├── secret-manager/               🚧 TODO: GCP Secret Manager
    ├── gcs-data/                     🚧 TODO: GCS data lake bucket
    ├── gke/                          🚧 TODO: GKE cluster module (with ingress node pool)
    │   └── .gitkeep
    └── frontend/                     🚧 TODO: GCS + Cloud CDN frontend
        └── .gitkeep

run_scripts/main_application_scripts/gcp/
└── .gitkeep                          🚧 TODO: GCP deployment scripts
    ├── run.sh                        🚧 TODO: Main GCP deployment script
    ├── shared/                       🚧 TODO: Shared GCP deployment helpers
    └── gke/                          🚧 TODO: GKE-specific deployment
```

**GCP Implementation Notes:**
- **GKE**: Google Kubernetes Engine (equivalent to AWS EKS)
- **Cloud SQL**: Managed PostgreSQL (equivalent to AWS Aurora)
- **Cloud CDN**: Content delivery network (equivalent to AWS CloudFront)
- **GCS**: Google Cloud Storage (equivalent to AWS S3)
- **VPC**: Google Cloud VPC (equivalent to AWS VPC)
- **Secret Manager**: GCP Secret Manager (equivalent to AWS Secrets Manager)

### 🚧 Pending: Azure (Microsoft Azure)

```
infra/terraform/providers/azure/
├── environments/
│   ├── _component/                    🚧 TODO: Shared Terragrunt base templates
│   │   └── .gitkeep
│   ├── dev/
│   │   ├── env.hcl                    🚧 TODO: Dev environment config
│   │   ├── infrastructure/            🚧 TODO: Base infrastructure (VNet, Azure Database, etc.)
│   │   │   └── .gitkeep
│   │   └── aks/                       🚧 TODO: AKS deployment config
│   │       └── .gitkeep
│   └── prod/
│       ├── env.hcl                    🚧 TODO: Prod environment config
│       ├── infrastructure/            🚧 TODO: Base infrastructure
│       │   └── .gitkeep
│       └── aks/                       🚧 TODO: AKS deployment config
│           └── .gitkeep
└── modules/
    ├── infrastructure/                🚧 TODO: VNet, Azure Database, IAM, Key Vault
    ├── vnet/                         🚧 TODO: Virtual Network module
    ├── azure-database/                🚧 TODO: Azure Database for PostgreSQL
    ├── iam/                          🚧 TODO: Azure RBAC and managed identities
    ├── key-vault/                    🚧 TODO: Azure Key Vault
    ├── storage-account/               🚧 TODO: Azure Blob Storage data lake
    ├── aks/                          🚧 TODO: AKS cluster module (with ingress node pool)
    │   └── .gitkeep
    └── frontend/                     🚧 TODO: Blob Storage + Azure CDN frontend
        └── .gitkeep

run_scripts/main_application_scripts/azure/
└── .gitkeep                          🚧 TODO: Azure deployment scripts
    ├── run.sh                        🚧 TODO: Main Azure deployment script
    ├── shared/                       🚧 TODO: Shared Azure deployment helpers
    └── aks/                          🚧 TODO: AKS-specific deployment
```

**Azure Implementation Notes:**
- **AKS**: Azure Kubernetes Service (equivalent to AWS EKS)
- **Azure Database**: Azure Database for PostgreSQL (equivalent to AWS Aurora)
- **Azure CDN**: Content delivery network (equivalent to AWS CloudFront)
- **Blob Storage**: Azure Blob Storage (equivalent to AWS S3)
- **VNet**: Virtual Network (equivalent to AWS VPC)
- **Key Vault**: Azure Key Vault (equivalent to AWS Secrets Manager)

### ✅ Implemented: Local (Development)

```
run_scripts/main_application_scripts/local/
├── kube/                             ✅ Local Kubernetes setup
│   ├── setup.sh                      ✅ Setup minikube/kind/Docker Desktop
│   ├── install-ingress.sh            ✅ Install NGINX Ingress Controller
│   └── README.md                     ✅ Local setup guide
├── deploy.sh                         ✅ Main local deployment script
└── deploy-app.sh                     ✅ Deploy application manifests

infra/k8s/                            ✅ 100% Portable Kubernetes Manifests
├── ingress.yaml                      ✅ NGINX Ingress resource (works on all providers)
├── service.yaml                      ✅ Application service (ClusterIP)
├── deployment.yaml                   ✅ Application deployment
├── configmap.yaml                    ✅ Application configuration template
├── secret.yaml                       ✅ Application secrets template
├── ingress-nginx-values-cloud.yaml   ✅ NGINX Helm values for cloud (LoadBalancer)
└── ingress-nginx-values-local.yaml   ✅ NGINX Helm values for local (NodePort)
```

**Local Implementation Notes:**
- Uses same Kubernetes manifests as cloud deployments
- Supports minikube, kind, and Docker Desktop Kubernetes
- No Terraform needed (uses local Docker/Kubernetes)
- Database can run in Docker Compose or Kubernetes

---

## 🏗️ Architecture Comparison

| Component | AWS | GCP | Azure | Local |
|-----------|-----|-----|-------|-------|
| **Kubernetes** | EKS ✅ | GKE 🚧 | AKS 🚧 | minikube/kind ✅ |
| **Database** | Aurora ✅ | Cloud SQL 🚧 | Azure DB 🚧 | PostgreSQL (Docker) ✅ |
| **Object Storage** | S3 ✅ | GCS 🚧 | Blob Storage 🚧 | Local FS ✅ |
| **CDN** | CloudFront ✅ | Cloud CDN 🚧 | Azure CDN 🚧 | None (localhost) ✅ |
| **Load Balancer** | ALB/NLB ✅ | GCP LB 🚧 | Azure LB 🚧 | NodePort/port-forward ✅ |
| **Secrets** | Secrets Manager ✅ | Secret Manager 🚧 | Key Vault 🚧 | Kubernetes Secrets ✅ |
| **Networking** | VPC ✅ | VPC 🚧 | VNet 🚧 | Local network ✅ |

---

## 📋 Implementation Status

### ✅ Completed

1. **AWS Infrastructure** (100%)
   - ✅ VPC, Aurora, IAM, Secrets Manager
   - ✅ ECS Fargate deployment
   - ✅ EKS deployment with ingress node group
   - ✅ CloudFront + S3 frontend
   - ✅ Deployment scripts and helpers

2. **Local Kubernetes** (100%)
   - ✅ Local Kubernetes setup (minikube/kind/Docker Desktop)
   - ✅ NGINX Ingress installation
   - ✅ Application deployment scripts
   - ✅ Same Kubernetes manifests as cloud

3. **Portable Kubernetes Layer** (100%)
   - ✅ Same manifests work on AWS, GCP, Azure, Local
   - ✅ NGINX Ingress Controller (cloud-agnostic)
   - ✅ ConfigMap/Secret templates

### 🚧 Pending Implementation

1. **GCP Infrastructure** (0%)
   - 🚧 GKE cluster module
   - 🚧 Cloud SQL PostgreSQL module
   - 🚧 VPC network module
   - 🚧 GCS + Cloud CDN frontend
   - 🚧 IAM and Secret Manager integration
   - 🚧 Deployment scripts

2. **Azure Infrastructure** (0%)
   - 🚧 AKS cluster module
   - 🚧 Azure Database for PostgreSQL module
   - 🚧 VNet module
   - 🚧 Blob Storage + Azure CDN frontend
   - 🚧 RBAC and Key Vault integration
   - 🚧 Deployment scripts

---

## 🎯 Implementation Roadmap

### Phase 1: GCP (GKE) Implementation

**Priority**: High (most similar to AWS)

**Steps**:
1. Create `infra/terraform/providers/gcp/modules/infrastructure/` module
   - VPC network with subnets
   - Cloud SQL PostgreSQL with pgvector extension
   - IAM service accounts and roles
   - Secret Manager integration
   - GCS bucket for data lake

2. Create `infra/terraform/providers/gcp/modules/gke/` module
   - GKE cluster with node pools
   - Ingress node pool (similar to AWS ingress node group)
   - Workload identity for pod authentication
   - Network policies

3. Create `infra/terraform/providers/gcp/modules/frontend/` module
   - GCS bucket for frontend static files
   - Cloud CDN distribution
   - Load balancer for API backend

4. Create Terragrunt configurations
   - `environments/dev/infrastructure/terragrunt.hcl`
   - `environments/dev/gke/terragrunt.hcl`
   - `environments/_component/infrastructure-base.hcl`
   - `environments/_component/gke-base.hcl`

5. Create deployment scripts
   - `run_scripts/main_application_scripts/gcp/run.sh`
   - `run_scripts/main_application_scripts/gcp/shared/helpers/`
   - `run_scripts/main_application_scripts/gcp/gke/deploy.sh`

**Estimated Effort**: 2-3 weeks

### Phase 2: Azure (AKS) Implementation

**Priority**: Medium

**Steps**:
1. Create `infra/terraform/providers/azure/modules/infrastructure/` module
   - Virtual Network (VNet) with subnets
   - Azure Database for PostgreSQL with pgvector
   - Managed identities and RBAC
   - Key Vault for secrets
   - Blob Storage account for data lake

2. Create `infra/terraform/providers/azure/modules/aks/` module
   - AKS cluster with node pools
   - Ingress node pool (similar to AWS/GCP)
   - Pod identity for authentication
   - Network policies

3. Create `infra/terraform/providers/azure/modules/frontend/` module
   - Blob Storage static website
   - Azure CDN distribution
   - Application Gateway for API backend

4. Create Terragrunt configurations
   - `environments/dev/infrastructure/terragrunt.hcl`
   - `environments/dev/aks/terragrunt.hcl`
   - `environments/_component/infrastructure-base.hcl`
   - `environments/_component/aks-base.hcl`

5. Create deployment scripts
   - `run_scripts/main_application_scripts/azure/run.sh`
   - `run_scripts/main_application_scripts/azure/shared/helpers/`
   - `run_scripts/main_application_scripts/azure/aks/deploy.sh`

**Estimated Effort**: 2-3 weeks

---

## 🔄 Portability Principles

### What's Portable (100%)

✅ **Kubernetes Manifests** (`infra/k8s/`)
- Same YAML files work identically on EKS, GKE, AKS, and local Kubernetes
- No provider-specific changes needed

✅ **NGINX Ingress Controller**
- Works identically across all Kubernetes providers
- Only difference: LoadBalancer (cloud) vs NodePort (local)

✅ **Application Code**
- Same Docker images work on all providers
- Same environment variables and configuration

### What's Provider-Specific

🚧 **Infrastructure Layer** (Terraform modules)
- VPC/VNet configuration
- Database provisioning (Aurora vs Cloud SQL vs Azure DB)
- Object storage (S3 vs GCS vs Blob Storage)
- CDN configuration (CloudFront vs Cloud CDN vs Azure CDN)
- IAM/RBAC and secrets management

🚧 **Deployment Scripts**
- Provider-specific CLI tools (AWS CLI vs gcloud vs az CLI)
- Provider-specific authentication
- Provider-specific resource provisioning

---

## 🚀 Quick Start

### AWS (Implemented)
```bash
# ECS deployment
./run_scripts/main_application_scripts/aws/run.sh deploy --container-type ecs dev

# EKS deployment
./run_scripts/main_application_scripts/aws/run.sh deploy --container-type eks dev
```

### Local (Implemented)
```bash
# Deploy to local Kubernetes (minikube)
./run_scripts/main_application_scripts/local/deploy.sh minikube

# Deploy to local Kubernetes (kind)
./run_scripts/main_application_scripts/local/deploy.sh kind

# Deploy to Docker Desktop Kubernetes
./run_scripts/main_application_scripts/local/deploy.sh docker-desktop
```

### GCP (Pending)
```bash
# TODO: Implement GKE deployment
./run_scripts/main_application_scripts/gcp/run.sh deploy --container-type gke dev
```

### Azure (Pending)
```bash
# TODO: Implement AKS deployment
./run_scripts/main_application_scripts/azure/run.sh deploy --container-type aks dev
```

---

## 📚 References

- **AWS EKS**: [Option B Refactor Plan](./OPTION_B_WITH_LOCAL_REVISED_PLAN.md)
- **Local Kubernetes**: [Local Setup Guide](./run_scripts/main_application_scripts/local/kube/README.md)
- **Kubernetes Manifests**: [infra/k8s/](./infra/k8s/)
- **Terraform Structure**: [FINAL_TERRAFORM_STRUCTURE.md](./FINAL_TERRAFORM_STRUCTURE.md)

---

## 🤝 Contributing

When implementing GCP or Azure support:

1. **Follow AWS patterns**: Use AWS implementation as reference
2. **Maintain portability**: Keep Kubernetes manifests provider-agnostic
3. **Update this README**: Mark completed items as ✅
4. **Test locally first**: Use local Kubernetes to validate manifests
5. **Document differences**: Note any provider-specific quirks

---

**Last Updated**: 2026-01-19
**Status**: AWS ✅ | Local ✅ | GCP 🚧 | Azure 🚧

