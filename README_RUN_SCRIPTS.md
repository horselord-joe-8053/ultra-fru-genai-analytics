# 🚀 FRU Run Scripts - Quick Start Guide

This directory contains **idempotent shell scripts** to automate setup and deployment for all FRU project scenarios. Each scenario has a **single top-level orchestrator script** that handles everything.

## 📋 Table of Contents

1. [🎯 Quick Start](#-1-quick-start)
2. [📁 Script Structure](#-2-script-structure)
3. [🧪 Local Development](#-3-local-development)
4. [☁️ AWS Deployment](#-4-aws-deployment)
6. [🛠️ Common Utilities](#-6-common-utilities)
7. [🔧 Script Features](#-7-script-features)
8. [🐛 Troubleshooting](#-8-troubleshooting)

---

# 🎯 1. Quick Start

### Local Development (Recommended for coding)

```bash
# One command to set up and start everything
./run_scripts/local/run.sh
```

This will:
- ✅ Check prerequisites (Python, Node.js, Docker)
- ✅ Create `.env` file from template
- ✅ Set up Python virtual environment
- ✅ Install all dependencies
- ✅ Start Docker services (Postgres + API)
- ✅ Initialize database schema
- ✅ Load CSV data
- ✅ Start frontend dev server
- ✅ Verify deployment and show usage instructions

**That's it!** Open `http://localhost:5173` and start coding.

### AWS Deployment

```bash
# Default: Complete ECS deployment (ecs-full)
./run_scripts/aws/run.sh

# Complete workflows (recommended):
./run_scripts/aws/run.sh ecs-full        # Complete ECS deployment
./run_scripts/aws/run.sh eks-full        # Complete EKS deployment
./run_scripts/aws/run.sh infrastructure  # Infrastructure only

# Legacy workflows (for quick updates):
./run_scripts/aws/run.sh ecs             # ECS-specific steps only
./run_scripts/aws/run.sh eks             # EKS-specific steps only
./run_scripts/aws/run.sh terraform       # Terraform manual control
```

**All workflows automatically verify deployment and provide usage instructions.**

---

# 📁 2. Script Structure

```
run_scripts/
├── README_RUN_SCRIPTS.md          # This file
│
├── common/                        # Shared utilities
│   ├── logger.sh                  # Colored logging
│   ├── load-env.sh                # Load .env file
│   ├── check-dependencies.sh      # Check prerequisites
│   └── wait-for-service.sh        # Wait for services
│
├── local/                         # Local development
│   ├── run.sh                     # 🎯 MAIN ORCHESTRATOR
│   ├── post_run_verify.sh         # Post-deployment verification
│   ├── setup-env.sh               # Create .env file
│   ├── setup-python.sh            # Python venv + deps
│   ├── setup-frontend.sh          # npm install
│   ├── start-services.sh          # Docker compose up
│   ├── init-db.sh                 # Database schema
│   ├── load-data.sh               # ETL script
│   ├── start-frontend.sh          # Start Vite dev server
│   └── stop-services.sh           # Stop Docker services
│
└── aws/                           # AWS deployments
    ├── run.sh                     # 🎯 MAIN ORCHESTRATOR
    ├── post_run_verify.sh         # Post-deployment verification
    ├── check-aws-credentials.sh   # Verify AWS setup
    │
    ├── bedrock/                   # Bedrock model access
    │   └── enable-model-access.sh # Enable/verify model access
    │
    ├── common_ecs_eks/            # Shared ECS/EKS scripts
    │   ├── build-push-ecr.sh      # Build & push to ECR
    │   └── deploy-frontend.sh     # Deploy to S3
    │
    ├── ecs/                       # ECS Fargate deployment
    │   └── deploy.sh              # ECS-specific deployment
    │
    ├── eks/                       # Kubernetes deployment
    │   └── deploy.sh              # EKS-specific deployment
    │
    └── terraform/                 # Infrastructure as Code
        ├── deploy.sh              # Deploy infrastructure/app
        ├── setup-s3-bucket.sh    # Setup Terraform state bucket
        └── teardown.sh            # Destroy infrastructure
```

---

# 🧪 3. Local Development

### Full Setup (One Command)

```bash
./run_scripts/local/run.sh
```

### Individual Steps (if needed)

```bash
# 1. Check prerequisites
./run_scripts/common/check-dependencies.sh

# 2. Setup .env file
./run_scripts/local/setup-env.sh

# 3. Setup Python environment
./run_scripts/local/setup-python.sh

# 4. Setup frontend dependencies
./run_scripts/local/setup-frontend.sh

# 5. Start Docker services
./run_scripts/local/start-services.sh

# 6. Initialize database
./run_scripts/local/init-db.sh

# 7. Load data
./run_scripts/local/load-data.sh

# 8. Start frontend (in separate terminal)
./run_scripts/local/start-frontend.sh
```

### Options

```bash
# Skip frontend startup (useful if running in separate terminal)
./run_scripts/local/run.sh --skip-frontend

# Skip data loading (if data already loaded)
./run_scripts/local/run.sh --skip-data-load
```

### Stopping Services

```bash
./run_scripts/local/stop-services.sh
```

---

# ☁️ 4. AWS Deployment

### Prerequisites

1. **AWS Account** with appropriate permissions
2. **AWS CLI** installed and configured
3. **AWS Credentials** configured (see below)
4. **Bedrock Access** enabled for Claude 3 model

### AWS Credentials Setup

You can provide AWS credentials in **three ways** (in order of preference):

1. **IAM Role** (Production - Recommended)
   - No credentials needed
   - ECS/EKS tasks use IAM roles
   - Most secure

2. **Environment Variables** (Local Development)
   ```bash
   # Add to .env file
   AWS_ACCESS_KEY_ID=your-access-key
   AWS_SECRET_ACCESS_KEY=your-secret-key
   AWS_REGION=us-east-1
   ```

3. **AWS Credentials File** (Standard)
   ```bash
   aws configure
   # Or edit ~/.aws/credentials
   ```

### ECS Fargate Deployment

**Recommended: Complete workflow (ecs-full)**
```bash
# Complete ECS deployment (build image → setup infra → deploy app)
./run_scripts/aws/run.sh ecs-full dev
```

**What it does:**
- ✅ Checks AWS credentials
- ✅ Builds and pushes Docker image to ECR (idempotent)
- ✅ Sets up S3 bucket for Terraform state (if needed)
- ✅ Deploys infrastructure (VPC, Aurora, IAM, Secrets Manager)
- ✅ Deploys application (ECS, ALB, Frontend)
- ✅ Verifies deployment and shows access URLs

**Legacy: ECS-specific steps only**
```bash
# ECS-specific steps (for quick updates after infrastructure exists)
./run_scripts/aws/run.sh ecs

# Or directly:
./run_scripts/aws/ecs/deploy.sh
```

**What it does:**
- ✅ Builds and pushes Docker image to ECR
- ✅ Builds and deploys frontend to S3
- ⚠️ Assumes infrastructure already exists (use `ecs-full` for first-time setup)

### EKS (Kubernetes) Deployment

**Recommended: Complete workflow (eks-full)**
```bash
# Complete EKS deployment (build image → setup infra → deploy EKS → deploy app)
./run_scripts/aws/run.sh eks-full dev
```

**What it does:**
- ✅ Checks AWS credentials
- ✅ Builds and pushes Docker image to ECR (idempotent)
- ✅ Sets up S3 bucket for Terraform state (if needed)
- ✅ Deploys infrastructure (VPC, Aurora, IAM, Secrets Manager)
- ✅ Deploys EKS layer (EKS cluster, node groups/Fargate profiles, OIDC provider)
- ✅ Configures kubectl automatically
- ✅ Generates Kubernetes ConfigMap and Secret from `.env`
- ✅ Applies Kubernetes manifests (Deployment, Service, Ingress)
- ✅ Verifies deployment and shows access URLs

**Prerequisites:**
- `kubectl` installed (will be configured automatically)
- Kubernetes manifests in `infra/k8s/`
- EKS cluster is created automatically via Terraform (no manual `eksctl` needed)

**Legacy: EKS-specific steps only**
```bash
# EKS-specific steps (for quick updates after infrastructure exists)
./run_scripts/aws/run.sh eks

# Or directly:
./run_scripts/aws/eks/deploy.sh
```

### Terraform Infrastructure

**Recommended: Use via run.sh workflows**
```bash
# Infrastructure only (no application)
./run_scripts/aws/run.sh infrastructure dev

# Or use Terraform directly:
./run_scripts/aws/terraform/deploy.sh dev all
```

**What it does:**
- ✅ Automatically sets up S3 bucket for Terraform state (if needed)
- ✅ Initializes Terraform
- ✅ Shows plan of changes
- ✅ Applies infrastructure layer (VPC, Aurora, IAM, Secrets Manager)
- ✅ Applies application layer (ECS, ALB, Frontend) - for ECS deployments
- ✅ Applies EKS layer (EKS cluster, node groups, OIDC provider) - for EKS deployments

**Available layers:**
- `infrastructure` - VPC, Aurora, IAM, Secrets Manager
- `application` - ECS, ALB, Frontend (ECS-specific)
- `eks` - EKS cluster, node groups, OIDC provider (EKS-specific)
- `all` - Deploy all layers (infrastructure + application OR infrastructure + eks)

**Terraform Teardown:**
```bash
# Destroy all resources (interactive confirmation)
./run_scripts/aws/terraform/teardown.sh dev all

# Destroy specific layer
./run_scripts/aws/terraform/teardown.sh dev infrastructure
./run_scripts/aws/terraform/teardown.sh dev application  # ECS-specific
./run_scripts/aws/terraform/teardown.sh dev eks        # EKS-specific
```

**Note:** 
- Terraform state bucket is automatically created by `setup-s3-bucket.sh` if it doesn't exist
- EKS and ECS deployments share the same infrastructure layer (VPC, Aurora, IAM, Secrets)
- EKS has its own layer (`eks/`) separate from the application layer (`application/`) because they use different orchestration platforms (see `README_INFRA.md` Section 3.3 for details)

---

# 🛠️ 5. Common Utilities

### Logger (`common/logger.sh`)

Provides colored logging functions:
- `log_info "message"` - Blue info messages
- `log_success "message"` - Green success messages
- `log_warning "message"` - Yellow warnings
- `log_error "message"` - Red error messages
- `log_step "message"` - Green step headers

### Load Environment (`common/load-env.sh`)

Loads `.env` file and exports all variables:
```bash
source common/load-env.sh
```

### Check Dependencies (`common/check-dependencies.sh`)

Checks if required tools are installed:
- Python 3.10+
- Node.js 18+
- Docker
- Optional: psql, spark-submit, aws, terraform

### Wait for Service (`common/wait-for-service.sh`)

Waits for a service to be ready:
```bash
wait_for_service "http://localhost:5000/health" 30 2
```

---

# 🔧 6. Script Features

All scripts are:

- ✅ **Idempotent** - Safe to run multiple times
- ✅ **Well-commented** - Clear explanations of each step
- ✅ **Error-handled** - Proper error messages and exit codes
- ✅ **Colored output** - Easy to read success/error messages
- ✅ **Prerequisite checks** - Validates dependencies before running
- ✅ **Auto-verification** - Post-deployment verification scripts check service health
- ✅ **Usage instructions** - Clear guidance on how to access and test deployments

---

# 🐛 7. Troubleshooting

### "Command not found" errors

**Solution:** Install missing dependencies
```bash
# Check what's missing
./run_scripts/common/check-dependencies.sh

# Install on macOS
brew install python3 node docker postgresql@16 awscli terraform
```

### ".env file not found"

**Solution:** Run setup script
```bash
./run_scripts/local/setup-env.sh
```

### "Docker is not running"

**Solution:** Start Docker Desktop
```bash
# macOS: Open Docker Desktop application
# Then verify:
docker info
```

### "AWS credentials not configured"

**Solution:** Configure AWS credentials
```bash
# Option 1: Add to .env file
AWS_ACCESS_KEY_ID=your-key
AWS_SECRET_ACCESS_KEY=your-secret

# Option 2: Use AWS CLI
aws configure

# Option 3: Verify credentials
aws sts get-caller-identity
```

### "Port already in use"

**Solution:** Stop the service using the port
```bash
# Find process using port 5000
lsof -i :5000

# Kill the process
kill -9 <PID>
```

### "Database connection failed"

**Solution:** Ensure Docker services are running
```bash
# Check Docker services
docker ps

# Restart services
./run_scripts/local/stop-services.sh
./run_scripts/local/start-services.sh
```

### "Python package import errors"

**Solution:** Reinstall dependencies
```bash
# Activate venv
source venv/bin/activate

# Reinstall
pip install -r requirements.txt
```

---

## 📝 Environment Variables

### Required (Local Development)

```bash
# Database
PGHOST=localhost
PGPORT=5432
PGUSER=postgres
PGPASSWORD=postgres
PGDATABASE=fru_db

# OpenAI
OPENAI_API_KEY=sk-...

# AWS (for Bedrock)
AWS_REGION=us-east-1
BEDROCK_MODEL_ID=anthropic.claude-3-haiku-20240229-v1:0
```

### Optional

```bash
# AWS Credentials (for local development)
# If not set, boto3 uses ~/.aws/credentials or IAM role
AWS_ACCESS_KEY_ID=your-access-key
AWS_SECRET_ACCESS_KEY=your-secret-key

# Analytics Scheduler
ENABLE_ANALYTICS_SCHEDULER=true
ANALYTICS_SCHEDULER_INTERVAL_MINUTES=5
SPARK_HOME=/path/to/spark
DELTA_TABLE_PATH=data/delta/fru_sales
```

---

## 🎓 Best Practices

1. **Always use the orchestrator scripts** (`run.sh`) for full setup
2. **Check prerequisites first** before running scripts
3. **Review `.env` file** after creation and fill in required values
4. **Use `--skip-*` flags** to avoid re-running completed steps
5. **Check logs** if something fails (Docker logs, script output)
6. **Keep `.env` out of git** (already in `.gitignore`)

---

## 🚀 Quick Reference

| Scenario | Command |
|----------|---------|
| **Local Dev Setup** | `./run_scripts/local/run.sh` |
| **AWS ECS Full** | `./run_scripts/aws/run.sh ecs-full dev` |
| **AWS EKS Full** | `./run_scripts/aws/run.sh eks-full dev` |
| **AWS Infrastructure** | `./run_scripts/aws/run.sh infrastructure dev` |
| **AWS ECS (legacy)** | `./run_scripts/aws/run.sh ecs` |
| **AWS EKS (legacy)** | `./run_scripts/aws/run.sh eks` |
| **Stop Services** | `./run_scripts/local/stop-services.sh` |
| **Check Dependencies** | `./run_scripts/common/check-dependencies.sh` |

---

## 📚 Additional Resources

- **Main README**: `README.md` - Project overview
- **Run Guide**: `README_RUN.md` - Detailed manual setup instructions
- **Architecture**: See README.md Section 6 (pgvector) and Section 10 (Query Processing)

---

## 🤝 Contributing

When adding new scripts:

1. Make scripts **idempotent** (safe to run multiple times)
2. Use **common utilities** (`logger.sh`, `load-env.sh`, etc.)
3. Add **clear comments** explaining each step
4. Include **error handling** with helpful messages
5. Update this **README** with new scripts

---

**Happy coding! 🎉**

