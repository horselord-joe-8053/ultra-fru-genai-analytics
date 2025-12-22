CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS fru_sales_embeddings (
    id TEXT PRIMARY KEY,
    customer_id TEXT,
    brand TEXT,
    fridge_model TEXT,
    capacity_liters NUMERIC,
    price NUMERIC,
    sales_date DATE,
    store_name TEXT,
    store_address TEXT,
    customer_feedback TEXT,
    feedback_rating TEXT,
    embedding VECTOR(1536)
);

CREATE INDEX IF NOT EXISTS fru_sales_embeddings_ivfflat
ON fru_sales_embeddings
USING ivfflat (embedding vector_cosine_ops)
WITH (lists = 100);

-- Indexes for fast lookups on new columns
CREATE INDEX IF NOT EXISTS fru_sales_embeddings_customer_id_idx 
ON fru_sales_embeddings(customer_id);

CREATE INDEX IF NOT EXISTS fru_sales_embeddings_store_address_idx 
ON fru_sales_embeddings(store_address);

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

-- Migration: Add missing columns to existing tables (idempotent)
-- These columns are now in CREATE TABLE above, but this ensures existing tables get them too
ALTER TABLE fru_sales_embeddings 
ADD COLUMN IF NOT EXISTS customer_id TEXT,
ADD COLUMN IF NOT EXISTS capacity_liters NUMERIC,
ADD COLUMN IF NOT EXISTS store_address TEXT;

-- Create indexes for new columns (idempotent)
CREATE INDEX IF NOT EXISTS fru_sales_embeddings_customer_id_idx 
ON fru_sales_embeddings(customer_id);

CREATE INDEX IF NOT EXISTS fru_sales_embeddings_store_address_idx 
ON fru_sales_embeddings(store_address);

