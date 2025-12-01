import os
import time
import pandas as pd
import psycopg2
from psycopg2.extras import execute_batch
from openai import OpenAI

OPENAI_MODEL = os.environ.get("OPENAI_EMBED_MODEL", "text-embedding-3-small")

def get_openai_client() -> OpenAI:
    return OpenAI()  # requires OPENAI_API_KEY in env

def embed_texts(client: OpenAI, texts):
    resp = client.embeddings.create(
        model=OPENAI_MODEL,
        input=texts,
    )
    return [item.embedding for item in resp.data]

def main():
    csv_path = os.environ.get("FRU_CSV_PATH", "data/raw/fridge_sales_with_rating.csv")
    df = pd.read_csv(csv_path)

    required = ["ID","BRAND","FRIDGE_MODEL","PRICE","SALES_DATE","STORE_NAME","CUSTOMER_FEEDBACK","FEEDBACK_RATING"]
    for c in required:
        if c not in df.columns:
            raise RuntimeError(f"Missing required column: {c}")

    conn = psycopg2.connect(
        host=os.environ.get("PGHOST","localhost"),
        port=os.environ.get("PGPORT","5432"),
        user=os.environ.get("PGUSER","postgres"),
        password=os.environ.get("PGPASSWORD","postgres"),
        dbname=os.environ.get("PGDATABASE","fru_db"),
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
                str(r["BRAND"]),
                str(r["FRIDGE_MODEL"]),
                float(r["PRICE"]),
                r["SALES_DATE"],
                str(r["STORE_NAME"]),
                str(r.get("CUSTOMER_FEEDBACK","")),
                str(r.get("FEEDBACK_RATING","")),
                emb,
            ))

        sql = """
        INSERT INTO fru_sales_embeddings
        (id, brand, fridge_model, price, sales_date, store_name, customer_feedback, feedback_rating, embedding)
        VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)
        ON CONFLICT (id) DO UPDATE SET
          brand = EXCLUDED.brand,
          fridge_model = EXCLUDED.fridge_model,
          price = EXCLUDED.price,
          sales_date = EXCLUDED.sales_date,
          store_name = EXCLUDED.store_name,
          customer_feedback = EXCLUDED.customer_feedback,
          feedback_rating = EXCLUDED.feedback_rating,
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