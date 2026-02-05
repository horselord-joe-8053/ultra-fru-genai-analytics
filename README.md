# 📦 FRU GenAI Analytics Overview 
**(Spark + Delta + OpenAI Embeddings + pgvector + Bedrock + AWS)**

FRU (**Fridges R Us**) is a real, end-to-end **conversational analytics system** built over refrigerator sales data.

## 📋 Table of Contents

1. [🧠 1. Concept](#-1-concept)
2. [🧩 2. Architecture Overview](#-2-architecture-overview)
   - [System layers](#system-layers)
   - [📐 Architecture Diagram (Textual)](#architecture-diagram-textual)
3. [🗂 3. Project Layout](#-3-project-layout)
4. [⚡️ 4. Local Quickstart](#-4-local-quickstart)
5. [🔥 5. Analytics with Spark + Delta](#-5-analytics-with-spark-delta)
   - [5.1 Ingest CSV → Delta Lake](#-51-ingest-csv-delta-lake)
   - [5.2 Generate NLQ→SQL examples for LoRA](#-52-generate-nlqsql-examples-for-lora)
6. [🧠 6. Intelligence Model: OpenAI Embeddings + pgvector](#-6-intelligence-model-openai-embeddings-pgvector)
   - [6.1 Overview](#-61-overview)
   - [6.2 Embedding Generation (Offline Factory)](#-62-embedding-generation-offline-factory)
   - [6.3 pgvector Schema](#-63-pgvector-schema)
   - [6.4 Inference-Time Flow](#-64-inference-time-flow)
   - [6.5 LLM Prompt Pattern](#-65-llm-prompt-pattern)
   - [6.6 Why pgvector vs Spark SQL?](#-66-why-pgvector-vs-spark-sql)
7. [🦾 7. Integrating Bedrock Claude](#-7-integrating-bedrock-claude)
   - [Prompt logic (conceptual)](#prompt-logic-conceptual)
8. [🏗 8. Full AWS Deployment](#-8-full-aws-deployment)
9. [🛡 9. Governance & Safety](#-9-governance-safety)
10. [🤖 10. Query Processing Architecture](#-10-query-processing-architecture) ⭐
   - [10.1 Current Implementation](#-101-current-implementation)
     - [Architecture](#architecture)
     - [Flow](#flow)
   - [10.2 Evolution Path: Enhancement_A → B → C](#-102-evolution-path-enhancement_a-b-c)
     - [Enhancement_A: LLM Classification + SQL Generation](#enhancement_a-llm-classification-sql-generation)
     - [Enhancement_B: Hybrid Query Processing](#enhancement_b-hybrid-query-processing)
     - [Enhancement_C: Agent-Based Autonomous Planning (Implemented)](#enhancement_c-agent-based-autonomous-planning-implemented)
   - [10.3 Agent-Based System (Enhancement_C) - Implementation](#-103-agent-based-system-enhancement_c-implementation)
     - [Components](#components)
     - [Usage](#usage)
     - [Feature Flags](#feature-flags)
     - [Debugging](#debugging)
     - [Performance Considerations](#performance-considerations)
     - [Migration Path](#migration-path)
     - [Rollback](#rollback)
11. [📌 11. Next Steps (Roadmap)](#-11-next-steps-roadmap)
12. [🙌 Summary](#summary)

---

## 📚 Documentation Guide

**Main Documentation:**
- **[`docs/README_RUN.md`](docs/README_RUN.md)** - Quick start guide for running FRU locally and on AWS
- **[`docs/README_INFRA.md`](docs/README_INFRA.md)** - Complete Infrastructure as Code (IaC) documentation for Terraform + Terragrunt deployment with modular architecture, environment management, and security best practices

**Additional Guides:**
- **[`guides/DELTA_SPARK_VS_POSTGRESQL_FULL_STACK.md`](guides/DELTA_SPARK_VS_POSTGRESQL_FULL_STACK.md)** - Detailed comparison and architecture guide for Delta Lake + Spark vs PostgreSQL + pgvector
- **[`guides/MANUAL_DEPLOYMENT_AND_TESTING.md`](guides/MANUAL_DEPLOYMENT_AND_TESTING.md)** - Manual deployment and testing procedures
- **[`guides/PERFORMANCE_BREAKDOWN.md`](guides/PERFORMANCE_BREAKDOWN.md)** - Performance analysis and optimization guide
- **[`guides/aws_setup_guide.md`](guides/aws_setup_guide.md)** - AWS setup and configuration guide
- **[`guides/database_setup_explanation.md`](guides/database_setup_explanation.md)** - Database setup and schema explanation
- **[`guides/deployment_scripts_relationship.md`](guides/deployment_scripts_relationship.md)** - Explanation of deployment scripts and their relationships

**Run & Teardown (unified entrypoint):**
- **`./run.sh help`** – Show usage
- **`./run.sh local nonkube`** – Local Docker Compose (default)
- **`./run.sh local kube`** – Local Kubernetes (minikube/kind)
- **`./run.sh aws nonkube [dev|prod]`** – AWS ECS
- **`./run.sh aws kube [dev|prod]`** – AWS EKS
- **`./teardown.sh local nonkube`** / **`./teardown.sh aws all [env]`** – Teardown

**Sub-projects:** `orchestration/`, `module_app_core/`, `module_infra_basic/`, `module_infra_longterm/`, `module_infra_frontend/`, `module_infra_db/`, `module_infra_spark/`, `module_infra_kubetypes/kube/`, `module_infra_kubetypes/nonkube/`, `module_test_verification/` (each has a README).

---

It demonstrates:

- ✔️ **Enterprise GenAI architecture**
- ✔️ **Separation of offline vs online compute**
- ✔️ **RAG over structured + unstructured data**
- ✔️ **Low-cost inference at scale**
- ✔️ **AWS-native deployment story**
- ✔️ **Infrastructure as Code (Terraform + Terragrunt)** - Production-ready IaC with modular architecture, environment management, and security best practices
- ⭐ **Agent-based query processing** (optional) - Autonomous ReAct agent for complex queries - **See [Section 10](#🤖-10-query-processing-architecture) for detailed architecture**
- ✔️ **Optimized deployment** - Redundant operations eliminated for faster deployments (~15-30s saved)
- ✔️ **Enhanced frontend** - Build version tracking, improved error handling with detailed console logging, configurable resizable panels, and environment-based width configuration

It is designed as a working prototype that demonstrates production-ready GenAI architecture patterns.

---

# 🧠 1. Concept
FRU (**Fridges R Us**) is a **conversational analytics assistant** for fridge sales.

Typical user asks:
> _“What is the overall average customer rating?”_  
> _“How many LG fridges did we sell in Brazil last month?”_  
> _“Which stores consistently get negative delivery feedback?”_

The system produces grounded insights using **real sales + feedback data**, not hallucination.

---

# 🧩 2. Architecture Overview

### 🔵 *The Golden Separation*

> **Spark does batch intelligence.  
> pgvector does interactive intelligence.  
> Claude explains it.**

This separation is a fundamental architectural principle that enables scalable, cost-effective analytics.

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

# 🗂 3. Project Layout

```text
fru-genai-analytics-all/
│
├─ README.md                     # ← This file
├─ docs/
│   ├─ README_RUN.md             # Manual runbook
│   ├─ README_INFRA.md           # Infrastructure as Code docs
│   └─ ...                       # Other docs (teardown, multi-cloud, etc.)
├─ requirements.txt
│
├─ data/
│   ├─ raw/
│   │   └─ fridge_sales_with_rating.csv
│   └─ synthetic/
│       └─ nlq_training_pairs.jsonl
│
├─ sql/
│   └─ schema_pgvector.sql       # Database schema
│
├─ backend/
│   ├─ api/
│   │   └─ app.py                # Flask API with /query and /query-v2 endpoints
│   ├─ etl/
│   │   └─ load_openai_embeddings_to_pgvector.py
│   ├─ llm/
│   │   └─ bedrock_client.py
│   ├─ agents/                   # Agent-based query processing (Enhancement_C)
│   │   ├─ query_agent.py
│   │   ├─ logger.py
│   │   ├─ metrics.py
│   │   ├─ prompts.py
│   │   └─ tools/
│   │       ├─ sql_tool.py
│   │       ├─ semantic_search_tool.py
│   │       └─ sql_generator_tool.py
│   └─ services/
│       ├─ analytics_scheduler.py
│       ├─ save_analytics_to_db.py
│       └─ feature_flags.py
│
├─ frontend/
│   ├─ src/
│   │   ├─ App.tsx
│   │   └─ components/
│   │       ├─ Chat.tsx
│   │       ├─ BatchAnalyticsPanel.tsx
│   │       └─ StatsPanel.tsx
│   └─ package.json
│
├─ spark_jobs/
│   ├─ ingest_delta.py           # CSV → Delta Lake
│   ├─ generate_training_data.py  # NLQ→SQL training pairs
│   └─ run_analytics.py           # Batch analytics
│
├─ run_scripts/                   # Automated setup/deployment scripts
│   ├─ local/                     # Local development
│   ├─ aws/                       # AWS deployments (ECS, EKS, Terraform)
│   │   ├─ common_ecs_eks/        # Shared ECS/EKS scripts
│   │   ├─ bedrock/               # Bedrock model access
│   │   ├─ resource-check/        # AWS resource inventory scripts
│   │   └─ terraform/             # Terraform deployment & teardown
│   └─ common/                    # Shared utilities
│
├─ module_infra_basic/             # Core infra: VPC, Aurora, IAM (Terraform)
├─ module_infra_longterm/          # Long-term: Secrets Manager (Terraform)
├─ module_infra_frontend/          # Frontend: S3 + CloudFront (Terraform)
├─ module_infra_kubetypes/kube/             # EKS + k8s manifests
├─ module_infra_kubetypes/nonkube/         # ECS, ALB, local Docker
│
├─ guides/                        # Additional documentation and guides
│   ├─ DELTA_SPARK_VS_POSTGRESQL_FULL_STACK.md
│   ├─ MANUAL_DEPLOYMENT_AND_TESTING.md
│   ├─ PERFORMANCE_BREAKDOWN.md
│   ├─ aws_setup_guide.md
│   ├─ database_setup_explanation.md
│   └─ deployment_scripts_relationship.md
│
└─ study/
    └─ ARCHITECT_STUDY_GUIDE_DETAILED.md
```

---

# ⚡️ 4. Local Quickstart

For detailed instructions on running FRU locally, see **[`docs/README_RUN.md`](docs/README_RUN.md)**.

**Quick summary:**
- Set up `.env` file with your credentials
- Run **`./run.sh local nonkube`** for one-command setup (or `./run.sh help` for options)
- Access frontend at `http://localhost:5173`

---

# 🔥 5. Analytics with Spark + Delta

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

# 🧠 6. Intelligence Model: OpenAI Embeddings + pgvector

> The beating heart of FRU.

pgvector serves as the **inference-time semantic engine** for FRU. It enables low-latency nearest-neighbor retrieval over embeddings inside a transactional database, complementing Spark + Delta Lake for batch processing.

## 6.1 Overview

FRU separates concerns into three major layers:

- **Spark + Delta Lake** → offline analytics, ETL/ELT, feature & training data generation
- **OpenAI embeddings + PostgreSQL pgvector** → real-time semantic retrieval
- **LLM (Bedrock Claude)** → reasoning and answer generation over structured + retrieved context

> **Key Principle**: Spark does batch intelligence; pgvector does interactive intelligence.

## 6.2 Embedding Generation (Offline Factory)

1. Ingest `data/raw/fridge_sales_with_rating.csv` into a Delta table via Spark.
2. Use an OpenAI embedding model (`text-embedding-3-small`) over `CUSTOMER_FEEDBACK`.
3. Write rows plus embeddings into a Postgres table with pgvector enabled.

The ETL process (`backend/etl/load_openai_embeddings_to_pgvector.py`) handles this offline, generating embeddings for all customer feedback before queries arrive.

## 6.3 pgvector Schema

```sql
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS fru_sales_embeddings (
    id TEXT PRIMARY KEY,
    brand TEXT,
    fridge_model TEXT,
    price NUMERIC,
    sales_date DATE,
    store_name TEXT,
    customer_feedback TEXT,
    feedback_rating INTEGER,
    feedback_sentiment_category TEXT,
    embedding VECTOR(1536)
);

CREATE INDEX IF NOT EXISTS fru_sales_embeddings_ivfflat
ON fru_sales_embeddings
USING ivfflat (embedding vector_cosine_ops)
WITH (lists = 100);
```

The `ivfflat` index enables fast approximate nearest neighbor (ANN) search for semantic similarity queries.

## 6.4 Inference-Time Flow

**Example user question:**
> "Which LG fridge do customers complain the most about delivery problems?"

**High-level flow:**

1. **Classify query** as qualitative (complaints / feedback).
2. **Embed the query text** with the same OpenAI embedding model.
3. **Run pgvector similarity query** with optional relational filters:

```sql
WITH nearest AS (
  SELECT id
  FROM fru_sales_embeddings
  WHERE brand = 'LG'
  ORDER BY embedding <-> $query_vector
  LIMIT 50
)
SELECT fridge_model,
       COUNT(*) AS complaints
FROM fru_sales_embeddings
WHERE id IN (SELECT id FROM nearest)
  AND feedback_sentiment_category = 'Negative'
GROUP BY fridge_model
ORDER BY complaints DESC;
```

4. **Take result rows** and sample `customer_feedback` snippets.
5. **Ask Bedrock Claude** to summarize the findings, using numbers from SQL and context from snippets.

## 6.5 LLM Prompt Pattern

Instead of letting the LLM invent SQL or guess facts, we:

- Generate SQL via templates or a fine-tuned NLQ→SQL model (see Section 10 for agent-based approach).
- Execute SQL against Postgres.
- Feed structured JSON + snippets into the LLM and ask for a concise, grounded answer.

**Prompt structure:**

```text
System:
You are a retail analytics assistant for fridge sales. You receive structured JSON (metrics)
and feedback snippets. Use JSON for numeric facts; use snippets for qualitative context.
Never make up numbers not present in JSON.

User:
{ "question": "...", "structured": {...}, "snippets": [ ... ] }
```

## 6.6 Why pgvector vs Spark SQL?

**Spark + Delta Lake** remains the backbone for:
- large-scale ETL / ELT
- heavy aggregations (e.g. multi-year sales by brand)
- generating NLQ→SQL training data
- building feature tables for models

**pgvector** is the serving-time engine:
- fast similarity search in milliseconds
- transactional semantics
- easy integration with SQL filters and joins

**What if we used Spark SQL for inference instead?**

You could attempt to use Spark SQL directly at inference time, but downsides include:
- **Latency**: Spark is optimized for batch, not per-request chat UX
- **Complexity**: Implementing approximate nearest neighbor search in Spark is non-trivial
- **Cost**: Keeping clusters warm just for interactive queries is more expensive
- **Operational risk**: Ties interactive traffic to batch infrastructure

**Summary:**
> Spark does batch intelligence; pgvector does interactive intelligence.

---

# 🦾 7. Integrating Bedrock Claude

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

# 🏗 8. Full AWS Deployment

For detailed instructions on deploying FRU to AWS, see **[`docs/README_RUN.md`](docs/README_RUN.md)** and **[`docs/README_INFRA.md`](docs/README_INFRA.md)**.

**Quick summary:**
- Set up `.env` file with AWS credentials
- Run **`./run.sh aws nonkube dev`** for complete ECS deployment (or `./run.sh aws kube dev` for EKS)
- Or use `eks-full` for Kubernetes deployment
- Infrastructure is managed via Terraform + Terragrunt (see `docs/README_INFRA.md`)

---

# 🛡 9. Governance & Safety

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

---

# 🤖 10. Query Processing Architecture

<div align="center">

**⭐ FEATURED ARCHITECTURE ⭐**

</div>

> **🎯 Key Innovation**: FRU's query processing has evolved from a simple keyword-based system to an **autonomous agent-based system** using the ReAct pattern. This section describes the complete evolution path (Current → Enhancement_A → Enhancement_B → Enhancement_C) and the implementation details of the agent-based system that enables intelligent, multi-step query processing.

**What makes this special:**
- 🤖 **Autonomous Planning**: LLM decides the analysis approach dynamically
- 🔧 **Tool-Based Architecture**: Modular tools (SQL, semantic search, SQL generation)
- 🔄 **Iterative Refinement**: Agent can iterate and refine based on results
- 📊 **Production-Ready**: Feature flags, metrics, logging, and gradual rollout support

---

FRU's query processing has evolved from a simple keyword-based system to an intelligent, agent-based autonomous system. This section describes the current implementation and the evolution path.

## 10.1 Current Implementation

### Architecture
- **Classification**: Simple keyword-based (`is_qualitative()` function)
- **Query Processing**: Single path - pgvector semantic search only
- **Limitations**:
  - All queries default to semantic search over feedback data
  - Quantitative queries (e.g., "which region has biggest sales?") perform poorly
  - No SQL generation capability
  - Fixed execution path

### Flow
```
User Query → Keyword Check → pgvector Search → Stats → Claude Explanation
```

**Example Problem:**
Query: "Which region has the biggest sales?"
- Current: Searches feedback semantically, returns 50 records
- Problem: Doesn't aggregate all sales data, only samples
- Result: Inaccurate or incomplete answer

## 10.2 Evolution Path: Enhancement_A → B → C

### Enhancement_A: LLM Classification + SQL Generation

**What It Adds:**
- **LLM-based classification**: Claude/Bedrock classifies queries as `quantitative`, `qualitative`, or `hybrid`
- **SQL generation**: LLM generates SQL from natural language for quantitative queries
- **Dual execution paths**: Different handling for quantitative vs qualitative queries

**Architecture:**
```
User Query → LLM Classify → Route Decision
                │
    ┌───────────┴───────────┐
    │                       │
Quantitative          Qualitative
    │                       │
LLM Generate SQL    pgvector Search
    │                       │
Execute SQL         Claude Explain
    │                       │
Claude Explain      Return Answer
    │
Return Answer
```

**Benefits:**
- Accurate quantitative queries: SQL aggregations over full dataset
- Maintains qualitative strength: Still uses pgvector for feedback queries
- Schema-aware: LLM receives table structure for accurate SQL generation

### Enhancement_B: Hybrid Query Processing

**What It Adds:**
- **Two-phase execution**: Quantitative analysis first, then qualitative analysis filtered by results
- **Result fusion**: Combines quantitative metrics with qualitative insights
- **Coordinated execution**: SQL results guide semantic search

**Architecture:**
```
User Query → Classify as "hybrid"
    │
    ├─ Phase 1: Quantitative
    │   └─ Generate & Execute SQL → Get low-sales stores
    │
    ├─ Phase 2: Qualitative (Filtered)
    │   └─ Semantic Search (filtered by SQL results) → Get feedback
    │
    └─ Phase 3: Synthesis
        └─ Claude combines both → Generate recommendations
```

**Example:**
Query: "How to improve sales where sales were low?"
1. **Phase 1**: SQL finds stores with below-average sales → ["Store A", "Store B"]
2. **Phase 2**: Semantic search for feedback ONLY from Store A and Store B
3. **Phase 3**: Claude synthesizes recommendations based on both quantitative and qualitative findings

### Enhancement_C: Agent-Based Autonomous Planning (Implemented)

**What It Adds:**
- **Autonomous planning**: LLM decides what analysis is needed
- **Tool-based execution**: Agent uses tools (SQL, semantic search, SQL generation)
- **Iterative refinement**: Agent can iterate multiple times based on results
- **Dynamic adaptation**: Adapts to novel queries without fixed patterns

**Architecture:**
```
User Query → Agent Planning
    │
    ├─ Agent thinks: "What do I need?"
    │   └─ Plans tool sequence
    │
    ├─ Execute Tool 1 (e.g., SQL)
    │   └─ Agent observes results
    │
    ├─ Agent decides: "Do I need more?"
    │   └─ If yes → Execute Tool 2 (e.g., Semantic Search)
    │
    └─ Agent synthesizes final answer
```

**Available Tools:**
1. **`execute_sql`**: Run SQL queries directly
2. **`semantic_search`**: pgvector search with optional filters
3. **`generate_sql`**: LLM generates SQL from natural language

**Benefits:**
- **Autonomous**: LLM decides approach, not hardcoded logic
- **Flexible**: Adapts to novel query patterns
- **Iterative**: Can refine based on intermediate results
- **Extensible**: Easy to add new tools

## 10.3 Agent-Based System (Enhancement_C) - Implementation

### Components

1. **Tools** (`backend/agents/tools/`)
   - `SQLTool`: Execute SQL queries safely
   - `SemanticSearchTool`: pgvector semantic search with filters
   - `SQLGeneratorTool`: LLM generates SQL from natural language

2. **Agent** (`backend/agents/query_agent.py`)
   - ReAct pattern implementation
   - Autonomous planning and execution
   - Iterative refinement (max 5 iterations)

3. **Logging** (`backend/agents/logger.py`)
   - Structured logging for debugging
   - Tool call tracking
   - Reasoning traces

4. **Metrics** (`backend/agents/metrics.py`)
   - Performance tracking
   - Success/failure rates
   - Latency monitoring

5. **API Integration** (`backend/api/app.py`)
   - `/query-v2` endpoint (agent-based)
   - `/metrics/agent` endpoint
   - Feature flag: `USE_AGENT_QUERY`

### Usage

**Enable Agent:**
Set environment variable:
```bash
USE_AGENT_QUERY=true
```

**API Endpoints:**

**Agent Query:**
```bash
curl -X POST http://localhost:5000/query-v2 \
  -H "Content-Type: application/json" \
  -d '{"query": "Which region has the biggest sales?"}'
```

**Metrics:**
```bash
curl http://localhost:5000/metrics/agent
```

### Feature Flags

- `USE_AGENT_QUERY`: Master switch (default: false)
- `USE_AGENT_QUERY_PERCENTAGE`: Gradual rollout percentage (0-100)
- `USE_AGENT_QUERY_WHITELIST`: Comma-separated user IDs for testing

### Debugging

When `FLASK_DEBUG=true`, the `/query-v2` response includes:
- `debug_info`: Complete execution trace
- `tool_calls`: All tool executions with inputs/outputs
- `agent_thoughts`: Agent reasoning

### Performance Considerations

**Latency:**
- **Current**: ~500-800ms (single pgvector search)
- **Enhancement_A**: ~800-1200ms (LLM classification + SQL generation)
- **Enhancement_B**: ~1200-2000ms (two-phase execution)
- **Enhancement_C**: ~1500-3000ms (multiple tool calls, iterations)

**Cost:**
- **Current**: OpenAI embeddings + Bedrock (1 call)
- **Enhancement_A**: +1 Bedrock call (classification/SQL generation)
- **Enhancement_B**: +1 Bedrock call (synthesis)
- **Enhancement_C**: +2-5 Bedrock calls (planning + tool calls + synthesis)

**Optimization Strategies:**
- Cache common SQL queries
- Batch tool executions when possible
- Use Claude Haiku for planning, Sonnet for synthesis
- Limit agent iterations (max 5 steps)

### Migration Path

1. **Phase 1**: Test with feature flag disabled (default)
2. **Phase 2**: Enable for specific users (whitelist)
3. **Phase 3**: Gradual rollout (percentage)
4. **Phase 4**: Full rollout (if metrics are good)

### Rollback

Set `USE_AGENT_QUERY=false` to disable agent and fall back to original `/query` endpoint.

---

# 📌 11. Next Steps (Roadmap)

- ✅ **React UI** - Already implemented with Chat interface, Batch Analytics Panel, and Query Stats
  - Configurable panel widths via environment variables (`VITE_FRONTEND_EXEC_LOG_PANEL_WIDTH_PERCENT`, `VITE_FRONTEND_BATCH_ANALYTIC_PANEL_WIDTH_PERCENT`)
  - Mouse-adjustable panel boundaries (resets to env vars on page reload)
  - Enhanced error handling with detailed console logging
- ✅ **Agent-based query processing** - Implemented (Enhancement_C) with ReAct pattern
- ✅ **Batch analytics integration** - Spark analytics scheduled and displayed in UI
- **Future enhancements:**
  - Fine-tune NLQ→SQL model using the training dataset (`data/synthetic/nlq_training_pairs.jsonl`)
  - LoRA training script (SageMaker or local) for a small NLQ→SQL model
  - Canary deployments for new models
  - Evaluation harness: "Golden questions" + acceptance thresholds
  - Enhanced agent tools (e.g., data visualization, report generation)

---

# 🙌 Summary

FRU is a **real playground** for experimenting with Spark, Delta, OpenAI embeddings, pgvector, and Bedrock. It demonstrates production-ready GenAI architecture patterns with:

- architectural judgment  
- cost awareness  
- governance thinking  
- practical GenAI patterns  
- ability to ship a working prototype

Use it, extend it, and explore RAG, embeddings, and hybrid AWS + LLM architectures.
