# Infrastructure as Code (IaC) for FRU

This document provides comprehensive documentation for deploying FRU infrastructure to AWS using Terraform and Terragrunt.

## Overview

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

## Why Terraform IaC? Necessity and Benefits

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

## Structure

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
    │   ├── alb/               # Application Load Balancer
    │   ├── frontend/           # S3 + CloudFront for frontend
    │   ├── infrastructure/    # Wrapper module (VPC + Aurora + IAM + Secrets)
    │   └── application/       # Wrapper module (ECS + ALB + Frontend)
    └── environments/          # Terragrunt environment configurations
        ├── terragrunt.hcl     # Root configuration
        ├── dev/
        │   ├── terragrunt.hcl
        │   ├── infrastructure/
        │   └── application/
        └── prod/
            ├── terragrunt.hcl
            ├── infrastructure/
            └── application/
```

---

## Security Best Practices

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

## Prerequisites

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

4. **S3 Bucket for Terraform State**
   - Create an S3 bucket for storing Terraform state
   - Create a DynamoDB table for state locking
   - Set environment variables:
     ```bash
     export TF_STATE_BUCKET="fru-terraform-state-<account-id>"
     export TF_STATE_LOCK_TABLE="fru-terraform-locks"
     ```

---

## Usage

### Quick Start (Using Scripts)

```bash
# Deploy to dev environment
./run_scripts/aws/terraform/deploy.sh dev all

# Deploy only infrastructure layer
./run_scripts/aws/terraform/deploy.sh dev infrastructure

# Deploy only application layer
./run_scripts/aws/terraform/deploy.sh prod application
```

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

3. **Deploy Application Layer**

   ```bash
   cd infra/terraform/environments/dev/application
   terragrunt plan
   terragrunt apply
   ```

### View Outputs

```bash
cd infra/terraform/environments/dev/infrastructure
terragrunt output

cd ../application
terragrunt output
```

---

## Module Documentation

Each module has its own README.md with:
- Purpose and features
- Usage examples
- Input variables
- Outputs
- Security considerations

See individual module directories in `infra/terraform/modules/` for details.

---

## Environment-Specific Configuration

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

## After Deployment

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

## Troubleshooting

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

## Destroying Infrastructure

```bash
cd infra/terraform/environments/dev/application
terragrunt destroy

cd ../infrastructure
terragrunt destroy
```

**Warning**: This will delete all resources. Ensure you have backups!

---

## Local Development (Docker)

For local development, use the Docker setup:

```bash
cd infra/docker
docker compose --env-file ../../.env up -d
```

This provides:
- Postgres + pgvector on `localhost:5432`
- Flask API on `localhost:5000`

See `README_RUN.md` for detailed local setup instructions.

