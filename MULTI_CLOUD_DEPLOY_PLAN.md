# Multi-Cloud Deployment Plan (Future: Azure, GCP)

This document outlines high-level requirements and steps for adding Azure and GCP cloud provider support to the FRU project.

## Overview

The current infrastructure supports AWS deployment. This plan documents what needs to be done to extend support to Azure and GCP while maintaining consistency with the existing AWS implementation.

## Current Architecture

### AWS Implementation
- **Infrastructure**: Terraform/Terragrunt in `infra/terraform/`
- **Orchestration**: Scripts in `run_scripts/aws/`
- **Services Used**:
  - ECS/EKS for compute
  - Aurora PostgreSQL for database
  - ECR for container registry
  - Secrets Manager for secrets
  - S3 + CloudFront for frontend
  - EMR Serverless (future) for Spark

## High-Level Requirements for Multi-Cloud

### 1. Infrastructure as Code (infra/)

#### Azure
**Directory Structure:**
```
infra/azure/
├── bicep/              # Recommended: Bicep templates (or terraform/)
│   ├── environments/
│   │   ├── dev/
│   │   └── prod/
│   └── modules/
└── README.md
```

**Service Mappings:**
- VPC → VNet (Virtual Network)
- Aurora PostgreSQL → Azure Database for PostgreSQL
- ECS/EKS → Azure Container Instances (ACI) / Azure Kubernetes Service (AKS)
- ECR → Azure Container Registry (ACR)
- Secrets Manager → Azure Key Vault
- S3 + CloudFront → Azure Storage + Azure CDN
- EMR → Azure Databricks or HDInsight

**IaC Tool:** Bicep (recommended) or Terraform

#### GCP
**Directory Structure:**
```
infra/gcp/
├── terraform/
│   ├── environments/
│   │   ├── dev/
│   │   └── prod/
│   └── modules/
└── README.md
```

**Service Mappings:**
- VPC → VPC (same name)
- Aurora PostgreSQL → Cloud SQL for PostgreSQL
- ECS/EKS → Cloud Run / Google Kubernetes Engine (GKE)
- ECR → Google Container Registry (GCR) / Artifact Registry
- Secrets Manager → Secret Manager
- S3 + CloudFront → Cloud Storage + Cloud CDN
- EMR → Dataproc

**IaC Tool:** Terraform (same as AWS)

### 2. Orchestration Scripts (run_scripts/)

#### Directory Structure
```
run_scripts/
├── aws/                # Existing
├── azure/              # New
│   ├── run.sh
│   ├── setup-azure-credentials.sh
│   ├── check-azure-credentials.sh
│   ├── shared/
│   │   ├── build-push-acr.sh
│   │   └── deploy-frontend.sh
│   ├── database/
│   │   ├── setup-database.sh
│   │   ├── ensure-pgvector.sh
│   │   └── validate-infra-outputs.sh
│   ├── bicep/  (or terraform/)
│   │   └── deploy.sh
│   └── verification/
│
└── gcp/                # New
    ├── run.sh
    ├── setup-gcp-credentials.sh
    ├── check-gcp-credentials.sh
    ├── shared/
    │   ├── build-push-gcr.sh
    │   └── deploy-frontend.sh
    ├── database/
    │   ├── setup-database.sh
    │   ├── ensure-pgvector.sh
    │   └── validate-infra-outputs.sh
    ├── terraform/
    │   └── deploy.sh
    └── verification/
```

#### Common Scripts (run_scripts/common/)

**Database Operations:**
- Add `common/database/init_schema_azure.sh`
- Add `common/database/init_schema_gcp.sh`
- Add `common/database/load_data_azure.sh`
- Add `common/database/load_data_gcp.sh`
- Update wrappers to route to Azure/GCP implementations

**Spark Operations:**
- Add `common/spark/setup-spark-azure.sh`
- Add `common/spark/setup-spark-gcp.sh`
- Update wrapper to route to Azure/GCP implementations

**Verification:**
- Enhance `common/verification/` scripts to support Azure/GCP
- Azure-specific: Azure Monitor, Application Insights
- GCP-specific: Cloud Monitoring, Cloud Logging

### 3. Environment Variables

#### Standardization
Add provider selection:
```bash
CLOUD_PROVIDER=aws  # or azure, gcp, local
```

#### Provider-Specific Variables
```bash
# AWS (existing)
AWS_REGION=us-east-1
AWS_PROFILE=admin

# Azure (new)
AZURE_LOCATION=eastus
AZURE_SUBSCRIPTION_ID=...
AZURE_TENANT_ID=...

# GCP (new)
GCP_PROJECT_ID=...
GCP_REGION=us-east1
GCP_ZONE=us-east1-b
```

#### Common Variables (Cloud-Agnostic)
```bash
# Database
PGUSER=...
PGPASSWORD=...
PGDATABASE=fru_db

# Application
OPENAI_API_KEY=...
LOG_LEVEL=...
ALLOWED_ORIGINS=...
```

### 4. Database Operations

