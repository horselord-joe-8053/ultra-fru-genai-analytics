# 📘 FRU – Friday aRe Us  
**GenAI Analytics – How to Run (Local, AWS, EKS, Terraform)**

FRU (**Friday aRe Us**) is a GenAI analytics assistant over fridge sales data, built with:

- OpenAI **embeddings** (text-embedding-3-small)
- Postgres + **pgvector** (semantic store)
- AWS **Bedrock** (Claude 3) for narrative answers
- Flask API backend
- React + Vite + Tailwind frontend
- Spark + Delta Lake for offline analytics
- Target production: **ECS Fargate + Aurora PostgreSQL + Bedrock**  
  (plus optional **EKS** and **Terraform** paths)

This guide explains **how to run** FRU in:

1. Local Developer Mode (best for coding)
2. Local “Production Simulation” (Docker-only)
3. AWS ECS Fargate + Aurora + Bedrock (primary prod path)
4. Kubernetes / EKS deployment (optional path)
5. Terraform-based IaC (optional path)

---

## 🧩 0. Prerequisites

### Local
- Python 3.10+
- Node.js 18+
- Docker Desktop (or compatible)
- OpenAI API key
- AWS credentials configured (for Bedrock)

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

```bash
PGUSER=postgres
PGPASSWORD=postgres
PGDATABASE=fru_db

OPENAI_API_KEY=sk-...

AWS_REGION=us-east-1
BEDROCK_MODEL_ID=anthropic.claude-3-haiku-20240229-v1:0
```

> Tip: keep `.env` out of git or add it to `.gitignore`.

---

### 2.2 Run Postgres + pgvector + API with Docker

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

---

### 2.3 Load CSV into the database

You should have `data/raw/fridge_sales_with_rating.csv` and:

- a schema / init script (for example `docs/sql/schema_pgvector.sql`)
- an ETL script like `backend/etl/load_openai_embeddings_to_pgvector.py`

1. Initialize schema:

   ```bash
   psql "postgresql://postgres:postgres@localhost:5432/fru_db"          -f docs/sql/schema_pgvector.sql
   ```

2. Run ETL (load CSV + compute embeddings + populate pgvector table):

   ```bash
   export OPENAI_API_KEY=sk-...
   export PGHOST=localhost
   export PGPORT=5432
   export PGUSER=postgres
   export PGPASSWORD=postgres
   export PGDATABASE=fru_db
   export FRU_CSV_PATH="data/raw/fridge_sales_with_rating.csv"

   cd backend
   python etl/load_openai_embeddings_to_pgvector.py
   ```

This will:

- read each row from the fridge sales CSV
- call OpenAI embeddings on `CUSTOMER_FEEDBACK`
- insert row + vector into `fru_sales_embeddings` (or similar table)

---

### 2.4 Start frontend (React analytical chat UI)

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
  },
}
```

So the frontend calls `fetch("/query")` and Vite forwards it to the Flask API.

Open `http://localhost:5173` and ask:

- “Why are Samsung customers unhappy?”
- “Which store has the most negative feedback?”
- “How many LG fridges did we sell last month?”

You’ll see:

- left: chat (user + assistant)
- right: stats (counts by brand/store/rating) + a mini table of sample records.

---

### 2.5 Using Spark + Delta locally (optional, for study / offline analytics)

Run ingestion to Delta:

```bash
spark-submit       --packages io.delta:delta-spark_2.12:3.2.0       spark_jobs/ingest_delta.py       data/raw/fridge_sales_with_rating.csv       data/delta/fru_sales
```

Generate NLQ→SQL synthetic training data (for future LoRA fine-tuning):

```bash
spark-submit       --packages io.delta:delta-spark_2.12:3.2.0       spark_jobs/generate_training_data.py       data/delta/fru_sales       data/synthetic/nlq_training_pairs.jsonl
```

You can later train an NLQ→SQL model using these pairs, but the core system already works without fine-tuning.

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

Environment variables in task definition:

```text
PGHOST=<aurora-endpoint>
PGPORT=5432
PGUSER=fru_user
PGPASSWORD=<password>
PGDATABASE=fru_db

OPENAI_API_KEY= (use Secrets Manager + task role IAM to fetch)

AWS_REGION=us-east-1
BEDROCK_MODEL_ID=anthropic.claude-3-haiku-20240229-v1:0
```

Attach IAM role with:

- `bedrock:InvokeModel`
- `bedrock:InvokeModelWithResponseStream`
- Permissions to read secret from Secrets Manager

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

# 🏗️ 6. Terraform IaC (Option C – Sketch)

To go fully IaC, you can:

- use Terraform modules for:
  - VPC
  - Aurora PostgreSQL
  - ECS cluster + service
  - ECR repos
  - IAM roles
  - S3 + CloudFront
- manage secrets via `aws_secretsmanager_secret`

Pseudo-structure:

```text
infra/terraform/
  main.tf
  vpc.tf
  aurora.tf
  ecs.tf
  iam.tf
  s3_cloudfront.tf
  outputs.tf
```

You don’t need full code for the interview; it’s enough to say:

> "In production, I’d capture this in Terraform: one module for the network (VPC + subnets), one for the database (Aurora + pgvector), another for the ECS service (task def + service + ALB), and a final one for the frontend (S3 + CloudFront). Secrets live in Secrets Manager, referenced from task defs via IAM."

If you want a concrete Terraform skeleton later, you can add it under `infra/terraform/` and model:

- `aws_rds_cluster` for Aurora
- `aws_ecs_cluster`, `aws_ecs_task_definition`, `aws_ecs_service`
- `aws_lb`, `aws_lb_target_group`, `aws_lb_listener`
- `aws_s3_bucket`, `aws_cloudfront_distribution`

---

# 🧯 7. Troubleshooting Checklist

- **API 500 errors**  
  - Missing or invalid `OPENAI_API_KEY`  
  - Bedrock permission issues (`AccessDeniedException`)  
  - Aurora security group not allowing ECS/EKS traffic

- **No matches / zero stats**  
  - Embeddings not loaded (ETL didn’t run)  
  - Wrong table name / schema mismatch

- **CORS issues (in non-proxy setups)**  
  - Use Vite dev proxy for local  
  - Use Nginx/ALB path routing in prod

- **High latency**  
  - Use smaller Claude model (Haiku)  
  - Reduce `max_tokens`  
  - Pre-filter rows (brand, date) before ANN search

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
