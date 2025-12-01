# Analysis: Idempotent Run Scripts for FRU Project

## Executive Summary

**Yes, we can create idempotent shell scripts** for most deployment scenarios. However, some AWS infrastructure steps require either:
- Complete Terraform implementation (recommended)
- Manual AWS Console setup (for quick demos)
- Hybrid approach (scripts + Terraform)

---

## 1. Local Environment Setup (Section 2) - ✅ FULLY AUTOMATABLE

### What Can Be Automated:

**Prerequisites Check & Install:**
- ✅ Check Python 3.10+ → Install via Homebrew if missing
- ✅ Check Node.js 18+ → Install via Homebrew if missing
- ✅ Check Docker → Install Docker Desktop if missing
- ✅ Check `psql` → Install PostgreSQL client if missing
- ✅ Check `spark-submit` → Install Spark if missing (optional)
- ✅ Check `aws` CLI → Install if missing (optional)

**Environment Setup:**
- ✅ Create `.env` file from template (idempotent - check if exists, prompt for values)
- ✅ Create Python virtual environment (idempotent - check if exists)
- ✅ Install Python dependencies (idempotent - pip install -r requirements.txt)
- ✅ Install Node.js dependencies (idempotent - npm install)

**Service Startup:**
- ✅ Start Docker containers (idempotent - docker compose up -d)
- ✅ Wait for database health check
- ✅ Initialize database schema (idempotent - check if tables exist)
- ✅ Run ETL if data not loaded (idempotent - check row count)
- ✅ Start backend API (idempotent - check if port 5000 in use)
- ✅ Start frontend dev server (idempotent - check if port 5173 in use)

**Idempotency Strategy:**
- Check for existence before creating
- Use `IF NOT EXISTS` in SQL
- Check service status before starting
- Skip steps if already completed

---

## 2. Local "Prod Simulation" (Section 3) - ✅ FULLY AUTOMATABLE

**Similar to Section 2, but:**
- Build Docker images instead of using dev mode
- Use `docker compose up --build`
- Serve frontend from built `dist/` folder

**Idempotency:**
- Check if images exist before building
- Use Docker layer caching
- Check if services are running before starting

---

## 3. AWS ECS Fargate Deployment (Section 4) - ⚠️ PARTIALLY AUTOMATABLE

### Fully Automatable Steps:

**4.2 Build & Push to ECR:**
- ✅ Check if ECR repo exists → Create if not
- ✅ Build Docker image (idempotent - use tags/versions)
- ✅ Login to ECR
- ✅ Tag and push image (idempotent - check if tag exists)

**4.4 Frontend Deployment:**
- ✅ Build frontend (idempotent)
- ✅ Check if S3 bucket exists → Create if not
- ✅ Sync files to S3 (idempotent - only uploads changed files)
- ✅ Configure S3 static website hosting
- ⚠️ CloudFront distribution (can be automated but complex)

**ETL Against Aurora:**
- ✅ Run ETL script with Aurora connection (idempotent - check row count)

### Requires Manual Setup or Terraform:

**4.1 Aurora PostgreSQL:**
- ⚠️ Create Aurora cluster (can use AWS CLI but complex)
- ⚠️ Enable pgvector extension (can be automated via SQL)
- ⚠️ Apply schema (can be automated via psql)
- ⚠️ **Recommendation:** Use Terraform or AWS CLI script

**4.3 ECS Fargate Service:**
- ⚠️ Create VPC and subnets (complex, better with Terraform)
- ⚠️ Create ECS cluster (can use AWS CLI)
- ⚠️ Create task definition (can use AWS CLI, but JSON is complex)
- ⚠️ Create ECS service (can use AWS CLI)
- ⚠️ Create ALB/API Gateway (complex, better with Terraform)
- ⚠️ Configure security groups (can use AWS CLI)
- ⚠️ Create IAM roles (can use AWS CLI)

**4.5 VPC Endpoint:**
- ⚠️ Create VPC endpoint for Bedrock (can use AWS CLI)

**Recommendation:**
- **Option A:** Complete Terraform implementation (best for production)
- **Option B:** Hybrid - Scripts for ECR/ECS/S3, Terraform for infrastructure
- **Option C:** Manual setup for infrastructure, scripts for deployment

---

## 4. EKS Deployment (Section 5) - ⚠️ PARTIALLY AUTOMATABLE

### Fully Automatable:

**Kubernetes Manifests:**
- ✅ Apply Deployment YAML (idempotent - kubectl apply)
- ✅ Apply Service YAML (idempotent - kubectl apply)
- ✅ Apply Ingress YAML (idempotent - kubectl apply)
- ✅ Create/update Kubernetes secrets (idempotent)

