# Deployment Scripts Relationship: Terraform vs ECS

This document explains the relationship and differences between the two main AWS deployment scripts in this project.

## Overview

The project provides **two different deployment approaches** for AWS:

1. **`run_scripts/aws/terraform/deploy.sh`** - Full Infrastructure as Code (IaC) deployment
2. **`run_scripts/aws/ecs/deploy.sh`** - Partial deployment (container + frontend only)

---

## Script Comparison

### `run_scripts/aws/terraform/deploy.sh`

**Purpose:** Complete Infrastructure as Code deployment using Terraform/Terragrunt

**What it does:**
- ✅ **Infrastructure Layer** (Step 1):
  - Creates VPC with public/private subnets
  - Creates Aurora PostgreSQL cluster with pgvector
  - Creates IAM roles (execution + runtime)
  - Creates Secrets Manager secrets
  - Creates security groups
  - Sets up networking (NAT gateways, VPC endpoints)

- ✅ **Application Layer** (Step 2):
  - Creates ECS Fargate cluster
  - Creates ECS task definition
  - Creates ECS service
  - Creates Application Load Balancer (ALB)
  - Creates S3 bucket for frontend
  - Creates CloudFront distribution (optional)
  - Configures all security groups and IAM permissions

**What it requires:**
- Terraform >= 1.5.0
- Terragrunt >= 0.50.0
- `CONTAINER_IMAGE` environment variable (ECR image URI)
- All infrastructure resources are created automatically

**Usage:**
```bash
# Deploy everything
./run_scripts/aws/terraform/deploy.sh dev all

# Deploy only infrastructure
./run_scripts/aws/terraform/deploy.sh dev infrastructure

# Deploy only application
./run_scripts/aws/terraform/deploy.sh dev application
```

**When to use:**
- ✅ **Recommended for production** - Full automation, reproducible, version-controlled
- ✅ **First-time setup** - Creates everything from scratch
- ✅ **Infrastructure changes** - Modify infrastructure declaratively
- ✅ **Multi-environment** - Easy to deploy dev/prod with same code

---

### `run_scripts/aws/ecs/deploy.sh`

**Purpose:** Partial deployment - only handles container image and frontend

**What it does:**
- ✅ **Step 1:** Checks AWS credentials
- ✅ **Step 2:** Builds and pushes Docker image to ECR
- ✅ **Step 3:** Builds and deploys frontend to S3
- ⚠️ **Step 4:** **Reminds you** that infrastructure must be set up manually

**What it does NOT do:**
- ❌ Does NOT create VPC
- ❌ Does NOT create Aurora database
- ❌ Does NOT create ECS cluster
- ❌ Does NOT create ECS task definition
- ❌ Does NOT create ECS service
- ❌ Does NOT create ALB
- ❌ Does NOT create IAM roles
- ❌ Does NOT create security groups

**What it requires:**
- Infrastructure must already exist (created manually or via Terraform)
- AWS CLI configured
- Docker installed (for building image)

**Usage:**
```bash
# Full deployment (build + frontend)
./run_scripts/aws/ecs/deploy.sh

# Skip building container image
./run_scripts/aws/ecs/deploy.sh --skip-build

# Skip frontend deployment
./run_scripts/aws/ecs/deploy.sh --skip-frontend
```

**When to use:**
- ✅ **Quick container updates** - When you only need to update the application code
- ✅ **Frontend-only changes** - When you only changed the frontend
- ✅ **Existing infrastructure** - When infrastructure is already set up
- ⚠️ **Not recommended for first-time setup** - Use Terraform instead

---

## Relationship Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    Deployment Approaches                     │
└─────────────────────────────────────────────────────────────┘
                              │
                ┌─────────────┴─────────────┐
                │                           │
                ▼                           ▼
    ┌───────────────────────┐   ┌───────────────────────┐
    │  Terraform Approach    │   │   ECS Script Approach  │
    │  (Recommended)         │   │   (Partial)            │
    └───────────────────────┘   └───────────────────────┘
                │                           │
                │                           │
    ┌───────────┴───────────┐   ┌──────────┴──────────┐
    │                       │   │                      │
    ▼                       ▼   ▼                      ▼
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│Infrastructure│    │ Application │    │   Container │    │  Frontend  │
│   Layer     │───▶│    Layer    │    │   Image     │    │  (S3)     │
│             │    │             │    │   (ECR)     │    │           │
│ - VPC       │    │ - ECS       │    │             │    │           │
│ - Aurora    │    │ - ALB       │    │             │    │           │
│ - IAM       │    │ - Frontend  │    │             │    │           │
│ - Secrets   │    │ - CloudFront│    │             │    │           │
└─────────────┘    └─────────────┘    └─────────────┘    └───────────┘
    │                       │                │                  │
    │                       │                │                  │
    └───────────────────────┴────────────────┴──────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │  Running System │
                    └─────────────────┘
```

---

## Workflow Comparison

### Terraform Workflow (Complete)

```bash
# 1. Build and push container image
./run_scripts/aws/ecs/build-push-ecr.sh

# 2. Set CONTAINER_IMAGE in .env
export CONTAINER_IMAGE=<ecr-uri>

# 3. Deploy everything with Terraform
./run_scripts/aws/terraform/deploy.sh dev all

# Result: Complete infrastructure + application deployed
```

### ECS Script Workflow (Partial)

```bash
# 1. Infrastructure must exist (created manually or via Terraform)
#    - VPC, Aurora, ECS cluster, ALB, IAM roles, etc.