#### Azure Database for PostgreSQL
- Use Azure REST API or direct connection (similar to AWS RDS Data API)
- pgvector extension support (same as AWS)
- Secrets in Azure Key Vault
- Implementation: `common/database/init_schema_azure.sh`, `common/database/load_data_azure.sh`

#### Cloud SQL for PostgreSQL
- Use Cloud SQL Proxy or direct connection
- pgvector extension support (same as AWS)
- Secrets in Secret Manager
- Implementation: `common/database/init_schema_gcp.sh`, `common/database/load_data_gcp.sh`

### 5. Container Registry

#### Azure Container Registry (ACR)
- Script: `azure/shared/build-push-acr.sh`
- Authentication: `az acr login`
- Image format: `<registry>.azurecr.io/<repo>:<tag>`

#### Google Container Registry / Artifact Registry
- Script: `gcp/shared/build-push-gcr.sh`
- Authentication: `gcloud auth configure-docker`
- Image format: `gcr.io/<project>/<repo>:<tag>` or `<region>-docker.pkg.dev/<project>/<repo>/<image>:<tag>`

### 6. Spark Setup

#### Azure
- **Options:**
  1. Azure Databricks (recommended for Spark workloads)
  2. HDInsight (managed Hadoop/Spark)
  3. AKS with Spark Operator (similar to EKS)
- Implementation: `common/spark/setup-spark-azure.sh`

#### GCP
- **Option:** Dataproc (managed Spark/Hadoop service)
- Implementation: `common/spark/setup-spark-gcp.sh`

### 7. Compute Services

#### Azure
- **Options:**
  1. Azure Container Instances (ACI) - serverless containers (similar to ECS Fargate)
  2. Azure Kubernetes Service (AKS) - managed Kubernetes (similar to EKS)
- Workflow structure similar to AWS (ecs-full → aci-full, eks-full → aks-full)

#### GCP
- **Options:**
  1. Cloud Run - serverless containers (similar to ECS Fargate)
  2. Google Kubernetes Engine (GKE) - managed Kubernetes (similar to EKS)
- Workflow structure similar to AWS

### 8. Frontend Deployment

#### Azure
- Azure Storage (static website hosting) + Azure CDN
- Script: `azure/shared/deploy-frontend.sh`
- Similar to AWS S3 + CloudFront pattern

#### GCP
- Cloud Storage (static website hosting) + Cloud CDN
- Script: `gcp/shared/deploy-frontend.sh`
- Similar to AWS S3 + CloudFront pattern

## Implementation Steps (When Adding Azure/GCP)

### Phase 1: Infrastructure Setup
1. Create provider directory structure (`infra/azure/`, `infra/gcp/`)
2. Create infrastructure modules (VPC/VNet, database, compute, secrets, frontend)
3. Create environment configurations (dev, prod)
4. Test infrastructure deployment

### Phase 2: Orchestration Scripts
1. Create provider directory in `run_scripts/` (`run_scripts/azure/`, `run_scripts/gcp/`)
2. Copy AWS scripts as templates
3. Replace AWS-specific logic with provider equivalents
4. Update credential handling
5. Create provider-specific scripts (build-push, deploy-frontend, etc.)

### Phase 3: Common Scripts
1. Add provider implementations to `common/database/`
2. Add provider implementations to `common/spark/`
3. Update wrapper scripts to route to new providers
4. Enhance verification scripts for new providers

### Phase 4: Integration
1. Update `common/check-dependencies.sh` for provider CLI tools (az, gcloud)
2. Update `common/load-env.sh` for provider environment variables
3. Update provider detection logic
4. Update documentation

### Phase 5: Testing & Documentation
1. Test end-to-end workflows
2. Document provider-specific requirements
3. Update README files
4. Create provider-specific guides

## Key Considerations

### Consistency
- Maintain same workflow structure across providers (prerequisites → setup → deploy → verify)
- Use similar step numbering and organization
- Keep conceptual steps consistent (database setup, Spark setup, etc.)

### Differences to Respect
- Cloud services have different APIs and behaviors
- IaC tools may differ (Terraform vs Bicep)
- Authentication methods differ (AWS profiles vs Azure Service Principals vs GCP Service Accounts)
- Network architectures differ (VPC vs VNet differences)

### DRY Principle
- Share common logic where possible (database operations, verification)
- Isolate provider differences in provider-specific implementations
- Use wrapper scripts to route to provider implementations
- Don't over-abstract - cloud services are inherently different

## Migration Strategy

When adding a new provider:
1. **Start with one provider** (e.g., Azure first, then GCP)
2. **Use AWS as template** - copy structure and adapt
3. **Test incrementally** - infrastructure first, then orchestration scripts
4. **Maintain backward compatibility** - AWS workflows should continue to work
5. **Document as you go** - provider-specific README files

## Notes

- This is a **future enhancement** - not part of current refactoring
- Current `infra/terraform/` structure works fine for AWS-only deployment
- Infrastructure reorganization (`infra/terraform/` → `infra/aws/terraform/`) should happen when adding Azure/GCP
- The refactored `run_scripts/` structure is already multi-cloud ready

