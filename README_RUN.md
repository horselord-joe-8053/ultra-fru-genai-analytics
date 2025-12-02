# 📘 FRU – How to Run (Local, AWS, EKS, Terraform)  
**GenAI Analytics – How to Run (Local, AWS, EKS, Terraform)**

## 📚 Documentation Overview

**This guide (`README_RUN.md`)** provides detailed manual instructions for running FRU in various environments.

**For automated setup scripts**, see **[`README_RUN_SCRIPTS.md`](README_RUN_SCRIPTS.md)** - it contains idempotent shell scripts that automate the entire setup process with a single command per scenario (local dev, local prod, AWS deployments).

**For Infrastructure as Code**, see **[`infra/terraform/README.md`](../infra/terraform/README.md)** - complete Terraform + Terragrunt implementation with modular architecture, environment management (dev/prod), and security best practices (IAM role separation, Secrets Manager, IAM database authentication).

---

FRU (**Friday aRe Us**) is a GenAI analytics assistant over fridge sales data, built with:

- OpenAI **embeddings** (text-embedding-3-small)
- Postgres + **pgvector** (semantic store)
- AWS **Bedrock** (Claude 3) for narrative answers
- Flask API backend
- React + Vite + Tailwind frontend
- Spark + Delta Lake for offline analytics
- Target production: **ECS Fargate + Aurora PostgreSQL + Bedrock**  
  (plus optional **EKS** and **Terraform** paths)

## 🚀 Quick Start (Automated Scripts)

**For the fastest setup, use our automated scripts:**

- **Local Development**: `./run_scripts/local/run.sh` - One command to set up everything
- **Local Production**: `./run_scripts/local-prod/run.sh` - Docker-based production simulation
- **AWS Deployment**: `./run_scripts/aws/run.sh` - Interactive menu for AWS deployments

📖 **See `README_RUN_SCRIPTS.md` for complete script documentation.**

---

This guide explains **how to run** FRU manually in:

1. Local Developer Mode (best for coding)
2. Local "Production Simulation" (Docker-only)
3. AWS ECS Fargate + Aurora + Bedrock (primary prod path)
4. Kubernetes / EKS deployment (optional path)
5. Terraform-based IaC (optional path)

---

## 🧩 0. Prerequisites

### Local
- Python 3.10+
- Node.js 18+
- Docker Desktop (or compatible)
- **PostgreSQL client tools** (for `psql` command)
  - macOS: `brew install postgresql@16` or `brew install libpq`
  - Linux: `sudo apt-get install postgresql-client`
  - Windows: Install PostgreSQL from https://www.postgresql.org/download/windows/ or use Docker exec alternative (see Section 2.3)
- **Apache Spark** (optional, for Spark jobs in Section 2.5)
  - Download from https://spark.apache.org/downloads.html
  - Or use Databricks / EMR for cloud execution
- OpenAI API key
- AWS credentials configured (for Bedrock)
- **AWS CLI** (optional, for AWS deployment sections)
  - macOS: `brew install awscli`
  - Linux: `sudo apt-get install awscli` or `pip install awscli`
  - Windows: https://aws.amazon.com/cli/

### AWS (prod)
- AWS Account with:
  - Bedrock access to **Claude 3** in chosen region
  - Permissions for ECS, ECR, Aurora PostgreSQL, S3, CloudWatch, IAM, VPC

---

## 🧠 1. Architecture Overview (High Level)

Textual architecture:

```text
User (Web UI)
    |
    v
Frontend (React + Vite)
    |
    v          OpenAI: embeddings
Flask API  ------------------------>  embedding vectors
    |
    | PGHOST/pgvector
    v
Postgres + pgvector
    |
    | rows + stats JSON
    v
AWS Bedrock (Claude 3)
    |
    v
Grounded narrative answer
```

- **Spark + Delta** are used offline to:
  - ingest CSV into Delta tables
  - generate NLQ→SQL training pairs
  - run heavier analytics
- Online path uses:
  - OpenAI embeddings for semantic search
  - pgvector for ANN search
  - Claude for narrative explanation

---

# 🧪 2. Local Developer Mode (Option A – Recommended)

This is what you use for day-to-day hacking and interview prep.

### 2.1 Set up environment

At repo root, create `.env`:

**Option A: Use automated script (recommended)**
```bash
./run_scripts/local/setup-env.sh
```
This will create `.env` from `.env.example` template.

