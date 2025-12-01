# FRU GenAI — pgvector as the Inference-Time Semantic Engine

## 1. Overview

FRU (Friday aRe Us) ingests refrigerator sales and customer feedback data.
We separate concerns into three major layers:

- **Spark + Delta Lake** → offline analytics, ETL/ELT, feature & training data generation
- **OpenAI embeddings + PostgreSQL pgvector** → real-time semantic retrieval
- **LLM (Bedrock Claude)** → reasoning and answer generation over structured + retrieved context

pgvector is not a replacement for data lakes. It is the inference-time semantic engine:
a way to do low-latency nearest-neighbor retrieval over embeddings inside a transactional database.

## 2. Embedding Generation (Offline Factory)

1. Ingest `data/raw/fridge_sales_with_rating.csv` into a Delta table via Spark.
2. Use an OpenAI embedding model (e.g. `text-embedding-3-small`) over `CUSTOMER_FEEDBACK`.
3. Write rows plus embeddings into a Postgres table with pgvector enabled.

## 3. pgvector Schema

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
    feedback_rating TEXT,
    embedding VECTOR(1536)
);

CREATE INDEX IF NOT EXISTS fru_sales_embeddings_ivfflat
ON fru_sales_embeddings
USING ivfflat (embedding vector_cosine_ops)
WITH (lists = 100);
```

## 4. Inference-Time Flow

Example user question:

> Which LG fridge do customers complain the most about delivery problems?

High-level flow:

1. Classify query as qualitative (complaints / feedback).
2. Embed the query text with the same OpenAI embedding model.
3. Run a pgvector similarity query with optional relational filters:

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
  AND feedback_rating = 'Negative'
GROUP BY fridge_model
ORDER BY complaints DESC;
```

4. Take result rows and sample `customer_feedback` snippets.
5. Ask Bedrock Claude to summarise the findings, using numbers from SQL and colour from snippets.

## 5. LLM Prompt Pattern

Instead of letting the LLM invent SQL, we:

- Generate SQL via templates or a fine-tuned NLQ→SQL model.
- Execute SQL against Postgres.
- Feed structured JSON + snippets into the LLM and ask for a concise, grounded answer.

Prompt sketch:

```text
System:
You are a retail analytics assistant for fridge sales. You receive structured JSON (metrics)
and feedback snippets. Use JSON for numeric facts; use snippets for qualitative colour.
Never make up numbers not present in JSON.

User:
{ "question": "...", "structured": {...}, "snippets": [ ... ] }
```

## 6. Spark + Delta vs pgvector

Spark + Delta Lake remain the backbone for:

- large-scale ETL / ELT
- heavy aggregations (e.g. multi-year sales by brand)
- generating NLQ→SQL training data
- building feature tables for models

pgvector is the serving-time engine:

- fast similarity search in milliseconds
- transactional semantics
- easy integration with SQL filters and joins

## 7. What If We Used Spark SQL for Inference Instead?

You could attempt to use Spark SQL directly at inference time:

- LLM generates SQL over Delta tables.
- Spark executes the queries on a cluster.

Downsides:

- Latency: Spark is optimised for batch, not per-request chat UX.
- Complexity: implementing approximate nearest neighbour search in Spark is non-trivial.
- Cost: keeping clusters warm just for interactive queries is more expensive.
- Operational risk: ties interactive traffic to batch infrastructure.

Where Spark still shines:

- offline analytics
- building curated training datasets
- feature engineering for downstream models

Interview summary line:

> Spark does batch intelligence; pgvector does interactive intelligence.