**Image Management:**
- ✅ Same ECR push as Section 4.2

### Requires Setup:

**EKS Cluster:**
- ⚠️ Create EKS cluster (can use `eksctl` or Terraform)
- ⚠️ Configure kubectl context
- ⚠️ Install ALB Ingress Controller (can be automated)
- ⚠️ Aurora setup (same as Section 4.1)

**Recommendation:**
- Use `eksctl` for cluster creation (simpler than raw AWS CLI)
- Use scripts for applying manifests
- Use Terraform for infrastructure (VPC, Aurora)

---

## 5. Terraform IaC (Section 6) - ✅ FULLY AUTOMATABLE (if implemented)

**If Terraform files are complete:**
- ✅ `terraform init` (idempotent)
- ✅ `terraform plan` (idempotent - shows changes)
- ✅ `terraform apply` (idempotent - only creates if not exists)
- ✅ `terraform destroy` (cleanup)

**Current Status:**
- ⚠️ Terraform files are skeleton only (main.tf has basic S3 and RDS)
- ⚠️ Need to complete: VPC, ECS, ALB, CloudFront, IAM roles

**Recommendation:**
- Complete Terraform implementation for full automation
- Or use scripts to call Terraform modules

---

## Proposed Script Structure

```
run_scripts/
├── README_RUN_SCRIPTS.md          # Main documentation
│
├── local/
│   ├── setup.sh                   # One-command local setup
│   ├── check-prerequisites.sh     # Check/install prerequisites
│   ├── setup-env.sh               # Create .env file
│   ├── setup-python.sh            # Python venv + dependencies
│   ├── setup-frontend.sh          # npm install
│   ├── start-services.sh          # Docker compose + services
│   ├── init-db.sh                 # Schema initialization
│   ├── load-data.sh               # ETL script execution
│   ├── start-backend.sh           # Start Flask API
│   ├── start-frontend.sh          # Start Vite dev server
│   └── stop-services.sh           # Stop all services
│
├── local-prod/
│   ├── deploy.sh                  # Full local prod simulation
│   ├── build-images.sh            # Build Docker images
│   └── serve-frontend.sh          # Serve built frontend
│
├── aws/
│   ├── ecs/
│   │   ├── deploy.sh              # Full ECS deployment
│   │   ├── setup-infra.sh         # Aurora + VPC (or calls Terraform)
│   │   ├── build-push-ecr.sh       # Build and push to ECR
│   │   ├── deploy-ecs.sh          # Create/update ECS service
│   │   ├── deploy-frontend.sh     # S3 + CloudFront
│   │   └── run-etl-aurora.sh      # ETL against Aurora
│   │
│   ├── eks/
│   │   ├── deploy.sh              # Full EKS deployment
│   │   ├── setup-cluster.sh       # Create EKS cluster (eksctl)
│   │   ├── deploy-backend.sh      # Apply K8s manifests
│   │   └── deploy-frontend.sh     # Frontend deployment
│   │
│   └── terraform/
│       ├── deploy.sh              # Terraform apply
│       ├── destroy.sh             # Terraform destroy
│       └── outputs.sh             # Get Terraform outputs
│
└── common/
    ├── load-env.sh                # Load .env file
    ├── check-dependencies.sh      # Check tool availability
    ├── wait-for-service.sh         # Wait for service to be ready
    └── logger.sh                  # Logging utilities
```

---

## Idempotency Patterns

### 1. Check Before Create
```bash
if [ ! -f ".env" ]; then
    # Create .env from template
fi

if ! docker ps | grep -q fru_db; then
    # Start container
fi
```

### 2. Use Idempotent Commands
```bash
# SQL: CREATE TABLE IF NOT EXISTS
# Docker: docker compose up -d (idempotent)
# kubectl: kubectl apply (idempotent)
# AWS: aws ecr describe-repositories (check) then create if needed
```

### 3. State Tracking
```bash
# Check if database is initialized
psql ... -c "SELECT COUNT(*) FROM fru_sales_embeddings" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    # Run ETL
fi
```

### 4. Version/Tag Management
```bash
# Use timestamps or git commits for Docker tags
IMAGE_TAG=$(git rev-parse --short HEAD)
# Check if tag exists in ECR before pushing
```

---

## Dependencies & Execution Order

### Local Setup Flow:
```
1. check-prerequisites.sh
2. setup-env.sh
3. setup-python.sh
4. setup-frontend.sh
5. start-services.sh (Docker)
6. wait-for-service.sh (DB health)
7. init-db.sh
8. load-data.sh
9. start-backend.sh (optional, if not using Docker)
10. start-frontend.sh
```

