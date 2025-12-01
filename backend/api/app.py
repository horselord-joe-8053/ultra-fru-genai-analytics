import os
import json
from typing import List, Dict, Any

from flask import Flask, request, jsonify
import psycopg2
from psycopg2.extras import RealDictCursor
from openai import OpenAI

from backend.llm.bedrock_client import claude_complete


app = Flask(__name__)


# ---------- Infra helpers ----------

def get_db_conn():
    # Create a new Postgres connection using PG* env vars.
    conn = psycopg2.connect(
        host=os.environ.get("PGHOST", "localhost"),
        port=int(os.environ.get("PGPORT", "5432")),
        user=os.environ.get("PGUSER", "postgres"),
        password=os.environ.get("PGPASSWORD", "postgres"),
        dbname=os.environ.get("PGDATABASE", "fru_db"),
    )
    return conn


_openai_client = None


def get_openai_client() -> OpenAI:
    global _openai_client
    if _openai_client is None:
        _openai_client = OpenAI()
    return _openai_client


def embed_text(text: str) -> List[float]:
    # Get an OpenAI embedding for a single text string.
    client = get_openai_client()
    model = os.environ.get("OPENAI_EMBED_MODEL", "text-embedding-3-small")
    resp = client.embeddings.create(model=model, input=[text])
    return resp.data[0].embedding


# ---------- Domain helpers ----------

def is_qualitative(question: str) -> bool:
    q = question.lower()
    qualitative_keywords = [
        "why",
        "complain",
        "complaints",
        "feedback",
        "happy",
        "unhappy",
        "satisfied",
        "dissatisfied",
        "issue",
        "problem",
        "experience",
        "sentiment",
    ]
    quantitative_keywords = [
        "how many",
        "count",
        "total",
        "sum",
        "average",
        "avg",
        "min",
        "max",
        "top",
        "bottom",
        "trend",
    ]
    if any(k in q for k in quantitative_keywords):
        return False
    if any(k in q for k in qualitative_keywords):
        return True
    # Default: treat as qualitative, because that benefits most from pgvector + Claude.
    return True


def pgvector_search_feedback(query_text: str, limit: int = 30) -> List[Dict[str, Any]]:
    # ANN search over fru_sales_embeddings using pgvector.
    vec = embed_text(query_text)

    sql = (
        "SELECT id, brand, fridge_model, price, sales_date, store_name, "
        "customer_feedback, feedback_rating "
        "FROM fru_sales_embeddings "
        "ORDER BY embedding <-> %s "
        "LIMIT %s;"
    )

    conn = get_db_conn()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            # psycopg2 + pgvector accepts Python lists as vector parameters.
            cur.execute(sql, (vec, limit))
            rows = cur.fetchall()
            return [dict(r) for r in rows]
    finally:
        conn.close()


def compute_simple_stats(rows: List[Dict[str, Any]]) -> Dict[str, Any]:
    total = len(rows)
    by_brand: Dict[str, int] = {}
    by_store: Dict[str, int] = {}
    by_rating: Dict[str, int] = {}

    for r in rows:
        brand = (r.get("brand") or "").strip()
        store = (r.get("store_name") or "").strip()
        rating = (r.get("feedback_rating") or "").strip()

        if brand:
            by_brand[brand] = by_brand.get(brand, 0) + 1
        if store:
            by_store[store] = by_store.get(store, 0) + 1
        if rating:
            by_rating[rating] = by_rating.get(rating, 0) + 1

    return {
        "total_matches": total,
        "by_brand": by_brand,
        "by_store": by_store,
        "by_rating": by_rating,
    }


def build_claude_system_prompt() -> str:
    return (
        "You are a retail analytics assistant for fridge sales (project FRU - Friday aRe Us). "
        "You receive structured JSON about sales records and customer feedback. "
        "Your job is to: "
        "- Explain patterns clearly and concisely for business users. "
        "- Use the numbers and facts from JSON as the single source of truth. "
        "- NEVER invent exact numbers, percentages, or rankings that are not in the JSON. "
        "- If the JSON does not contain enough information, say so explicitly and suggest additional data you would need. "
        "- Use a professional but simple tone."
    )


def build_claude_user_payload(
    question: str,
    rows: List[Dict[str, Any]],
    stats: Dict[str, Any],
) -> str:
    payload = {
        "question": question,
        "stats": stats,
        "sample_records": rows[:10],
    }
    return json.dumps(payload, ensure_ascii=False)


# ---------- Flask routes ----------

@app.route("/health", methods=["GET"])
def health():
    return {"status": "ok"}


@app.route("/query", methods=["POST"])
def query():
    body = request.get_json(silent=True) or {}
    question = body.get("query") or body.get("q") or ""

    if not question:
        return jsonify({"error": "Missing 'query' in JSON body"}), 400

    qualitative = is_qualitative(question)

    # 1) Retrieve rows via pgvector
    rows = pgvector_search_feedback(question, limit=50)
    stats = compute_simple_stats(rows)

    # 2) Build payload for Claude
    system_prompt = build_claude_system_prompt()
    user_payload = build_claude_user_payload(question, rows, stats)

    # 3) Call Claude via Bedrock
    answer_text = claude_complete(system_prompt, user_payload)

    response = {
        "question": question,
        "mode": "qualitative" if qualitative else "mixed",
        "stats": stats,
        "sample_records": rows[:5],
        "answer": answer_text,
    }
    return jsonify(response)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
