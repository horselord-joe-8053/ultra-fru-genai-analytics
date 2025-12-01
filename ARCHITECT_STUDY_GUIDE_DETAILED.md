# STUDY_GUIDE_DETAILED.md

## 🎯 Goal
This guide prepares you for interviews as a **Senior AWS GenAI Architect**, using the **FRU (Friday aRe Us)** fridge sales analytics project as the concrete, end‑to‑end example.

---

## 1. Core Interview Narrative: From Business Need → GenAI System

**Business need (FRU case):**
Retail wants a system where stakeholders can type questions like:
> “Why are Samsung customers unhappy in São Paulo?”

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

OpenAI embeddings “index” real‑world customer feedback.
Claude “explains" those records.

**Do not ask LLM for facts.  
Ask LLM to interpret facts.**

---

## 5. How to explain RAG in interviews

The strongest phrasing:

> “RAG lets us decouple general intelligence from business truth.
> We retrieve real corporate data using embeddings and vector search,
> then ask the model to reason over that factual context.”

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
> “Spark does batch intelligence; pgvector does interactive intelligence.”

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
> “We grounded insights in real sales records to avoid hallucination.”

**Dive Deep**
> “We examined vector recall before scaling.”

**Invent & Simplify**
> “Combining embeddings + pgvector replaced brittle SQL heuristics.”

**Bias for Action**
> “We shipped the UI with analytics panel in 48 hours.”

**Insist on High Standards**
> “We rejected answer-only models that fabricate numbers.”

---

## 14. STAR Stories

### Samsung Complaints Surge
- **Situation**: sudden spike in Samsung fridge sentiment
- **Task**: stakeholders demanded “why”
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

> “Embeddings for recall, pgvector for truth, Spark for batch,
> Claude for interpretation, ECS for stateless scaling,
> Aurora for enterprise-grade persistence.”

This sentence alone passes most screens.

---