### AWS ECS Flow:
```
1. setup-infra.sh (or terraform apply)
   - VPC, Aurora, Security Groups
2. init-aurora.sh (schema + pgvector)
3. build-push-ecr.sh
4. deploy-ecs.sh
   - ECS cluster, task definition, service
5. deploy-frontend.sh
   - S3 bucket, CloudFront
6. run-etl-aurora.sh
```

---

## Challenges & Solutions

### Challenge 1: AWS Infrastructure Complexity
**Problem:** VPC, Aurora, ECS, ALB setup is complex
**Solution:**
- **Option A:** Complete Terraform (recommended)
- **Option B:** Use AWS CDK (TypeScript/Python)
- **Option C:** Scripts call AWS CLI with error handling

### Challenge 2: Secrets Management
**Problem:** Passwords, API keys shouldn't be in scripts
**Solution:**
- Use `.env` file (local)
- Use AWS Secrets Manager (production)
- Scripts read from environment or prompt interactively

### Challenge 3: State Management
**Problem:** Need to track what's already deployed
**Solution:**
- Use AWS resource tags
- Check resource existence before creating
- Use Terraform state (if using Terraform)

### Challenge 4: Cross-Platform (macOS focus)
**Problem:** Scripts need to work on macOS
**Solution:**
- Use Homebrew for package management
- Use standard Unix tools (bash, grep, awk)
- Test on macOS specifically

---

## Recommended Approach

### For Local Development:
✅ **Fully automated** - One script: `./run_scripts/local/setup.sh`

### For AWS Deployments:
**Hybrid Approach:**
1. **Infrastructure (VPC, Aurora, ECS cluster):** Use Terraform
2. **Application Deployment (ECR, ECS service, S3):** Use scripts
3. **Orchestration:** Master script calls Terraform + deployment scripts

**Why Hybrid?**
- Terraform is better for infrastructure (state management, dependencies)
- Scripts are simpler for application deployment (Docker, ECR, S3 sync)
- Easier to maintain and understand

---

## Script Features

### All Scripts Should:
1. ✅ Be idempotent (safe to run multiple times)
2. ✅ Have clear error messages
3. ✅ Check prerequisites before running
4. ✅ Support `--dry-run` mode (show what would happen)
5. ✅ Support `--verbose` mode (detailed output)
6. ✅ Log operations to file
7. ✅ Use colors for success/error messages
8. ✅ Exit with proper error codes

### Example Script Structure:
```bash
#!/bin/bash
set -e  # Exit on error
set -u  # Exit on undefined variable

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"
source "$SCRIPT_DIR/../common/load-env.sh"

# Configuration
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Functions
check_prerequisites() { ... }
setup_environment() { ... }
main() { ... }

# Run
main "$@"
```

---

## What CANNOT Be Fully Automated

1. **AWS Account Setup:**
   - Bedrock model access enablement (requires AWS Console)
   - IAM permissions (can be automated but complex)

2. **Domain/SSL:**
   - Domain registration
   - SSL certificate (can use ACM but needs domain)

3. **Initial Secrets:**
   - OpenAI API key (user must provide)
   - AWS credentials (user must configure)

4. **Network Configuration:**
   - VPC peering (if needed)
   - Cross-region setup

---

## Estimated Script Count

- **Local scripts:** ~10 scripts
- **AWS ECS scripts:** ~6 scripts
- **AWS EKS scripts:** ~4 scripts
- **Terraform scripts:** ~3 scripts
- **Common utilities:** ~4 scripts

**Total: ~27 scripts** (well-organized in hierarchy)

---

## Benefits of This Approach

1. ✅ **One-command setup** for local development
2. ✅ **Consistent deployments** across environments
3. ✅ **Easy onboarding** for new developers
4. ✅ **Reproducible** deployments
5. ✅ **Error handling** and validation
6. ✅ **Clear documentation** of what each step does
7. ✅ **Idempotent** - safe to re-run

---

## Conclusion

**Yes, we can create comprehensive idempotent scripts** for:
- ✅ Local setup (100% automatable)
- ✅ Local prod simulation (100% automatable)
- ⚠️ AWS deployments (80% automatable, 20% needs Terraform or manual setup)
- ⚠️ EKS deployments (70% automatable, 30% needs cluster setup)
- ✅ Terraform (100% automatable if implemented)

**Recommendation:** Create scripts with clear separation:
- Infrastructure → Terraform (or manual for quick demos)
- Application deployment → Scripts
- Orchestration → Master scripts that coordinate everything

This gives users **maximum flexibility** while maintaining **ease of use**.

