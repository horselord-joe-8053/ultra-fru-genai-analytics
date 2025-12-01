# 📦 FRU GenAI Analytics Overview 
**(Spark + Delta + OpenAI Embeddings + pgvector + Bedrock + AWS)**

FRU (**Friday aRe Us**) is a real, end-to-end **conversational analytics system** built over refrigerator sales data.

It demonstrates:

- ✔️ **Enterprise GenAI architecture**
- ✔️ **Separation of offline vs online compute**
- ✔️ **RAG over structured + unstructured data**
- ✔️ **Low-cost inference at scale**
- ✔️ **AWS-native deployment story**

It is built specifically to support a **Senior AWS GenAI Architect interview** and to be used as a working prototype.

---

# 🧠 **1. Concept**
FRU (**Friday aRe Us**) is a **conversational analytics assistant** for fridge sales.

Typical user asks:
> _“Why are Samsung customers unhappy?”_  
> _“How many LG fridges did we sell in Brazil last month?”_  
> _“Which stores consistently get negative delivery feedback?”_

The system produces grounded insights using **real sales + feedback data**, not hallucination.

---

# 🧩 **2. Architecture Overview**

### 🔵 *The Golden Separation*

> **Spark does batch intelligence.  
> pgvector does interactive intelligence.  
> Claude explains it.**

This separation is the core of the design interview.

### System layers

**Offline Factory (heavy)**
- CSV → Delta
- feature generation
- NLQ→SQL training pairs
- analytics modeling

**Online Brain (fast)**
- embeddings → pgvector search
- relational SQL aggregation
- Bedrock summarization

---

## 📐 Architecture Diagram (Textual)

```text
                              ┌──────────────────────┐
                              │ Spark + Delta Lake   │
                              │ ▸ ingest CSV         │
                              │ ▸ analytics          │
                              │ ▸ NLQ→SQL dataset    │
                              └──────────┬───────────┘
                                         │
                                         ▼
                      ┌────────────────────────────────────┐
                      │  OpenAI Embeddings (offline batch)  │
                      │  CSV => vectors per feedback        │
                      └──────────────┬──────────────────────┘
                                     │
                                     ▼
                         ┌──────────────────────────┐
                         │ Postgres + pgvector      │
                         │ ANN search + SQL filters │
                         └───────────┬──────────────┘
                                     │
                                     ▼
                        ┌────────────────────────────┐
                        │ Flask API (ECS / Fargate)  │
                        └──────────┬─────────────────┘
                                    │
                                    ▼
                      ┌──────────────────────────────────┐
                      │ Bedrock Claude Summarization      │
                      └──────────────────────────────────┘
```

---

# 🗂 **3. Suggested Repository Layout**

```text
fru-genai-analytics/
│
├─ README.md                     # ← This file
├─ requirements.txt
│
├─ data/
│   ├─ raw/
│   │   └─ fridge_sales_with_rating.csv
│   └─ synthetic/
│       └─ nlq_training_pairs.jsonl
│
├─ docs/
│   ├─ architecture/
│   │   └─ pgvector_inference.md
│   └─ sql/
│       └─ schema_pgvector.sql
│
├─ backend/
│   ├─ api/
│   │   └─ app.py
│   ├─ etl/
│   │   └─ load_openai_embeddings_to_pgvector.py
│   └─ llm/
│       └─ bedrock_client.py
│
├─ spark_jobs/
│   ├─ ingest_delta.py
│   └─ generate_training_data.py
│
└─ infra/
    ├─ docker/
    │   ├─ Dockerfile.api
    │   └─ docker-compose.yml
    ├─ terraform/
    │   └─ main.tf
    └─ README_INFRA.md
```

---

# ⚡️ **4. Local Quickstart (Works Without AWS)**

> Easiest way to play with FRU and test embeddings.

## 4.1 Install dependencies

```bash
pip install -r requirements.txt
```

---

## 4.2 Run pgvector locally

```bash
cd infra/docker
docker compose up -d
```

You now have:
- Postgres + pgvector on `localhost:5432`
- Optional API container

---

## 4.3 Initialize pgvector schema

```bash
psql "postgresql://postgres:postgres@localhost:5432/fru_db"   -f docs/sql/schema_pgvector.sql
```

---

