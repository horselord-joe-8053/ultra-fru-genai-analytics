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
    feedback_rating INTEGER,
    feedback_sentiment_category TEXT,
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
ADD COLUMN IF NOT EXISTS store_address TEXT,
ADD COLUMN IF NOT EXISTS feedback_sentiment_category TEXT;

-- Migration: Change feedback_rating from TEXT to INTEGER (idempotent)
-- This will fail if column doesn't exist or is already INTEGER, so we check first
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'fru_sales_embeddings' 
        AND column_name = 'feedback_rating' 
        AND data_type = 'text'
    ) THEN
        ALTER TABLE fru_sales_embeddings 
        ALTER COLUMN feedback_rating TYPE INTEGER USING feedback_rating::INTEGER;
    END IF;
END $$;

-- Create indexes for new columns (idempotent)
CREATE INDEX IF NOT EXISTS fru_sales_embeddings_customer_id_idx 
ON fru_sales_embeddings(customer_id);

CREATE INDEX IF NOT EXISTS fru_sales_embeddings_store_address_idx 
ON fru_sales_embeddings(store_address);

CREATE INDEX IF NOT EXISTS fru_sales_embeddings_sentiment_category_idx 
ON fru_sales_embeddings(feedback_sentiment_category);

-- Add comments to document these are "man in the loop" labels
COMMENT ON COLUMN fru_sales_embeddings.feedback_rating IS 
  'Human-reviewed numeric satisfaction rating (1-10) assigned to CUSTOMER_FEEDBACK';
COMMENT ON COLUMN fru_sales_embeddings.feedback_sentiment_category IS 
  'Human-reviewed sentiment category (Positive/Neutral/Negative) assigned to CUSTOMER_FEEDBACK';

