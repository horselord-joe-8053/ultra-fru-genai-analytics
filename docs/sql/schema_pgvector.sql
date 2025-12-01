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

-- Batch analytics table (for Spark + Delta analytics results)
CREATE TABLE IF NOT EXISTS batch_analytics (
    id SERIAL PRIMARY KEY,
    created_at TIMESTAMP DEFAULT NOW(),
    sales_by_brand JSONB,
    store_performance JSONB,
    feedback_analysis JSONB,
    top_models JSONB,
    price_stats JSONB,
    total_records INTEGER,
    total_revenue NUMERIC
);

CREATE INDEX IF NOT EXISTS batch_analytics_created_at_idx
ON batch_analytics(created_at DESC);
