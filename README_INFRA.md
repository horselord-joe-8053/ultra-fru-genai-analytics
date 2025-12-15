# 🏗️ Infrastructure as Code (IaC) for FRU

This document provides comprehensive documentation for deploying FRU infrastructure to AWS using Terraform and Terragrunt.

## 📋 Table of Contents

1. [📖 Overview](#-1-overview)
2. [💡 Why Terraform IaC? Necessity and Benefits](#-2-why-terraform-iac-necessity-and-benefits)
3. [📁 Structure](#-3-structure)
   - [3.1. Why `terragrunt.hcl` at Each Level?](#-31-why-terragrunthcl-at-each-level)
   - [3.2. Terraform Lock Files (`.terraform.lock.hcl`)](#-32-terraform-lock-files-terraformlockhcl)
4. [🔒 Security Best Practices](#-4-security-best-practices)
5. [✅ Prerequisites](#-5-prerequisites)
6. [🚀 Usage](#-6-usage)
7. [📚 Module Documentation](#-7-module-documentation)
8. [🌍 Environment-Specific Configuration](#-8-environment-specific-configuration)
9. [🎯 After Deployment](#-9-after-deployment)
10. [🐛 Troubleshooting](#-10-troubleshooting)
11. [🗑️ Destroying Infrastructure](#-11-destroying-infrastructure)
12. [🐳 Local Development (Docker)](#-12-local-development-docker)

---

## 📖 1. Overview

The `infra/` folder contains infrastructure code for FRU:

- **`docker/`**: Local development stack
  - `Dockerfile.api` — container for the Flask API
  - `docker-compose.yml` — local stack: Postgres with pgvector + API

- **`terraform/`**: Production infrastructure
  - **Complete Infrastructure as Code (IaC) implementation** using Terraform + Terragrunt
  - **Modular architecture**: 7 reusable modules (VPC, Aurora, IAM, Secrets Manager, ECS, ALB, Frontend)
  - **Environment management**: Terragrunt configurations for dev/prod with infrastructure/application layers
  - **Security best practices**: IAM role separation, Secrets Manager integration, IAM database authentication
  - **Production-ready**: Automated deployments, version-controlled infrastructure, disaster recovery support

---

# 💡 2. Why Terraform IaC? Necessity and Benefits

### The Problem: Manual Infrastructure Management

Without Infrastructure as Code (IaC), deploying FRU to AWS requires:
- **Manual AWS Console clicks** for 20+ resources (VPC, subnets, Aurora, ECS, ALB, IAM roles, security groups, etc.)
- **Inconsistent configurations** between dev/staging/prod environments
- **No version control** for infrastructure changes
- **Error-prone manual processes** leading to misconfigurations and security gaps
- **Difficult disaster recovery** - no automated way to recreate infrastructure
- **Time-consuming deployments** - hours or days to set up a new environment

### The Solution: Terraform + Terragrunt

This implementation provides:

#### 1. **Reproducibility & Consistency**
- **Same infrastructure, every time**: Deploy identical environments (dev/prod) with a single command
- **Version-controlled infrastructure**: All changes tracked in git, with rollback capability
- **Environment parity**: Dev matches prod architecture, reducing "works on my machine" issues

#### 2. **Security by Design**
- **Built-in security best practices**: IAM role separation, Secrets Manager integration, private subnets
- **No hardcoded credentials**: All secrets managed through AWS Secrets Manager
- **Least privilege IAM**: Separate execution and runtime roles with minimal permissions
- **Audit trail**: Every infrastructure change is logged and traceable

#### 3. **Speed & Efficiency**
- **Automated deployment**: Infrastructure provisioned in minutes, not hours
- **Idempotent operations**: Safe to run multiple times without side effects
- **Parallel resource creation**: Terraform creates independent resources concurrently
- **Quick environment spin-up**: New dev/staging environments in minutes

#### 4. **Cost Optimization**
- **Environment-specific sizing**: Dev uses smaller instances, prod uses production-grade resources
- **Easy cleanup**: Destroy entire environments when not needed
- **Resource tagging**: Automatic cost allocation and tracking

#### 5. **Maintainability & Scalability**
- **Modular architecture**: Reusable modules (VPC, Aurora, ECS) across projects
- **Terragrunt DRY principle**: Shared configuration, environment-specific overrides
- **Easy updates**: Change one module, apply to all environments
- **Team collaboration**: Multiple engineers can work on infrastructure safely

#### 6. **Disaster Recovery**
- **Infrastructure as code**: Recreate entire environment from git repository
- **State management**: Track resource relationships and dependencies
- **Backup and restore**: Infrastructure can be recreated from state files

#### 7. **Production Readiness**
- **Enterprise-grade practices**: IaC, security, and DevOps best practices
- **Production-ready**: Same code used for dev and prod, with appropriate configurations
- **Documentation**: Self-documenting infrastructure through code

### Real-World Impact

**Before Terraform IaC:**
- Manual setup: 4-8 hours per environment
- Configuration drift between environments
- Security misconfigurations common
- Difficult to scale or replicate

**After Terraform IaC:**
- Automated setup: 15-30 minutes per environment
- Identical configurations across environments
- Security best practices enforced
- Easy to scale, replicate, and maintain

---

# 📁 3. Structure

```
infra/
├── docker/                    # Local development
│   ├── Dockerfile.api
│   └── docker-compose.yml
└── terraform/                 # Production infrastructure
    ├── modules/               # Reusable Terraform modules
    │   ├── vpc/               # VPC, subnets, NAT gateways, VPC endpoints
    │   ├── aurora/            # Aurora PostgreSQL cluster with pgvector
    │   ├── iam/               # IAM roles (execution + runtime)
    │   ├── secrets-manager/   # Secrets Manager for sensitive data
    │   ├── ecs/               # ECS cluster, service, task definition
    │   ├── eks/               # EKS cluster, node groups, OIDC provider
    │   ├── alb/               # Application Load Balancer
    │   ├── frontend/           # S3 + CloudFront for frontend
    │   ├── infrastructure/    # Wrapper module (VPC + Aurora + IAM + Secrets)
    │   └── application/       # Wrapper module (ECS + ALB + Frontend)
    └── environments/          # Terragrunt environment configurations
        ├── root.hcl           # Root configuration (Level 1)
        ├── dev/
        │   ├── env.hcl        # Environment config (Level 2)
        │   ├── infrastructure/
        │   │   └── terragrunt.hcl  # Infrastructure layer (Level 3)
        │   ├── application/
        │   │   └── terragrunt.hcl   # Application layer (Level 3) - ECS
        │   └── eks/
        │       └── terragrunt.hcl   # EKS layer (Level 3) - EKS
        └── prod/
            ├── env.hcl        # Environment config (Level 2)
            ├── infrastructure/
            │   └── terragrunt.hcl  # Infrastructure layer (Level 3)
            ├── application/
            │   └── terragrunt.hcl   # Application layer (Level 3) - ECS
            └── eks/
                └── terragrunt.hcl   # EKS layer (Level 3) - EKS
```

### 3.1. Why `terragrunt.hcl` at Each Level?

**Important:** All Terragrunt configuration files at Level 3 (infrastructure and application layers) must be named `terragrunt.hcl`. This is a **Terragrunt requirement**, not just a convention.

#### The Problem with Custom Names

If we used custom names like `infra.hcl` or `appl.hcl`:
- ✅ Terragrunt can find the config in the **current directory** using `--terragrunt-config` flag
- ❌ Terragrunt **cannot** find configs in **dependency directories** (no flag support)
- ❌ When `application/terragrunt.hcl` references `../infrastructure`, Terragrunt looks for `../infrastructure/terragrunt.hcl`
- ❌ If the file is named `infra.hcl`, Terragrunt fails with: "You attempted to run terragrunt in a folder that does not contain a terragrunt.hcl file"

#### Why This Matters

Our `application/terragrunt.hcl` has a dependency block:
```hcl
dependency "infrastructure" {
  config_path = "../infrastructure"  # Terragrunt looks for terragrunt.hcl here
  ...
}
```

When Terragrunt processes this:
1. It reads `application/terragrunt.hcl` ✅
2. It sees the dependency pointing to `../infrastructure`
3. It **automatically** looks for `../infrastructure/terragrunt.hcl` (no flag can override this)
4. If the file is named anything else, Terragrunt fails ❌

#### The Solution

**Use `terragrunt.hcl` at Level 3:**
- ✅ Terragrunt finds it automatically in the current directory
- ✅ Terragrunt finds it automatically in dependency directories
- ✅ No need for `--terragrunt-config` flags
- ✅ Works with all Terragrunt features (dependencies, includes, etc.)

#### File Naming Summary

| Level | File Name | Reason |
|-------|-----------|--------|
| Level 1 | `root.hcl` | Custom name OK - no dependencies reference it |
| Level 2 | `env.hcl` | Custom name OK - included explicitly via path |
| Level 3 | `terragrunt.hcl` | **Must be `terragrunt.hcl`** - required for dependency resolution |

**Key Takeaway:** Level 3 files (`infrastructure/` and `application/`) must use `terragrunt.hcl` because Terragrunt's dependency resolution mechanism requires it. Level 1 and Level 2 files can use custom names because they're referenced explicitly via `include` blocks with explicit paths.

### 3.2. Terraform Lock Files (`.terraform.lock.hcl`)

**Purpose:** Lock files ensure consistent provider versions across all environments and team members, preventing "works on my machine" issues.

**What They Do:**
- **Lock exact provider versions**: Records the specific version used (e.g., AWS provider `5.100.0`)
- **Store security checksums**: Verifies provider integrity during download
- **Override version constraints**: When a lock file exists, Terraform uses the locked version instead of resolving from constraints

**Where They're Located:**
```
infra/terraform/environments/
├── dev/
│   ├── infrastructure/.terraform.lock.hcl  ✅ Committed
│   ├── application/.terraform.lock.hcl     ✅ Committed
│   └── eks/.terraform.lock.hcl            ✅ Committed (if EKS is used)
└── prod/
    ├── infrastructure/.terraform.lock.hcl  ✅ Committed
    ├── application/.terraform.lock.hcl      ✅ Committed
    └── eks/.terraform.lock.hcl              ✅ Committed (if EKS is used)
```

**Why They Must Be Committed:**
- ✅ **Team consistency**: Everyone uses the same provider versions
- ✅ **Reproducibility**: Same infrastructure behavior across dev/prod
- ✅ **Security**: Checksums prevent tampering/corruption
- ✅ **Stability**: Prevents unexpected breaking changes from provider updates

**Current Configuration:**
- **Provider constraint**: `~> 5.0` (in `root.hcl`) - allows any 5.x version
- **Locked version**: `5.100.0` - exact version used across all environments
- **Auto-upgrade prevention**: The constraint prevents automatic upgrades to 6.x

**Important Notes:**
- ❌ **Do NOT** run `terraform init` directly in module directories (`infra/terraform/modules/*`)
- ✅ Lock files are automatically generated when running `terragrunt init` or `terragrunt apply`
- ✅ Lock files in cache directories (`temp_terra_gen/.terragrunt-cache/`) are temporary and should not be committed
- ✅ Only commit lock files next to `terragrunt.hcl` files in environment directories

**Updating Provider Versions:**
To upgrade providers (e.g., from 5.x to 6.x):
1. Update the constraint in `root.hcl`: `version = "~> 6.0"`
2. Run `terraform init -upgrade` in each environment directory
3. Test thoroughly in dev environment first
4. Commit the updated lock files

### 3.3. Why EKS Has Its Own Layer (Separate from Application Layer)

**Question**: Why does EKS have its own `eks/` folder, while ECS is part of the `application/` layer?

**Answer**: ECS and EKS use fundamentally different orchestration and load balancing approaches, requiring separate infrastructure layers.

#### ECS: Direct ALB Integration (AWS-Native)

- **Terraform-managed ALB**: The `application/` layer includes an ALB module that creates AWS resources directly via Terraform (`aws_lb`, `aws_lb_target_group`)
- **Direct connection**: ECS Service explicitly connects to the ALB Target Group via a `load_balancer` block in Terraform
- **Static configuration**: ALB configuration is fixed at Terraform apply time
- **Bundled together**: ECS, ALB, and Frontend are tightly coupled in the application layer

**Flow**: `Internet → ALB (Terraform) → Target Group (Terraform) → ECS Tasks`

#### EKS: ALB via Kubernetes Controller

- **Controller-managed ALB**: EKS uses AWS Load Balancer Controller (a Kubernetes pod) that watches for `Ingress` resources
- **Dynamic creation**: ALB and Target Group are created **at runtime** by the controller based on Kubernetes Ingress annotations
- **Kubernetes-native**: Uses Kubernetes `Ingress` and `Service` resources, not Terraform-managed ALB
- **Different lifecycle**: ALB is managed by Kubernetes, not Terraform

**Flow**: `Internet → ALB (Controller-created) → Kubernetes Service → Pods`

#### Why They Can't Share the Same Layer

1. **Different ALB Management**:
   - ECS: Terraform creates and manages ALB
   - EKS: Kubernetes controller creates and manages ALB
   - They would conflict if both tried to manage the same ALB

2. **Different Target Types**:
   - ECS: Target Group uses `target_type = "ip"` (Fargate IPs)
   - EKS: Target Group targets Kubernetes Service endpoints
   - Different health checks, security groups, configurations

3. **Different Deployment Models**:
   - ECS: Task definitions, ALB target groups (Terraform)
   - EKS: Kubernetes manifests, Ingress resources (`kubectl apply`)

4. **Independent Lifecycles**:
   - EKS cluster creation takes 10-15 minutes (deserves its own layer)
   - ECS and EKS are alternatives (choose one or the other, or both)

#### Structure Comparison

```
ECS Deployment:
  infrastructure/  → VPC, Aurora, IAM, Secrets (SHARED)
  application/     → ECS, ALB, Frontend (ECS-specific)

EKS Deployment:
  infrastructure/  → VPC, Aurora, IAM, Secrets (SHARED)
  eks/            → EKS Cluster, Node Groups, OIDC (EKS-specific)
  (Kubernetes manifests deployed separately via kubectl)
```

**Key Insight**: ECS doesn't have its own folder because it's bundled with ALB and Frontend in the application layer. EKS needs its own layer because it uses a different orchestration platform with different networking requirements.

---

# 🔒 4. Security Best Practices

### IAM Role Separation

- **Execution Role**: Used by ECS service to start tasks
  - ECR: Pull container images
  - CloudWatch: Write logs
  - Secrets Manager: Read secrets for task definition

- **Runtime Role**: Assumed by running containers
  - Bedrock: Invoke models
  - Secrets Manager: Read secrets at runtime
  - RDS IAM Auth: Connect to Aurora (if enabled)

### Secrets Management

- **Never store secrets in environment variables**
- All sensitive data (OPENAI_API_KEY, PGPASSWORD) stored in Secrets Manager
- Secrets referenced in ECS task definition via `secrets` block
- Only non-sensitive values (PGHOST, PGPORT, PGDATABASE) as environment variables

### Database Authentication

- **IAM Database Authentication** (recommended for production)
  - No passwords needed
  - ECS tasks authenticate using IAM roles
  - More secure than password-based auth

- **Secrets Manager** (fallback)
  - Store password in Secrets Manager
  - Reference in ECS task definition
  - Rotate regularly

---

# ✅ 5. Prerequisites

1. **Terraform** >= 1.5.0
   ```bash
   brew install terraform
   ```

2. **Terragrunt** >= 0.50.0
   ```bash
   brew install terragrunt
   ```

3. **AWS CLI** configured
   ```bash
   aws configure
   ```

4. **AWS Credentials Setup**
   - **Two profiles required**: `admin` (infrastructure) and `bedrock` (application runtime)
   - **Why both?** Separation of concerns: infrastructure scripts need admin permissions (ECR, S3, Terraform), while application code only needs Bedrock access (least privilege)
   - **Setup**: Add `AWS_ADMIN_*` and `AWS_BEDROCK_*` credentials to `.env`, then run `./run_scripts/aws/setup-aws-profiles.sh`
   - **Note**: Scripts automatically use `admin` profile; application uses `bedrock` profile (or `admin` for local Docker)

5. **S3 Bucket for Terraform State**
   - **Automated**: The deployment scripts automatically create the S3 bucket if it doesn't exist
   - **Manual** (optional): Create an S3 bucket for storing Terraform state
   - Set environment variable in `.env`:
     ```bash
     TF_STATE_BUCKET="fru-terraform-state-<account-id>"
     ```
   - The `setup-s3-bucket.sh` script handles bucket creation, versioning, encryption, and public access blocking automatically

---

# 🚀 6. Usage

### Quick Start (Using Scripts)

**Recommended: Complete workflows**
```bash
# Complete ECS deployment (build image → setup infra → deploy app)
./run_scripts/aws/run.sh ecs-full dev

# Complete EKS deployment (build image → setup infra → deploy app)
./run_scripts/aws/run.sh eks-full dev

# Infrastructure only (no application)
./run_scripts/aws/run.sh infrastructure dev
```

**Legacy: Direct Terraform control**
```bash
# Deploy to dev environment
./run_scripts/aws/terraform/deploy.sh dev all

# Deploy only infrastructure layer
./run_scripts/aws/terraform/deploy.sh dev infrastructure

# Deploy only application layer
./run_scripts/aws/terraform/deploy.sh dev application

# Deploy only EKS layer
./run_scripts/aws/terraform/deploy.sh dev eks
```

> **Note:** All workflows automatically:
> - Set up S3 bucket for Terraform state (if needed)
> - Verify deployment and show access URLs
> - Provide usage instructions

### Manual Deployment

1. **Set Environment Variables**

   ```bash
   export AWS_REGION="us-east-1"
   export ENVIRONMENT="dev"
   export OPENAI_API_KEY="sk-..."
   export DB_PASSWORD="SecurePassword123!"
   export CONTAINER_IMAGE="123456789012.dkr.ecr.us-east-1.amazonaws.com/fru-api:latest"
   ```

2. **Deploy Infrastructure Layer**

   ```bash
   cd infra/terraform/environments/dev/infrastructure
   terragrunt plan
   terragrunt apply
   ```

3. **Deploy Application Layer (ECS)**

   ```bash
   cd infra/terraform/environments/dev/application
   terragrunt plan
   terragrunt apply
   ```

   **OR Deploy EKS Layer**

   ```bash
   cd infra/terraform/environments/dev/eks
   terragrunt plan
   terragrunt apply
   
   # After EKS cluster is created, configure kubectl
   aws eks update-kubeconfig --region us-east-1 --name fru-dev-cluster --profile admin
   ```

> **Note:** The Terragrunt configuration files use standard naming:
> - `root.hcl` - Root configuration (Level 1)
> - `env.hcl` - Environment-specific config (Level 2)
> - `terragrunt.hcl` - Layer-specific config (Level 3) - used in both infrastructure and application directories

### View Outputs

```bash
cd infra/terraform/environments/dev/infrastructure
terragrunt output

cd ../application
terragrunt output
```

---

# 📚 7. Module Documentation

Each module has its own README.md with:
- Purpose and features
- Usage examples
- Input variables
- Outputs
- Security considerations

See individual module directories in `infra/terraform/modules/` for details.

---

# 🌍 8. Environment-Specific Configuration

### Dev Environment

- Smaller instance sizes
- Single AZ (cost savings)
- No deletion protection
- IAM auth optional

### Prod Environment

- Larger instance sizes
- Multi-AZ (high availability)
- Deletion protection enabled
- IAM auth enabled
- Enhanced monitoring

---

# 🎯 9. After Deployment

1. **Enable pgvector Extension**

   Connect to Aurora and run:
   ```sql
   CREATE EXTENSION IF NOT EXISTS vector;
   ```

2. **Apply Database Schema**

   ```sql
   \i sql/schema_pgvector.sql
   ```

3. **Set Up IAM Database User** (if using IAM auth)

   ```sql
   CREATE USER fru_app_user;
   GRANT rds_iam TO fru_app_user;
   GRANT ALL ON DATABASE fru_db TO fru_app_user;
   ```

4. **Run ETL Script**

   ```bash
   export PGHOST=<aurora-endpoint>
   export PGPORT=5432
   export PGUSER=fru_user
   export PGPASSWORD=<password>  # Or use IAM auth
   export PGDATABASE=fru_db
   export FRU_CSV_PATH=data/raw/fridge_sales_with_rating.csv

   python backend/etl/load_openai_embeddings_to_pgvector.py
   ```

5. **Deploy Frontend**

   ```bash
   cd frontend
   npm run build
   aws s3 sync dist/ s3://$(terragrunt output -raw s3_bucket_id)/
   aws cloudfront create-invalidation \
     --distribution-id $(terragrunt output -raw cloudfront_distribution_id) \
     --paths "/*"
   ```

---

# 🐛 10. Troubleshooting

### State Lock Issues

If Terraform state is locked:
```bash
aws dynamodb delete-item \
  --table-name fru-terraform-locks \
  --key '{"LockID":{"S":"<lock-id>"}}'
```

### Module Not Found

Ensure you're running Terragrunt from the correct directory:
```bash
cd infra/terraform/environments/dev/infrastructure
terragrunt plan
```

### Secrets Not Found

Ensure secrets are created in Secrets Manager before deploying application layer:
```bash
cd infra/terraform/environments/dev/infrastructure
terragrunt apply
```

---

# 🗑️ 11. Destroying Infrastructure

**Recommended: Use automated teardown script**
```bash
# Destroy all resources (interactive confirmation)
./run_scripts/aws/terraform/teardown.sh dev all

# Destroy only application layer
./run_scripts/aws/terraform/teardown.sh dev application

# Destroy only infrastructure layer
./run_scripts/aws/terraform/teardown.sh dev infrastructure
```

**Manual: Using Terragrunt directly**
```bash
cd infra/terraform/environments/dev/application
terragrunt destroy

cd ../infrastructure
terragrunt destroy
```

**Warning**: This will delete all resources. Ensure you have backups!

> **Note:** The teardown script is idempotent and handles dependencies correctly (destroys application layer before infrastructure layer).

---

# 🐳 12. Local Development (Docker)

For local development, use the Docker setup:

```bash
cd infra/docker
docker compose --env-file ../../.env up -d
```

This provides:
- Postgres + pgvector on `localhost:5432`
- Flask API on `localhost:5000`

See `README_RUN.md` for detailed local setup instructions.