## 4.4 Load embeddings into pgvector

> Embeds `CUSTOMER_FEEDBACK` using OpenAI `text-embedding-3-small`.

```bash
export OPENAI_API_KEY="sk-yourkey"
export PGHOST=localhost
export PGPORT=5432
export PGUSER=postgres
export PGPASSWORD=postgres
export PGDATABASE=fru_db
export FRU_CSV_PATH="data/raw/fridge_sales_with_rating.csv"

python backend/etl/load_openai_embeddings_to_pgvector.py
```

---

## 4.5 Run API locally

```bash
python backend/api/app.py
```

Test:

```bash
curl -X POST http://localhost:5000/query   -H "Content-Type: application/json"   -d '{"query": "Why are Samsung customers upset?"}'
```

The `/query` endpoint will:

1. Embed your question using OpenAI.
2. Run a pgvector similarity search over `fru_sales_embeddings`.
3. Compute simple stats (counts by brand/store/rating).
4. Send structured JSON + your question to Claude via Bedrock.
5. Return a grounded natural-language summary plus raw stats.

---

# 🔥 **5. Analytics with Spark + Delta**

> This is your enterprise “big data platform” story.

## 5.1 Ingest CSV → Delta Lake

```bash
spark-submit   --packages io.delta:delta-spark_2.12:3.2.0   spark_jobs/ingest_delta.py   data/raw/fridge_sales_with_rating.csv   data/delta/fru_sales
```

---

## 5.2 Generate NLQ→SQL examples for LoRA

```bash
spark-submit   --packages io.delta:delta-spark_2.12:3.2.0   spark_jobs/generate_training_data.py   data/delta/fru_sales   data/synthetic/nlq_training_pairs.jsonl
```

This creates structured AI training data like:

```json
{"question":"How many LG fridges were sold at São Paulo West?",
 "sql":"SELECT STORE_NAME, BRAND, COUNT(*) AS qty ..."}
```

You can later use this JSONL to:

- fine-tune a small NLQ→SQL model (e.g. with LoRA), or  
- evaluate GPT-generated SQL offline.

---

# 🧠 **6. Intelligence Model: OpenAI Embeddings + pgvector**

> The beating heart of FRU.

1. Convert user text → **OpenAI embedding** (`text-embedding-3-small`).
2. ANN search with pgvector: `embedding <-> query_vector`.
3. Apply relational filters if needed (brand, date, rating).
4. Compute counts and basic stats.
5. Feed **facts** to Claude.

This keeps inference:
- **fast**
- **cheap**
- **non-hallucinatory**
- **governable**

### SQL Example

```sql
WITH nearest AS (
  SELECT id FROM fru_sales_embeddings
  WHERE brand='LG'
  ORDER BY embedding <-> $query_vector
  LIMIT 50
)
SELECT fridge_model, COUNT(*) complaints
FROM fru_sales_embeddings
WHERE id IN (SELECT id FROM nearest)
  AND feedback_rating='Negative'
GROUP BY fridge_model
ORDER BY complaints DESC;
```

---

# 🦾 **7. Integrating Bedrock Claude**

Claude sees:

- Structured facts (`stats`, `sample_records`)  
- The original business question  

### Prompt logic (conceptual)

System prompt (simplified):

> You are a retail analytics assistant.  
> Use JSON stats as single source of truth.  
> Never invent new numbers.  
> If data is insufficient, say so.

User content:

```json
{
  "question": "...",
  "stats": { ... },
  "sample_records": [ ... ]
}
```

Claude returns:

- An explanation of **what is happening**
- Emphasis on **evidence**, not guesses
- Suggestions like:
  - “Investigate delivery provider X in region Y”
  - “Consider service training at store Z”

---

# 🏗 **8. Full AWS Deployment (Interview-Friendly Path)**

> This is your “I can design and ship this on AWS” story.

### 8.1 S3 (raw + delta storage)

- Bucket: `fru-analytics-data-<env>`
- Layout:
  ```text
  s3://fru-analytics-data-prod/raw/fridge_sales/<date>/fridge_sales_with_rating.csv
  s3://fru-analytics-data-prod/delta/fru_sales/...
  ```

Use `infra/terraform/main.tf` as a starting point (or create manually first, then backfill Terraform).

---