**Option B: Manual creation**

Copy from `.env.example`:
```bash
cp .env.example .env
```

Or create manually with:

```bash
# Database Configuration
PGHOST=localhost
PGPORT=5432
PGUSER=postgres
PGPASSWORD=postgres
PGDATABASE=fru_db

# OpenAI Configuration
OPENAI_API_KEY=sk-...

# AWS Configuration
AWS_REGION=us-east-1
BEDROCK_MODEL_ID=anthropic.claude-3-haiku-20240229-v1:0

# Optional: AWS Credentials (for local development only)
# If not set, boto3 will use ~/.aws/credentials or IAM role
# AWS_ACCESS_KEY_ID=your-access-key
# AWS_SECRET_ACCESS_KEY=your-secret-key
# AWS_SESSION_TOKEN=...  # If using temporary credentials

# Optional: Data Paths
# FRU_CSV_PATH=data/raw/fridge_sales_with_rating.csv

# Optional: Analytics Scheduler (requires Spark + Delta table)
# ENABLE_ANALYTICS_SCHEDULER=true
# ANALYTICS_SCHEDULER_INTERVAL_MINUTES=5
# SPARK_HOME=/path/to/spark  # Optional, if spark-submit not in PATH
# DELTA_TABLE_PATH=data/delta/fru_sales
```

**Important:** Fill in:
- `OPENAI_API_KEY` (required)
- `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (optional for local dev - can use `~/.aws/credentials` instead)
- Other optional settings as needed

> Tip: keep `.env` out of git (already in `.gitignore`). For production, use IAM roles instead of credentials.

---

### 2.2 Install Python Dependencies

Before running any Python scripts, install the required packages:

Create a virtual environment (recommended):

```bash
python3 -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate
```

Install required packages:

```bash
pip install -r requirements.txt
```

Verify installation:

```bash
python -c "import flask, psycopg2, openai, boto3, pandas; print('✓ All dependencies installed')"
```

> **Note:** This step is required before running ETL scripts (Section 2.3) or the API locally.

---

### 2.3 Run Postgres + pgvector + API with Docker

From repo root:

```bash
cd infra/docker
docker compose --env-file ../../.env up -d
```

This starts:

- `fru_db` (Postgres + pgvector)
- `fru_api` (Flask API, port 5000)

Check:

```bash
curl http://localhost:5000/health
```

You should see a small JSON `{ "status": "ok" }`.

> **Note:** The API includes an optional analytics scheduler that runs Spark batch analytics every 5 minutes. To enable it, set `ENABLE_ANALYTICS_SCHEDULER=true` in your `.env` file. The scheduler requires Spark to be installed and the Delta table to exist (see Section 2.6).

---

### 2.4 Load CSV into the database

You should have `data/raw/fridge_sales_with_rating.csv` and:

- a schema / init script (for example `docs/sql/schema_pgvector.sql`)
- an ETL script like `backend/etl/load_openai_embeddings_to_pgvector.py`

1. Initialize schema (includes `batch_analytics` table for Spark analytics):

   Option A (if psql installed locally):
   ```bash
   psql "postgresql://postgres:postgres@localhost:5432/fru_db" -f docs/sql/schema_pgvector.sql
   ```

   Option B (using Docker, if psql not installed):
   ```bash
   docker exec -i fru_db psql -U postgres -d fru_db < docs/sql/schema_pgvector.sql
   ```

   This creates:
   - `fru_sales_embeddings` table (for pgvector semantic search)
   - `batch_analytics` table (for storing Spark + Delta analytics results)

2. Run ETL (load CSV + compute embeddings + populate pgvector table):

   From repo root, load environment variables from `.env` file and run ETL:

   ```bash
   # Load .env file and export variables (works in bash/zsh)
   set -a
   source .env
   set +a
   
   # Set CSV path (if not already in .env)
   export FRU_CSV_PATH="data/raw/fridge_sales_with_rating.csv"

   cd backend
   python etl/load_openai_embeddings_to_pgvector.py
   ```

   > **Note:** The `.env` file created in Section 2.1 should already contain all required database and API configuration. The `set -a` command automatically exports all variables from the `.env` file, so you don't need to manually export them.
   
   > **Alternative:** If you prefer, you can install `python-dotenv` (`pip install python-dotenv`) and modify the ETL script to automatically load the `.env` file without needing to source it manually.

This will:

- read each row from the fridge sales CSV
- call OpenAI embeddings on `CUSTOMER_FEEDBACK`
- insert row + vector into `fru_sales_embeddings` (or similar table)

---

### 2.5 Start frontend (React analytical chat UI)

```bash
cd frontend
npm install
npm run dev
```

This starts Vite at `http://localhost:5173`.

