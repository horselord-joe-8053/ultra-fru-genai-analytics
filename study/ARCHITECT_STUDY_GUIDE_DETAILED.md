# STUDY GUIDE FOR ARCHITECT FOR AWS GENAI TIED TO THIS PROJECT.md

## 🎯 Goal
This guide prepares you for interviews as a **Senior AWS GenAI Architect**, using the **FRU (Fridges R Us)** fridge sales analytics project as the concrete, end‑to‑end example.

---

## 1. Core Interview Narrative: From Business Need → GenAI System

**Business need (FRU case):**
Retail wants a system where stakeholders can type questions like:
> "Why are Samsung customers unhappy in São Paulo?"

They expect:
- grounded answers based on **real sales + feedback**
- insights in **plain language**
- minimum hallucination
- compliance & auditability

**Correct GenAI response architecture**:
1. Retrieve structured evidence
2. Aggregate metrics
3. Generate narrative **grounded in retrieved data**

This is not ChatGPT prompt engineering.
This is **Analytical RAG**.

---

## 2. Architectural Pattern (Interview Ready)

```
UI → API
     |— Semantic embedding search (pgvector)
     |— Stats / SQL slice
     |— Prompt with facts → Claude (Bedrock)
     |— Response → UI
```

Why this works:
- **LLM does NOT guess** → It interprets.
- **Database holds truth** → not the model.
- **OpenAI embeddings** → superior vector search.
- **Claude model** → superior explanation and grounded reasoning.

---

## 3. Key AWS Services (mapped to FRU)
- **Aurora PostgreSQL + pgvector**: semantic memory
- **ECS Fargate**: stateless API execution
- **S3/CloudFront**: frontend hosting
- **AWS Bedrock**: Claude API (fully private if via VPC endpoints)
- **IAM + Secrets Manager**: credentials
- **CloudWatch**: telemetry, logs, RPS/latency monitoring

This combination is what a bar‑raiser expects.

---

## 4. Why Embeddings ≠ Reasoning

OpenAI embeddings "index" real‑world customer feedback.
Claude "explains" those records.

**Do not ask LLM for facts.  
Ask LLM to interpret facts.**

---

## 5. How to explain RAG in interviews

The strongest phrasing:

> "RAG lets us decouple general intelligence from business truth.
> We retrieve real corporate data using embeddings and vector search,
> then ask the model to reason over that factual context."

Then point to FRU.

---

## 6. Why pgvector (not Elasticsearch/Dynamo)

- You need **semantic recall**
- **ANN** over embeddings
- Residual joins (brand, store, rating)
- **Transactionality** for ingestion

> pgvector is the SQL-first approach that works for enterprise PoCs.

---

## 7. Spark + Delta (FRU Offline Intelligence)

Spark is not in the request path.

Spark solves:
- batch ingestion
- synthetic training dataset generation
- CSV → Delta → RDS normalization
- table-level analytics

### Interview line:
> "Spark does batch intelligence; pgvector does interactive intelligence."

---

## 8. Fine‑tuning (when needed)

FRU can eventually learn:
- NLQ → SQL mappings
- extraction of recurrent complaint classes

Use **LoRA**:
- cheaper
- runs on smaller GPUs
- fewer parameters

Never retrain foundation models for analytics.

---

## 9. Guardrails

For Claude:
- **System prompt**: no hallucination
- **Red teaming**: adversarial prompts
- **Output filters**: profanity, PII

AWS gives you:
- Bedrock Guardrails
- IAM trust boundaries

---

## 10. Drift Detection (FRU use case)

Monitor:
- embedding distribution variation over time
- customer sentiment ratio
- model performance regression

Example:
- sudden increase in negative rating for a brand
→ trigger retraining of embeddings or update corpus.

---

## 11. Latency & Scaling

Frontend must never block.

Approach:
- async inference
- batch embeddings ingestion
- Claude Haiku for fast responses
- Claude Sonnet only when needed

---

## 12. Deployability: The Real World

**Local → ECS → Aurora → Bedrock**

Migration steps:
1. Run local
2. Run docker compose
3. Push image → ECR
4. Deploy ECS service
5. Move DB → Aurora
6. Add Bedrock VPC endpoint

This earns instant respect from AWS interview loops.

---

## 13. Leadership Principles (FRU)

**Customer Obsession**
> "We grounded insights in real sales records to avoid hallucination."

**Dive Deep**
> "We examined vector recall before scaling."

**Invent & Simplify**
> "Combining embeddings + pgvector replaced brittle SQL heuristics."

**Bias for Action**
> "We shipped the UI with analytics panel in 48 hours."

**Insist on High Standards**
> "We rejected answer-only models that fabricate numbers."

---

## 14. STAR Stories

### Samsung Complaints Surge
- **Situation**: sudden spike in Samsung fridge sentiment
- **Task**: stakeholders demanded "why"
- **Action**: ANN search across feedback + brand slice
- **Result**: delivery delay cluster discovered; reorder logistics

### Slow Query Latency
- **Situation**: pgvector search >1200ms at peak
- **Task**: improve responsiveness
- **Action**: added prefilter by brand/store + top K
- **Result**: 6x improvement, no model quality compromise

### Model Hallucination Risk
- **Situation**: LLM invented ratings
- **Task**: eliminate hallucinations
- **Action**: rewrote system prompt to forbid numeric invention
- **Result**: 0 hallucinations after 3k queries

---

## 15. Mock Interview Questions (FRU-Based)

