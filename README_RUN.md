# 🚀 FRU - Quick Start Guide

This guide provides quick instructions for running FRU locally and on AWS.

## 📋 Table of Contents

1. [🎯 1. Quick Start](#-1-quick-start)
   - [1.1 Set Up Environment Variables](#-11-set-up-environment-variables)
   - [1.2 Local Development](#-12-local-development)
   - [1.3 AWS Deployment](#-13-aws-deployment)
2. [🔧 2. Prerequisites](#-2-prerequisites)
   - [2.1 Automatic Installation](#-21-automatic-installation)
   - [2.2 Manual Installation](#-22-manual-installation)
3. [🖥️ 3. Frontend Overview](#-3-frontend-overview)
4. [📚 4. Additional Resources](#-4-additional-resources)

---

# 🎯 1. Quick Start

## 1.1 Set Up Environment Variables

Create a `.env` file at the repository root with your actual credentials and configuration values.

**Copy from template:**
```bash
cp .env.example .env
```

**Required values to fill in:**

1. **Database credentials:**
```bash
   PGPASSWORD=your-database-password
   DB_PASSWORD=your-database-password
   ```

2. **OpenAI API Key:**
```bash
   OPENAI_API_KEY=sk-your-openai-api-key-here
   ```

3. **Claude API Key:**
   ```bash
   CLAUDE_API_KEY=sk-ant-api03-your-claude-api-key-here
   ```

4. **AWS Credentials** (for AWS deployments and Bedrock):
   ```bash
   AWS_ADMIN_ACCESS_KEY_ID=your-admin-access-key-id
   AWS_ADMIN_SECRET_ACCESS_KEY=your-admin-secret-access-key
   AWS_BEDROCK_ACCESS_KEY_ID=your-bedrock-access-key-id
   AWS_BEDROCK_SECRET_ACCESS_KEY=your-bedrock-secret-access-key
   ```

5. **Terraform State Bucket** (for AWS deployments):
   ```bash
   TF_STATE_BUCKET=fru-terraform-state-your-account-id
   ```

> **Note:** After creating `.env`, run `./run_scripts/main_application_scripts/aws/setup-aws-profiles.sh` to sync AWS credentials to `~/.aws/credentials` profiles.

> **Security:** The `.env` file is already in `.gitignore`. Never commit actual credentials to the repository.

---

## 1.2 Local Development

**One-command setup:**
```bash
./run_scripts/main_application_scripts/local/run.sh
```

This script will:
- ✅ **Check and install prerequisites** (Python 3.10+, Node.js 18+, Docker) - automatic installation on macOS/Ubuntu
- ✅ Create `.env` file from template (if missing)
- ✅ Set up Python virtual environment
- ✅ Install Python dependencies from `requirements.txt`
- ✅ Install frontend dependencies (React, Vite, etc.)
- ✅ Start Docker services (Postgres + API)
- ✅ Initialize database schema
- ✅ Load CSV data
- ✅ Start frontend dev server
- ✅ Verify deployment

**Clean rebuild (remove all resources and recreate):**
```bash
./run_scripts/main_application_scripts/local/run.sh --preempt
```

The `--preempt` flag will:
- 🗑️ Stop and remove all Docker containers
- 🗑️ Remove Docker volumes (including database data)
- 🗑️ Remove Docker images
- 🗑️ Clean Docker build cache
- ✅ Recreate everything from scratch

**After setup:**
- Frontend: `http://localhost:5173`
- API: `http://localhost:5000`
- Database: `localhost:5432`

---

## 1.3 AWS Deployment

### Complete ECS Deployment

**Initial deployment:**
```bash
./run_scripts/main_application_scripts/aws/run.sh ecs-full dev
```

The `ecs-full` workflow performs a complete ECS deployment:

1. **Phase 0: Pre-flight checks**
   - Verify AWS credentials
   - Check prerequisites (Terraform, AWS CLI, Docker)

2. **Phase 1: Build and push Docker image**
   - Build Docker image for the API
   - Push to Amazon ECR (Elastic Container Registry)
   - Image is tagged and versioned for deployment

3. **Phase 2: Setup Terraform state bucket**
   - Create S3 bucket for Terraform state storage (if needed)
   - Configure state locking with DynamoDB

4. **Phase 3: Deploy infrastructure layer**
   - VPC with public and private subnets
   - Aurora PostgreSQL cluster with pgvector extension
   - IAM roles (execution and runtime roles)
   - AWS Secrets Manager for sensitive credentials
   - Security groups and networking

5. **Phase 4: Deploy application layer**
   - ECS Fargate cluster and service
   - Application Load Balancer (ALB)
   - Frontend (S3 + CloudFront distribution)

6. **Phase 5: Post-deployment verification**
   - Verify services are running
   - Test endpoints
   - Display access URLs (API, Frontend)

**Clean rebuild (remove all AWS resources and recreate):**
```bash
./run_scripts/main_application_scripts/aws/run.sh ecs-full dev --preempt
```

The `--preempt` flag performs a complete cleanup before deployment:

1. **Teardown existing resources:**
   - Stop all running ECS tasks
   - Destroy ECS service and cluster
   - Destroy Application Load Balancer (ALB)
   - Delete CloudFront distribution
   - Delete S3 buckets (frontend and Terraform state)
   - Destroy Aurora PostgreSQL cluster
   - Remove VPC, subnets, security groups
   - Clean up IAM roles and policies
   - Remove Secrets Manager secrets

2. **Clean local resources:**
   - Remove local Docker images related to the project
   - Clean Docker build cache

3. **Recreate everything:**
   - Run the full deployment workflow from scratch
   - All resources are freshly created with new configurations

> **Warning:** The `--preempt` flag destroys all resources. This is useful for:
> - Starting fresh on a new machine
> - Testing complete infrastructure recreation
> - Cleaning up after testing

### Other Workflows

**Infrastructure only (no application):**
```bash
./run_scripts/main_application_scripts/aws/run.sh infrastructure dev
```

**EKS deployment (Kubernetes):**
```bash
./run_scripts/main_application_scripts/aws/run.sh eks-full dev
```

**EKS with clean rebuild:**
```bash
./run_scripts/main_application_scripts/aws/run.sh eks-full dev --preempt
```

---

# 🔧 2. Prerequisites

## 2.1 Automatic Installation

The `run.sh` scripts **automatically check and install** missing prerequisites when you run them. No manual setup required!

**Supported Operating Systems:**
- ✅ **macOS** (via Homebrew)
- ✅ **Ubuntu/Debian** (via apt or official installers)

**Installation Behavior:**
- **Interactive mode** (terminal): Prompts for confirmation before installing
- **Non-interactive mode** (CI/CD): Automatically installs without prompts

**Local Development Prerequisites:**
- **Python 3.10+** (installs 3.11 if missing)
- **Node.js 18+ LTS** (installs LTS version if missing)
- **Docker** (guides to Docker Desktop on macOS, apt install on Ubuntu)

**AWS Deployment Prerequisites:**
- **Python 3.10+** (required for Terraform scripts)
- **AWS CLI 2.x** (installs latest 2.x version if missing)
- **Terraform >= 1.5.0** (installs via Homebrew/apt if missing)
- **Terragrunt >= 0.50.0** (installs via Homebrew/GitHub releases if missing)
- **Docker** (required for building container images)

**Version Validation:**
- Scripts verify minimum versions are met
- Warns if installed version is too old (doesn't auto-upgrade)
- Provides clear error messages if installation fails

## 2.2 Manual Installation

If you prefer to install prerequisites manually or need custom versions:

**macOS:**
```bash
# Install Homebrew (if not already installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install prerequisites
brew install python@3.11
brew install node@18
brew install terraform terragrunt awscli

# Install Docker Desktop from: https://www.docker.com/products/docker-desktop
```

**Ubuntu:**
```bash
# Update package list
sudo apt-get update

# Install Python 3.11 (via deadsnakes PPA)
sudo apt-get install -y software-properties-common
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt-get install -y python3.11 python3.11-venv python3.11-pip

# Install Node.js 18 LTS (via NodeSource)
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs

# Install Terraform (via Hashicorp repository)
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform

# Install Terragrunt (manual download)
# See: https://github.com/gruntwork-io/terragrunt/releases

# Install AWS CLI 2.x (official installer)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Install Docker
sudo apt-get install -y ca-certificates curl gnupg lsb-release
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

**Note:** The automatic installation system uses the same methods as above but handles everything for you.

---

# 🖥️ 3. Frontend Overview

The FRU frontend displays **3 vertical panels** (left, middle, right) that occupy the full vertical space, providing different views of the analytics system:

## Panel 1: Chat Interface (Left)

Interactive conversational interface for querying the fridge sales data.

**Features:**
- Natural language query input
- Chat history with user questions and AI responses
- Real-time query processing
- Grounded answers based on actual sales data

**Example queries:**
- "Why are Samsung customers unhappy?"
- "Which store has the most negative feedback?"
- "How many LG fridges did we sell last month?"

## Panel 2: Execution Log (Middle)

Shows **real-time execution details** for the current query, including agent-based query processing steps.

**Features:**
- Displays query processing method (semantic search, SQL generation, etc.)
- Shows tool calls and iterations (for agent-based queries)
- Execution time and token usage metrics
- Real-time streaming updates during query processing
- Error messages if query processing fails
- Detailed view of each tool's input and output

**Data Source:** Server-Sent Events (SSE) stream from the Flask API showing step-by-step query execution.

## Panel 3: Batch Analytics (Right)

Displays **offline batch analytics** results from Spark + Delta Lake processing.

**Features:**
- Auto-refreshes at interval specified by `VITE_FRONTEND_POLL_FREQUENCY_IN_SEC` environment variable (configured in `.env`, default: 60 seconds)
- Shows "Last Updated At" timestamp
- Displays aggregate statistics:

  **Sales Summary by Brand:**
  - Total sales count per brand
  - Total revenue per brand
  - Average, minimum, and maximum prices per brand

  **Store Performance Metrics:**
  - Sales volume per store
  - Total revenue per store
  - Average sale price per store
  - Negative and positive feedback counts
  - Negative feedback rate percentage

  **Feedback Analysis by Brand:**
  - Total feedback count per brand
  - Positive vs negative feedback distribution

  **Top Models by Sales Volume:**
  - Best-selling fridge models
  - Sales count per model
  - Total revenue per model
  - Average price per model

  **Price Distribution Statistics:**
  - Mean, minimum, and maximum prices across all products

**Data Source:** Spark batch analytics jobs that process the Delta table and store results in PostgreSQL `batch_analytics` table. 

**Configuration:**
- **Enable analytics scheduler**: Set `ENABLE_ANALYTICS_SCHEDULER=true` in `.env` (default: false)
- **Batch analytics interval**: Configured via `ANALYTICS_SCHEDULER_INTERVAL_SECONDS` in `.env` (default: 300 seconds, i.e., 5 minutes)
- **Frontend refresh interval**: Configured via `VITE_FRONTEND_POLL_FREQUENCY_IN_SEC` in `.env` (default: 60 seconds)

This panel shows pre-computed aggregations that are updated at the interval specified by `ANALYTICS_SCHEDULER_INTERVAL_SECONDS`. The frontend automatically refreshes to fetch the latest results at the interval specified by `VITE_FRONTEND_POLL_FREQUENCY_IN_SEC`.

---

## Architecture Overview

```
User Query (Chat Interface - Left Panel)
    ↓
Flask API
    ├─→ Query Processing → Execution Log Panel (Middle)
    │   └─→ Tool calls, iterations, execution details
    │
    └─→ Bedrock Claude → Narrative Answer → Chat Interface

Spark + Delta (Offline)
    ↓
PostgreSQL batch_analytics table
    ↓
Batch Analytics Panel (Right Panel - Auto-refresh via VITE_FRONTEND_POLL_FREQUENCY_IN_SEC)
```

**Key Separation:**
- **Chat Interface (Left)**: Interactive queries → AI-generated answers
- **Execution Log Panel (Middle)**: Real-time processing → Query execution details, tool calls, and performance metrics
- **Batch Analytics Panel (Right)**: Offline processing (Spark + Delta) → Pre-computed aggregated statistics

---

# 📚 4. Additional Resources

**Main Documentation:**
- **[`README.md`](README.md)** - Project overview and architecture
- **[`README_INFRA.md`](README_INFRA.md)** - Infrastructure as Code (Terraform + Terragrunt) documentation

**Additional Guides** (in `guides/` directory):
- `guides/DELTA_SPARK_VS_POSTGRESQL_FULL_STACK.md` - Detailed comparison and architecture guide
- `guides/MANUAL_DEPLOYMENT_AND_TESTING.md` - Manual deployment procedures (obsolete - see `guides/bk/`)
- `guides/PERFORMANCE_BREAKDOWN.md` - Performance analysis and optimization
- `guides/aws_setup_guide.md` - AWS setup and configuration
- `guides/database_setup_explanation.md` - Database setup and schema explanation
- `guides/deployment_scripts_relationship.md` - Deployment scripts relationships

**Obsolete Documentation** (in `guides/bk/` directory):
- `guides/bk/README_RUN.md` - Original detailed runbook (superseded by this guide)
- `guides/bk/README_RUN_SCRIPTS.md` - Original scripts documentation (superseded by this guide)

---

**Happy coding! 🎉**