The Vite dev server is configured with a proxy:

```ts
// vite.config.ts
server: {
  port: 5173,
  proxy: {
    "/query": {
      target: "http://localhost:5000",
      changeOrigin: true,
    },
    "/analytics": {
      target: "http://localhost:5000",
      changeOrigin: true,
    },
  },
}
```

So the frontend calls `fetch("/query")` and `fetch("/analytics")` and Vite forwards them to the Flask API.

Open `http://localhost:5173` and ask:

- "Why are Samsung customers unhappy?"
- "Which store has the most negative feedback?"
- "How many LG fridges did we sell last month?"

You'll see:

- **Left**: Chat interface (user + assistant)
- **Right (top)**: Batch Analytics panel (Spark + Delta offline analytics)
  - Shows summary stats, top brands, store performance, top models
  - Updates automatically every 60 seconds
  - Displays "Last Updated At" timestamp
- **Right (bottom)**: Query Stats panel (pgvector real-time stats)
  - Shows counts by brand/store/rating for current query
  - Sample records table

---

### 2.6 Using Spark + Delta locally (optional, for study / offline analytics)

> **Note:** This section is **optional** and separate from the main application. Spark + Delta is used for **offline batch analytics** and generating training data. The main application (Sections 2.1-2.5) works without Spark.

**What is Spark + Delta?**
- **Spark**: Distributed computing framework for processing large datasets
- **Delta Lake**: Open-source storage layer that brings ACID transactions to data lakes
- **Purpose in FRU**: Used for offline analytics and generating NLQ→SQL training pairs (not required for the main chat interface)

**Why use it?**
- Demonstrates enterprise "big data" architecture (useful for interviews)
- Generates training data for fine-tuning NLQ→SQL models (optional enhancement)
- Performs heavy batch analytics on large datasets

**Prerequisites:**
- Apache Spark installed locally (see Section 0 for installation)
- Java 8 or 11 installed (required by Spark)