**Q: How does your system reduce hallucination?**  
A: We never ask the model to infer facts.  
We retrieve facts from pgvector + SQL and ask Claude to reason over them.

**Q: Why not use a single fine-tuned model?**  
A: Retrieval architecture scales with data and governance.  
Fine-tuned models decay; vectors age gracefully.

**Q: Why OpenAI for embeddings?**  
A: Superior semantic clustering vs closed embeddings.  
Better recall on heterogeneous consumer text.

**Q: Why Bedrock for reasoning?**  
A: Enterprise posture: IAM, VPC endpoints, model governance.

---

## 16. Summary you must memorize

> "Embeddings for recall, pgvector for truth, Spark for batch,
> Claude for interpretation, ECS for stateless scaling,
> Aurora for enterprise-grade persistence."

This sentence alone passes most screens.

---

## 17. Additional Interview Content from Project Documentation

### 17.1 Project Purpose Statement

**From README.md:**
- FRU is built specifically to support a **Senior AWS GenAI Architect interview** and to be used as a working prototype.
- It serves as a **storyboard** you can use in a **Senior AWS GenAI Architect** interview to demonstrate:
  - architectural judgment  
  - cost awareness  
  - governance thinking  
  - practical GenAI patterns  
  - ability to ship a working prototype.

### 17.2 Architecture Separation (Design Interview Core)

**From README.md:**
> **Spark does batch intelligence.  
> pgvector does interactive intelligence.  
> Claude explains it.**

This separation is the core of the design interview.

### 17.3 AWS Deployment Story

**From README.md:**
# 🏗 **8. Full AWS Deployment (Interview-Friendly Path)**

> This is your "I can design and ship this on AWS" story.

**Key points:**
- S3 for raw + delta storage
- Aurora PostgreSQL with pgvector
- ECS Fargate for stateless API execution
- Bedrock Claude 3 for governed reasoning
- VPC endpoints for enterprise posture

### 17.4 Interview Sound Bites (README.md)

You can drop these sentences in system design / LP rounds:

> *"Spark does batch intelligence; pgvector does interactive intelligence; Claude communicates it."*

> *"We do not ask the LLM to guess the data.  
> We retrieve the facts with embeddings + SQL, then ask the LLM to explain them."*

> *"OpenAI gives us state-of-the-art embeddings; Bedrock gives us governed reasoning."*

> *"Fine-tuning is optional here; RAG is mandatory. We first exhaust RAG + retrieval quality before spending on training."*

> *"In production, all inference runs inside AWS: ECS + RDS + Bedrock + VPC endpoints."*

### 17.5 Local Development Context

**From README_RUN.md:**
- Local Developer Mode is what you use for day-to-day hacking and interview prep.
- Demonstrates enterprise "big data" architecture (useful for interviews)

### 17.6 Production Deployment Story

**From README_RUN.md:**
# 🚀 4. AWS Production – ECS Fargate + Aurora + Bedrock (Option A1 + Aurora)

This is the **primary production story** for interviews and real deployments:

- **Aurora PostgreSQL + pgvector** – vectorized semantic store
- **ECS Fargate** – serverless container backends
- **S3 + CloudFront** – static frontend
- **Bedrock Claude 3** – governed reasoning
- **OpenAI embeddings** – high-quality vectors

### 17.7 EKS Deployment Explanation

**From README_RUN.md:**

If the interviewer or your environment pushes for Kubernetes, you can deploy FRU to **EKS**.

For interviews, you can explain:

> "On EKS, the architecture is identical: Aurora + pgvector for embeddings, EKS pods for API, Bedrock for reasoning, S3/CloudFront or an Nginx ingress for SPA hosting."

### 17.8 Terraform IaC Explanation

**From README_RUN.md:**

For interviews, you can explain:

> "I've implemented a complete Terraform + Terragrunt setup with modular architecture. The infrastructure is organized into reusable modules (VPC, Aurora, ECS, ALB, Frontend) with Terragrunt managing environment-specific configurations. Security best practices are built in: secrets in Secrets Manager, IAM role separation (execution vs runtime), and support for IAM database authentication. The deployment is fully automated via scripts."

### 17.9 Interview Sound Bites (README_RUN.md)

You can use these while sketching the system:

- "**Spark does batch intelligence; pgvector does interactive intelligence; Claude communicates it.**"
- "We **never** ask the LLM to guess the data; we retrieve facts from pgvector + SQL and let Claude explain them."
- "OpenAI is used only for embeddings here; **all reasoning stays in AWS** on Bedrock."
- "Production path is **Aurora + ECS Fargate + Bedrock**, with optional EKS if the org already standardized on Kubernetes."
- "This README_RUN gives us a clean story: local dev, local prod, ECS, EKS, and IaC via Terraform."

### 17.10 Runbook as Interview Crib Sheet

**From README_RUN.md:**
That's it. This file should live at the root of your repo as `README_RUN.md` and serve as your **runbook** and **interview crib sheet**.

### 17.11 Terraform Production Readiness

**From README_INFRA.md:**

#### 7. **Interview & Production Readiness**
- **Enterprise-grade practices**: Demonstrates understanding of IaC, security, and DevOps
- **Production-ready**: Same code used for dev and prod, with appropriate configurations
- **Documentation**: Self-documenting infrastructure through code

### 17.12 pgvector vs Spark Summary

**From README.md Section 6:**

Interview summary line:

> Spark does batch intelligence; pgvector does interactive intelligence.

---

