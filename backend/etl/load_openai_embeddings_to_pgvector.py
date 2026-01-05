#!/usr/bin/env python3
"""
Load CSV data into PostgreSQL with OpenAI embeddings and pgvector support.

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
"""
import os
import time
import pandas as pd
import psycopg2
from psycopg2.extras import execute_batch
from openai import OpenAI
from backend.utils.env_helpers import get_required_env, get_optional_env, get_optional_int_env

OPENAI_MODEL = get_required_env("OPENAI_EMBED_MODEL", "OpenAI embedding model (e.g., text-embedding-3-small)")

def get_openai_client() -> OpenAI:
    return OpenAI()  # requires OPENAI_API_KEY in env

def embed_texts(client: OpenAI, texts):
    resp = client.embeddings.create(
        model=OPENAI_MODEL,
        input=texts,
    )
    return [item.embedding for item in resp.data]

def main():
    csv_path = get_optional_env("FRU_CSV_PATH", "data/raw/fridge_sales_with_rating.csv")
    df = pd.read_csv(csv_path)

    required = ["ID","CUSTOMER_ID","BRAND","FRIDGE_MODEL","CAPACITY_LITERS","PRICE","SALES_DATE","STORE_NAME","STORE_ADDRESS","CUSTOMER_FEEDBACK","FEEDBACK_RATING","FEEDBACK_SENTIMENT_CATEGORY"]
    for c in required:
        if c not in df.columns:
            raise RuntimeError(f"Missing required column: {c}")

    conn = psycopg2.connect(
        host=get_required_env("PGHOST", "Database host"),
        port=get_optional_int_env("PGPORT", 5432),
        user=get_required_env("PGUSER", "Database username"),
        password=get_required_env("PGPASSWORD", "Database password"),
        dbname=get_required_env("PGDATABASE", "Database name"),
    )
    conn.autocommit = True
    cur = conn.cursor()

    client = get_openai_client()
    rows = df.to_dict(orient="records")
    batch_size = 64

    for i in range(0, len(rows), batch_size):
        batch = rows[i:i+batch_size]
        texts = [r.get("CUSTOMER_FEEDBACK") or "" for r in batch]
        embeddings = embed_texts(client, texts)
        payload = []
        for r, emb in zip(batch, embeddings):
            payload.append((
                str(r["ID"]),
                str(r.get("CUSTOMER_ID", "")),
                str(r["BRAND"]),
                str(r["FRIDGE_MODEL"]),
                float(r.get("CAPACITY_LITERS", 0)) if pd.notna(r.get("CAPACITY_LITERS")) else None,
                float(r["PRICE"]),
                r["SALES_DATE"],
                str(r["STORE_NAME"]),
                str(r.get("STORE_ADDRESS", "")),
                str(r.get("CUSTOMER_FEEDBACK","")),
                int(r.get("FEEDBACK_RATING", 0)) if r.get("FEEDBACK_RATING") else None,
                str(r.get("FEEDBACK_SENTIMENT_CATEGORY","")),
                emb,
            ))

        sql = """
        INSERT INTO fru_sales_embeddings
        (id, customer_id, brand, fridge_model, capacity_liters, price, sales_date, store_name, store_address, customer_feedback, feedback_rating, feedback_sentiment_category, embedding)
        VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
        ON CONFLICT (id) DO UPDATE SET
          customer_id = EXCLUDED.customer_id,
          brand = EXCLUDED.brand,
          fridge_model = EXCLUDED.fridge_model,
          capacity_liters = EXCLUDED.capacity_liters,
          price = EXCLUDED.price,
          sales_date = EXCLUDED.sales_date,
          store_name = EXCLUDED.store_name,
          store_address = EXCLUDED.store_address,
          customer_feedback = EXCLUDED.customer_feedback,
          feedback_rating = EXCLUDED.feedback_rating,
          feedback_sentiment_category = EXCLUDED.feedback_sentiment_category,
          embedding = EXCLUDED.embedding;
        """
        execute_batch(cur, sql, payload)
        print(f"Upserted {len(payload)} rows [{i}..{i+len(payload)-1}]")
        time.sleep(0.2)

    cur.close()
    conn.close()
    print("Done.")

if __name__ == "__main__":
    main()