**Step 1: Ingest CSV into Delta Lake format** (Optional - only if Delta table doesn't exist)

This converts your CSV file into Delta Lake format (a more efficient, versioned format).

> **Note:** You only need to run this if:
> - The Delta table doesn't exist yet
> - You've updated the source CSV and want to refresh the Delta table
> - You want to recreate the Delta table from scratch

**Check if Delta table exists:**
```bash
# From repo root
ls -la data/delta/fru_sales/ 2>/dev/null && echo "Delta table exists" || echo "Delta table does not exist"
```

**If Delta table doesn't exist or you want to regenerate:**

```bash
# From repo root
spark-submit \
  --packages io.delta:delta-spark_2.12:3.2.0 \
  spark_jobs/ingest_delta.py \
  data/raw/fridge_sales_with_rating.csv \
  data/delta/fru_sales
```

**What this does:**
- Reads the CSV file
- Converts it to Delta Lake format
- Saves to `data/delta/fru_sales/` directory
- Creates a versioned, queryable table
- **Overwrites** existing Delta table if it exists (uses `mode("overwrite")`)

**Expected output:**
```
Wrote Delta table to data/delta/fru_sales
```

> **Note:** If you're just exploring the project and the Delta table already exists, you can skip to Step 2 (or skip both steps entirely if the training pairs file also exists).

**Step 2: Generate NLQ→SQL training pairs** (Optional - only if file doesn't exist)

This creates synthetic training data (question-SQL pairs) that could be used to fine-tune a model.

> **Note:** If `data/synthetic/nlq_training_pairs.jsonl` already exists (as it does in the repo), you can skip this step. Only run it if:
> - The file doesn't exist
> - You want to regenerate with updated data from your Delta table
> - You've modified the source CSV and want fresh training pairs

**Check if file exists:**
```bash
# From repo root
ls -la data/synthetic/nlq_training_pairs.jsonl
```

**If file doesn't exist or you want to regenerate:**

```bash
# From repo root
spark-submit \
  --packages io.delta:delta-spark_2.12:3.2.0 \
  spark_jobs/generate_training_data.py \
  data/delta/fru_sales \
  data/synthetic/nlq_training_pairs.jsonl
```

**What this does:**
- Reads the Delta table created in Step 1
- Samples 200 unique records
- Generates natural language questions and corresponding SQL queries
- **Overwrites** the existing JSONL file (if it exists)
- Saves as JSONL file (one question-SQL pair per line)

**Expected output:**
```
Wrote 600 training pairs to data/synthetic/nlq_training_pairs.jsonl
```

> **Warning:** Running this will overwrite any existing `nlq_training_pairs.jsonl` file. The repo already includes a pre-generated file with 24 training pairs, so you typically don't need to run this unless you want to regenerate with your own data.

**Example output format** (`data/synthetic/nlq_training_pairs.jsonl`):
```json
{"question":"How many LG fridges were sold at São Paulo West?","sql":"SELECT STORE_NAME, BRAND, COUNT(*) AS qty FROM fru_sales WHERE BRAND = 'LG' AND STORE_NAME = 'São Paulo West' GROUP BY STORE_NAME, BRAND;"}
{"question":"What is the average price of model FR-4500 in São Paulo West?","sql":"SELECT STORE_NAME, FRIDGE_MODEL, AVG(PRICE) AS avg_price FROM fru_sales WHERE FRIDGE_MODEL = 'FR-4500' AND STORE_NAME = 'São Paulo West' GROUP BY STORE_NAME, FRIDGE_MODEL;"}
```

**What you can do with this:**
- Fine-tune a small NLQ→SQL model (e.g., using LoRA on a base model)
- Evaluate GPT-generated SQL offline
- Use as a dataset for training custom models
- **Note:** The main FRU application (Sections 2.1-2.5) works without this - it uses pgvector for semantic search instead

**Step 3: Run Batch Analytics** (Demonstrates offline analytics)

This step actually demonstrates **offline batch analytics** - the core use case for Spark + Delta. It performs heavy aggregations and statistical analysis that would be too slow or resource-intensive for the real-time API.

**Run analytics:**

```bash
# From repo root
spark-submit \
  --packages io.delta:delta-spark_2.12:3.2.0 \
  spark_jobs/run_analytics.py \
  data/delta/fru_sales \
  data/analytics
```

**What this does:**
- Reads the Delta table created in Step 1
- Performs multiple batch analytics operations:
  1. **Sales Summary by Brand** - Total sales, revenue, average/min/max prices per brand
  2. **Store Performance Metrics** - Sales volume, revenue, feedback rates per store
  3. **Feedback Analysis by Brand** - Positive/negative feedback distribution
  4. **Monthly Sales Trends** - Time-based sales patterns (if date column exists)
  5. **Top Models by Sales Volume** - Best-selling fridge models
  6. **Price Distribution Statistics** - Overall price statistics
- Displays results in the console
- Optionally saves summary to `data/analytics/analytics_summary.json`

**Expected output:**
```
================================================================================
FRU Batch Analytics Report
================================================================================

Total records in Delta table: 500

================================================================================
1. Sales Summary by Brand
================================================================================
+--------+-----------+-------------+---------+---------+---------+
|BRAND   |total_sales|total_revenue|avg_price|min_price|max_price|
+--------+-----------+-------------+---------+---------+---------+
|Samsung |150        |450000.00    |3000.00  |2000.00  |4000.00  |
|LG      |120        |360000.00    |3000.00  |2500.00  |3500.00  |
...

================================================================================
2. Store Performance Metrics
================================================================================
+------------------+-----------+-------------+-------------+------------------------+------------------------+------------------------+
|STORE_NAME        |total_sales|total_revenue|avg_sale_price|negative_feedback_count|positive_feedback_count|negative_feedback_rate|
+------------------+-----------+-------------+-------------+------------------------+------------------------+------------------------+
|New York Store    |100        |300000.00    |3000.00      |15                      |60                     |15.00                  |
...

[Additional analytics sections...]

✓ Analytics summary saved to: data/analytics/analytics_summary.json
================================================================================
Analytics Complete!
================================================================================
```

**Why this demonstrates "offline batch analytics":**
- **Heavy aggregations**: Processes entire dataset with multiple GROUP BY operations
- **Statistical analysis**: Computes averages, sums, counts across millions of records
- **Time-based analysis**: Analyzes trends over time periods
- **Resource-intensive**: Uses distributed computing for large-scale processing
- **Batch processing**: Not real-time - runs on schedule or on-demand, not per-request

**Comparison to online system:**
- **Spark + Delta (offline)**: Heavy batch analytics, full dataset scans, scheduled jobs
- **pgvector + PostgreSQL (online)**: Fast semantic search, real-time queries, per-request responses

**When to use each:**
- **Use Spark + Delta for**: Monthly reports, trend analysis, bulk data processing, training data generation
- **Use pgvector for**: Real-time chat queries, interactive analytics, semantic search

**Integration with Frontend:**

The batch analytics results are automatically displayed in the frontend UI:

- **Batch Analytics Panel** (top right): Shows Spark + Delta analytics
  - Fetches from `/analytics` API endpoint
  - Auto-refreshes every 60 seconds
  - Displays "Last Updated At" timestamp
  - Shows summary stats, top brands, store performance, top models

- **Query Stats Panel** (bottom right): Shows pgvector real-time results
  - Updates with each user query
  - Shows query-specific statistics

This demonstrates the **separation of concerns**:
- **Offline batch intelligence** (Spark + Delta) → Batch Analytics Panel
- **Interactive intelligence** (pgvector) → Query Stats Panel

**Troubleshooting:**
- **"spark-submit: command not found"**: Install Apache Spark (see Section 0 Prerequisites)
- **"Java not found"**: Install Java 8 or 11: `brew install openjdk@11` (macOS) or `sudo apt-get install openjdk-11-jdk` (Linux)
- **"Package not found"**: The `--packages` flag downloads Delta Lake automatically, but requires internet connection

---

# 🧪 3. Local “Prod Simulation” Mode (Option A – Docker Only)

This mode uses only Docker to simulate a production-like setup on your machine.

## 3.1 Build backend image

Ensure `backend/Dockerfile.api` exists (something like):

```Dockerfile
FROM python:3.10-slim

WORKDIR /app
COPY . .

RUN pip install --no-cache-dir -r requirements.txt

EXPOSE 5000
CMD ["python", "api/app.py"]
```

The docker-compose file in `infra/docker/docker-compose.yml` already builds this.

Start everything:

```bash
cd infra/docker
docker compose --env-file ../../.env up --build -d
```

- API: `http://localhost:5000`
- DB: `localhost:5432` on the host

Frontend for a “prod-like” test:

```bash
cd frontend
npm install
npm run build
```

Serve `frontend/dist` from `npm run preview`, Nginx, or any static file server.  
For a simple static host demo, you can:

```bash
npm run preview
```
and then manually configure Nginx later.

---

# 🚀 4. AWS Production – ECS Fargate + Aurora + Bedrock (Option A1 + Aurora)

This is the **primary production story** for interviews and real deployments:

- **Aurora PostgreSQL + pgvector** – vectorized semantic store
- **ECS Fargate** – serverless container backends
- **S3 + CloudFront** – static frontend
- **Bedrock Claude 3** – governed reasoning
- **OpenAI embeddings** – high-quality vectors

> **💡 Recommended**: Use the **Terraform IaC implementation** (`infra/terraform/`) for automated, reproducible deployments with security best practices. See [`infra/terraform/README.md`](../infra/terraform/README.md) for complete documentation. The manual steps below are for understanding the architecture.

## 4.1 Aurora PostgreSQL + pgvector

1. Create an **Aurora PostgreSQL** cluster (Serverless v2 recommended)
2. Enable pgvector extension:

   ```sql
   CREATE EXTENSION IF NOT EXISTS vector;
   ```

3. Apply schema similar to `docs/sql/schema_pgvector.sql`:

   ```sql
   -- basic example, adapt to your actual schema
   CREATE TABLE IF NOT EXISTS fru_sales_embeddings (
     id SERIAL PRIMARY KEY,
     brand TEXT,
     fridge_model TEXT,
     price NUMERIC,
     sales_date DATE,
     store_name TEXT,
     customer_feedback TEXT,
     feedback_rating TEXT,
     embedding vector(1536) -- or 3072 depending on model
   );
   ```

4. Run the same ETL script against Aurora:

   ```bash
   export PGHOST=<aurora-endpoint>
   export PGPORT=5432
   export PGUSER=fru_user
   export PGPASSWORD=<password>
   export PGDATABASE=fru_db
   export FRU_CSV_PATH="data/raw/fridge_sales_with_rating.csv"

   python backend/etl/load_openai_embeddings_to_pgvector.py
   ```

---

## 4.2 Build & push backend image to ECR

```bash
cd backend
docker build -t fru-api .
```

Create ECR repo:

```bash
aws ecr create-repository --repository-name fru-api
```

Tag + push:

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=us-east-1
ECR_URL="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

docker tag fru-api:latest "$ECR_URL/fru-api:latest"
aws ecr get-login-password --region $AWS_REGION |       docker login --username AWS --password-stdin "$ECR_URL"
docker push "$ECR_URL/fru-api:latest"
```

---

## 4.3 Create ECS Fargate Service

- VPC with private subnets
- ECS cluster (Fargate)
- Task definition using `fru-api` image
- Security groups:
  - allow outbound to Aurora SG
  - allow outbound to Bedrock (via Internet or VPC endpoint)

**Security Best Practices:**

1. **IAM Role Separation:**
   - **Execution Role**: Used by ECS service to start tasks
     - ECR: Pull container images
     - CloudWatch: Write logs
     - Secrets Manager: Read secrets for task definition
   - **Runtime Role**: Assumed by running containers
     - Bedrock: Invoke models
     - Secrets Manager: Read secrets at runtime
     - RDS IAM Auth: Connect to Aurora (if enabled)

2. **Secrets Management:**
   - **Never store secrets in environment variables**
   - All sensitive data stored in Secrets Manager
   - Secrets referenced in ECS task definition via `secrets` block

**Environment variables in task definition** (non-sensitive only):

```text
PGHOST=<aurora-endpoint>
PGPORT=5432
PGDATABASE=fru_db
AWS_REGION=us-east-1
BEDROCK_MODEL_ID=anthropic.claude-3-haiku-20240229-v1:0
```

**Secrets** (from Secrets Manager, not environment variables):

```text
OPENAI_API_KEY=<from Secrets Manager>
PGPASSWORD=<from Secrets Manager or use IAM database authentication>
PGUSER=<from Secrets Manager, optional if using IAM auth>
```

**IAM Roles:**

- **Execution Role** (attached to task definition):
  - `ecr:GetAuthorizationToken`
  - `ecr:BatchCheckLayerAvailability`
  - `ecr:GetDownloadUrlForLayer`
  - `ecr:BatchGetImage`
  - `logs:CreateLogStream`
  - `logs:PutLogEvents`
  - `secretsmanager:GetSecretValue` (for task definition secrets)

- **Runtime Role** (task role):
  - `bedrock:InvokeModel`
  - `bedrock:InvokeModelWithResponseStream`
  - `secretsmanager:GetSecretValue` (for runtime secrets)
  - `rds-db:connect` (if using IAM database authentication)

Expose ECS service via either:

- Application Load Balancer (ALB) → `/query` → ECS
- API Gateway HTTP API → private integration to ECS

---

## 4.4 Frontend in AWS

1. Build frontend:

   ```bash
   cd frontend
   npm install
   npm run build
   ```

2. Upload `dist/` to an S3 bucket configured as a static site:

   ```bash
   aws s3 sync dist/ s3://fru-frontend-bucket/
   ```

3. Put CloudFront in front of S3 for HTTPS + caching.

4. Configure the frontend so it calls the API Gateway / ALB URL for `/query`.  
   For example, set an env variable like `VITE_API_BASE_URL=https://api.fru.yourdomain.com` and prepend it in the fetch call.

Result:

- `https://fru.yourdomain.com` → CloudFront → S3 SPA
- SPA → `https://api.fru.yourdomain.com/query` → API Gateway/ALB → ECS Fargate → Aurora + Bedrock

---

## 4.5 Bedrock networking (VPC endpoint, optional but recommended)

For full enterprise posture:

- Add a **VPC Endpoint** for Bedrock in your VPC
- Route ECS tasks’ traffic to Bedrock through that endpoint
- This keeps inference inside AWS network (no public internet path)

---

# ☸️ 5. Kubernetes / EKS Deployment (Option B)

If the interviewer or your environment pushes for Kubernetes, you can deploy FRU to **EKS**.  
The building blocks:

- EKS cluster
- Aurora PostgreSQL (same as above)
- Bedrock + OpenAI as external services
- Kubernetes `Deployment` + `Service` for API
- Ingress (ALB Ingress Controller) for HTTP/HTTPS

### 5.1 Backend deployment YAML (simplified)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fru-api
  labels:
    app: fru-api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: fru-api
  template:
    metadata:
      labels:
        app: fru-api
    spec:
      containers:
        - name: fru-api
          image: <ECR_URL>/fru-api:latest
          ports:
            - containerPort: 5000
          env:
            - name: PGHOST
              value: "<aurora-endpoint>"
            - name: PGPORT
              value: "5432"
            - name: PGUSER
              valueFrom:
                secretKeyRef:
                  name: fru-secrets
                  key: pguser
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: fru-secrets
                  key: pgpassword
            - name: PGDATABASE
              value: "fru_db"
            - name: AWS_REGION
              value: "us-east-1"
            - name: BEDROCK_MODEL_ID
              value: "anthropic.claude-3-haiku-20240229-v1:0"
```

Service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: fru-api-svc
spec:
  type: ClusterIP
  selector:
    app: fru-api
  ports:
    - port: 80
      targetPort: 5000
```

Then Ingress (ALB Ingress Controller) to expose `/query` externally.

Frontend: same S3 + CloudFront setup as ECS, or host frontend as a separate `Deployment + Service + Ingress`.

For interviews, you can explain:

> "On EKS, the architecture is identical: Aurora + pgvector for embeddings, EKS pods for API, Bedrock for reasoning, S3/CloudFront or an Nginx ingress for SPA hosting."

---

# 🏗️ 6. Terraform IaC (Option C – Fully Implemented)

**Full Terraform + Terragrunt implementation is now available!**

The infrastructure is organized as reusable modules with Terragrunt for environment management:

**Modules:**
- `vpc/` — VPC, subnets, NAT gateways, VPC endpoints
- `aurora/` — Aurora PostgreSQL with pgvector, IAM auth support
- `iam/` — IAM roles (execution + runtime separation)
- `secrets-manager/` — Secrets Manager for sensitive data
- `ecs/` — ECS cluster, service, task definition
- `alb/` — Application Load Balancer
- `frontend/` — S3 + CloudFront for frontend

**Structure:**

```text
infra/terraform/
  modules/              # Reusable Terraform modules
    vpc/
    aurora/
    iam/
    secrets-manager/
    ecs/
    alb/
    frontend/
    infrastructure/     # Wrapper (VPC + Aurora + IAM + Secrets)
    application/        # Wrapper (ECS + ALB + Frontend)
  environments/         # Terragrunt configs
    terragrunt.hcl     # Root config
    dev/
      infrastructure/
      application/
    prod/
      infrastructure/
      application/
```

**Security Best Practices:**
- Secrets stored in Secrets Manager (not environment variables)
- IAM role separation (execution vs runtime)
- IAM database authentication support
- Private subnets for ECS tasks

**Deployment:**

```bash
# Deploy infrastructure layer
./run_scripts/aws/terraform/deploy.sh dev infrastructure

# Deploy application layer
./run_scripts/aws/terraform/deploy.sh dev application
```

See `infra/terraform/README.md` for complete documentation.

For interviews, you can explain:

> "I've implemented a complete Terraform + Terragrunt setup with modular architecture. The infrastructure is organized into reusable modules (VPC, Aurora, ECS, ALB, Frontend) with Terragrunt managing environment-specific configurations. Security best practices are built in: secrets in Secrets Manager, IAM role separation (execution vs runtime), and support for IAM database authentication. The deployment is fully automated via scripts."

If you want a concrete Terraform skeleton later, you can add it under `infra/terraform/` and model:

- `aws_rds_cluster` for Aurora
- `aws_ecs_cluster`, `aws_ecs_task_definition`, `aws_ecs_service`
- `aws_lb`, `aws_lb_target_group`, `aws_lb_listener`
- `aws_s3_bucket`, `aws_cloudfront_distribution`

---

# 🧯 7. Troubleshooting Checklist

## Common Errors and Solutions

### API 500 errors
- **Missing or invalid `OPENAI_API_KEY`**
  - Check `.env` file has `OPENAI_API_KEY=sk-...`
  - Verify key is valid: `curl https://api.openai.com/v1/models -H "Authorization: Bearer $OPENAI_API_KEY"`
  
- **Bedrock permission issues (`AccessDeniedException`)**
  - Verify AWS credentials: `aws sts get-caller-identity`
  - Check IAM permissions include `bedrock:InvokeModel`
  - Verify Bedrock model access in AWS Console (some models require enablement)
  - Check `AWS_REGION` matches region where Bedrock is enabled
  
- **Database connection errors**
  - Verify PostgreSQL is running: `docker ps | grep fru_db`
  - Check connection string: `psql "postgresql://postgres:postgres@localhost:5432/fru_db" -c "SELECT 1;"`
  - Verify environment variables: `echo $PGHOST $PGUSER $PGDATABASE`
  - Check security groups (for Aurora) allow traffic from ECS/EKS

### No matches / zero stats
- **Embeddings not loaded (ETL didn't run)**
  - Verify ETL completed: `psql ... -c "SELECT COUNT(*) FROM fru_sales_embeddings;"`
  - Re-run ETL: `python backend/etl/load_openai_embeddings_to_pgvector.py`
  - Check CSV file exists: `ls -la data/raw/fridge_sales_with_rating.csv`
  
- **Wrong table name / schema mismatch**
  - Verify table exists: `psql ... -c "\dt fru_sales_embeddings"`
  - Check schema: `psql ... -c "\d fru_sales_embeddings"`
  - Re-run schema init: `psql ... -f docs/sql/schema_pgvector.sql`

### ModuleNotFoundError / Import errors
- **Python dependencies not installed**
  - Activate virtual environment: `source venv/bin/activate`
  - Install dependencies: `pip install -r requirements.txt`
  - Verify installation: `python -c "import flask, psycopg2, openai, boto3, pandas"`

### CORS issues (in non-proxy setups)
- **Local development**
  - Use Vite dev proxy (already configured in `vite.config.ts`)
  - Or enable CORS in Flask API (see code changes)
  
- **Production**
  - Use Nginx/ALB path routing
  - Configure CORS headers in API Gateway/ALB
  - Set `ALLOWED_ORIGINS` environment variable in API

### High latency
- **Optimize model selection**
  - Use smaller Claude model (Haiku instead of Sonnet)
  - Reduce `max_tokens` in Bedrock calls
  
- **Database optimization**
  - Pre-filter rows (brand, date) before ANN search
  - Ensure pgvector index exists: `CREATE INDEX ... USING ivfflat`
  - Reduce `limit` parameter in vector search
  
- **Network issues**
  - Use VPC endpoints for Bedrock (keeps traffic in AWS network)
  - Check database connection pooling is enabled

### Docker issues
- **Container won't start**
  - Check logs: `docker logs fru_api` or `docker logs fru_db`
  - Verify `.env` file exists and has required variables
  - Check port conflicts: `lsof -i :5000` or `lsof -i :5432`
  
- **Database connection from host fails**
  - Verify port mapping: `docker ps` should show `0.0.0.0:5432->5432/tcp`
  - Check container is running: `docker ps | grep fru_db`
  - Try connecting via Docker: `docker exec -it fru_db psql -U postgres -d fru_db`

### Environment variable issues
- **Variables not loading**
  - Check `.env` file location (should be at repo root)
  - Verify Docker Compose uses `--env-file ../../.env`
  - For local Python scripts, export variables or use `python-dotenv`
  
- **Missing required variables**
  - Required: `OPENAI_API_KEY`, `PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`
  - Optional: `AWS_REGION`, `BEDROCK_MODEL_ID`, `OPENAI_EMBED_MODEL`
  - Check with: `env | grep -E "(PG|OPENAI|AWS|BEDROCK)"`

---

# 🧭 8. Interview Sound Bites (Tied to This Runbook)

You can use these while sketching the system:

- “**Spark does batch intelligence; pgvector does interactive intelligence; Claude communicates it.**”
- “We **never** ask the LLM to guess the data; we retrieve facts from pgvector + SQL and let Claude explain them.”
- “OpenAI is used only for embeddings here; **all reasoning stays in AWS** on Bedrock.”
- “Production path is **Aurora + ECS Fargate + Bedrock**, with optional EKS if the org already standardized on Kubernetes.”
- “This README_RUN gives us a clean story: local dev, local prod, ECS, EKS, and IaC via Terraform.”

---

That’s it. This file should live at the root of your repo as `README_RUN.md` and serve as your **runbook** and **interview crib sheet**.