# 2. Deploy container and frontend
./run_scripts/aws/ecs/deploy.sh

# Result: Only container image and frontend updated
#         Infrastructure unchanged
```

---

## Key Differences

| Aspect | Terraform Script | ECS Script |
|--------|-----------------|-------------|
| **Scope** | Complete (infrastructure + application) | Partial (container + frontend only) |
| **Infrastructure Creation** | ✅ Automated | ❌ Manual or via Terraform |
| **Infrastructure Updates** | ✅ Declarative (via Terraform) | ❌ Manual (AWS Console/CLI) |
| **Reproducibility** | ✅ High (version-controlled) | ⚠️ Low (manual steps) |
| **First-Time Setup** | ✅ Recommended | ❌ Not suitable |
| **Container Updates** | ✅ Yes (via Terraform) | ✅ Yes (direct) |
| **Frontend Updates** | ✅ Yes (via Terraform) | ✅ Yes (direct) |
| **Dependencies** | Terraform + Terragrunt | AWS CLI + Docker |
| **State Management** | ✅ Terraform state | ❌ No state tracking |
| **Rollback** | ✅ Easy (terraform destroy/apply) | ⚠️ Manual |
| **Multi-Environment** | ✅ Easy (dev/prod configs) | ⚠️ Manual per environment |

---

## Recommended Usage Patterns

### Pattern 1: First-Time Setup (Recommended)

```bash
# Step 1: Build container image
./run_scripts/aws/ecs/build-push-ecr.sh

# Step 2: Set CONTAINER_IMAGE in .env
# Edit .env: CONTAINER_IMAGE=<ecr-uri>

# Step 3: Deploy everything with Terraform
./run_scripts/aws/terraform/deploy.sh dev all
```

**Result:** Complete system deployed from scratch

---

### Pattern 2: Application Code Updates (After Initial Setup)

**Option A: Using Terraform (Recommended)**
```bash
# 1. Build new container image
./run_scripts/aws/ecs/build-push-ecr.sh

# 2. Update CONTAINER_IMAGE in .env (if changed)

# 3. Update via Terraform (updates ECS service with new image)
./run_scripts/aws/terraform/deploy.sh dev application
```

**Option B: Using ECS Script (Faster, but limited)**
```bash
# 1. Build new container image
./run_scripts/aws/ecs/deploy.sh --skip-frontend

# 2. Manually update ECS service to use new image
aws ecs update-service --cluster <cluster> --service <service> --force-new-deployment
```

---

### Pattern 3: Frontend-Only Updates

**Option A: Using Terraform**
```bash
# 1. Build frontend
cd frontend && npm run build

# 2. Deploy via Terraform (updates S3 + CloudFront)
./run_scripts/aws/terraform/deploy.sh dev application
```

**Option B: Using ECS Script (Faster)**
```bash
# Deploy frontend only
./run_scripts/aws/ecs/deploy.sh --skip-build
```

---

## When to Use Which Script

### Use Terraform Script (`terraform/deploy.sh`) When:

- ✅ **First-time deployment** - Setting up everything from scratch
- ✅ **Infrastructure changes** - Need to modify VPC, Aurora, networking, etc.
- ✅ **Production deployments** - Need reproducibility and version control
- ✅ **Multi-environment** - Deploying to dev/prod with same code
- ✅ **Infrastructure updates** - Changing IAM roles, security groups, etc.
- ✅ **Disaster recovery** - Recreating entire environment

### Use ECS Script (`ecs/deploy.sh`) When:

- ✅ **Quick container updates** - Only application code changed
- ✅ **Frontend-only changes** - Only UI changed
- ✅ **Existing infrastructure** - Infrastructure already set up and stable
- ✅ **Rapid iteration** - Fast development cycle (container rebuilds)
- ⚠️ **Not for infrastructure changes** - Use Terraform for that

---

## Integration: Using Both Scripts Together

The scripts are **complementary**, not mutually exclusive:

```bash
# Initial Setup (Terraform)
./run_scripts/aws/terraform/deploy.sh dev all

# Later: Quick Application Updates (ECS Script)
./run_scripts/aws/ecs/deploy.sh

# Infrastructure Changes (Back to Terraform)
./run_scripts/aws/terraform/deploy.sh dev infrastructure
```

**Best Practice:**
- Use **Terraform** for infrastructure and initial setup
- Use **ECS script** for quick application/frontend updates
- Use **Terraform** again when infrastructure needs changes

---

## Summary

| Script | Purpose | Creates Infrastructure? | Creates Application? | Recommended For |
|--------|---------|----------------------|---------------------|-----------------|
| `terraform/deploy.sh` | Full IaC deployment | ✅ Yes | ✅ Yes | Production, first-time setup |
| `ecs/deploy.sh` | Container + frontend | ❌ No | ⚠️ Partial (reminds you) | Quick updates, existing infra |

**Key Takeaway:**
- **Terraform script** = Complete, automated, production-ready
- **ECS script** = Quick updates, assumes infrastructure exists
- **Use Terraform for setup**, **use ECS script for quick iterations**

---

## Related Files

- `run_scripts/aws/run.sh` - Main menu that calls both scripts
- `run_scripts/aws/ecs/build-push-ecr.sh` - Builds and pushes container (used by both)
- `run_scripts/aws/ecs/deploy-frontend.sh` - Deploys frontend (used by ECS script)
- `infra/terraform/` - Terraform modules and configurations