### 8.2 RDS (or Aurora) PostgreSQL with pgvector

- Engine: Postgres 16 (or Aurora Postgres compatible)
- Private subnets
- Security groups:
  - allow ECS tasks, deny public internet
- After provisioning:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
\i docs/sql/schema_pgvector.sql
```

FRU now has a semantic store inside AWS.

---

### 8.3 Embedding ETL in AWS

First stage: run ETL from your laptop pointing at RDS:

```bash
export PGHOST=<rds-endpoint>   # from RDS console
export PGPORT=5432
export PGUSER=fru_user
export PGPASSWORD=<password>
export PGDATABASE=fru_db
export FRU_CSV_PATH=data/raw/fridge_sales_with_rating.csv

python backend/etl/load_openai_embeddings_to_pgvector.py
```

Later evolution:

- run ETL on ECS Fargate or EMR Serverless
- pull CSV from S3 rather than local disk

---

### 8.4 Containerize API + push to ECR

```bash
docker build -f infra/docker/Dockerfile.api -t fru-api .
aws ecr create-repository --repository-name fru-api
# tag & push
```

---

### 8.5 ECS Fargate Service

- Task definition uses `fru-api` ECR image.
- Environment variables:

```text
PGHOST=<rds-endpoint>
PGPORT=5432
PGUSER=fru_user
PGPASSWORD=<password>
PGDATABASE=fru_db
OPENAI_API_KEY=<your-openai-key>
AWS_REGION=<region-with-bedrock>
BEDROCK_MODEL_ID=anthropic.claude-3-haiku-20240229-v1:0
```

- Service runs in private subnets.
- Security groups allow:
  - outbound to RDS SG
  - outbound to Bedrock via VPC endpoint (recommended)
- Exposed via:
  - ALB, or
  - API Gateway HTTP API via private integration.

---

### 8.6 Bedrock Access

Grant the ECS task role permissions for:

- `bedrock:InvokeModel`
- `bedrock:InvokeModelWithResponseStream`

And, optionally, restrict to the Claude model ID you use.

---

# 🛡 **9. Governance & Safety**

- **OpenAI** only used for **offline + query-time embeddings**, not for final narrative.
- **Claude** (Bedrock) used for answers:
  - Data never leaves AWS during reasoning.
  - IAM-controlled access.
  - VPC endpoints for Bedrock and RDS.
- **Postgres + pgvector**:
  - row-level governance
  - role-based permissions
  - encryption at rest (RDS-managed)

Add:

- CloudWatch metrics for:
  - latency
  - token usage
  - error rate
- CloudWatch Logs:
  - store inputs/outputs (with redaction) for evaluation.

---

# 🧭 **10. Interview Sound Bites**

You can drop these sentences in system design / LP rounds:

> *“Spark does batch intelligence; pgvector does interactive intelligence; Claude communicates it.”*

> *“We do not ask the LLM to guess the data.  
> We retrieve the facts with embeddings + SQL, then ask the LLM to explain them.”*

> *“OpenAI gives us state-of-the-art embeddings; Bedrock gives us governed reasoning.”*

> *“Fine-tuning is optional here; RAG is mandatory. We first exhaust RAG + retrieval quality before spending on training.”*

> *“In production, all inference runs inside AWS: ECS + RDS + Bedrock + VPC endpoints.”*

---

# 📌 **11. Next Steps (Roadmap)**

- Wire `/query` into a **simple React UI** for business stakeholders.
- Implement:
  - SQL generation using the NLQ→SQL dataset (`data/synthetic/nlq_training_pairs.jsonl`).
  - A LoRA training script (SageMaker or local) for a small NLQ→SQL model.
- Add:
  - Canary deployments for new models.
  - Evaluation harness: “Golden questions” + acceptance thresholds.

---

# 🙌 Summary

FRU is both:

1. A **real playground** for experimenting with Spark, Delta, OpenAI embeddings, pgvector, and Bedrock.
2. A **storyboard** you can use in a **Senior AWS GenAI Architect** interview to demonstrate:
   - architectural judgment  
   - cost awareness  
   - governance thinking  
   - practical GenAI patterns  
   - ability to ship a working prototype.

Use it, extend it, and mine it for examples when talking through RAG, embeddings, and hybrid AWS + LLM architectures.
