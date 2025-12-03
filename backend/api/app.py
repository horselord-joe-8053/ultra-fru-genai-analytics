import os
import json
import logging
from typing import List, Dict, Any, Optional, Tuple
from decimal import Decimal
from datetime import datetime, date

from flask import Flask, request, jsonify
from flask_cors import CORS
import psycopg2
from psycopg2 import pool
from psycopg2 import Error as Psycopg2Error
from psycopg2.extras import RealDictCursor
from openai import OpenAI
from openai import APIError as OpenAIError

from backend.llm.bedrock_client import claude_complete
from backend.services.analytics_scheduler import start_analytics_scheduler

# Configure logging
logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
app = Flask(__name__)
app.logger = logging.getLogger(__name__)

# Configure CORS
allowed_origins = os.environ.get("ALLOWED_ORIGINS", "*").split(",")
CORS(app, resources={
    r"/query": {"origins": allowed_origins},
    r"/analytics": {"origins": allowed_origins},
    r"/health": {"origins": "*"}
})


# ---------- Infra helpers ----------

# Connection pool for database connections
_connection_pool: Optional[pool.SimpleConnectionPool] = None


def init_db_pool():
    """Initialize database connection pool."""
    global _connection_pool
    if _connection_pool is None:
        try:
            _connection_pool = psycopg2.pool.SimpleConnectionPool(
                1, 20,  # minconn, maxconn
                host=os.environ.get("PGHOST", "localhost"),
                port=int(os.environ.get("PGPORT", "5432")),
                user=os.environ.get("PGUSER", "postgres"),
                password=os.environ.get("PGPASSWORD", "postgres"),
                dbname=os.environ.get("PGDATABASE", "fru_db"),
            )
            app.logger.info("Database connection pool initialized")
        except Exception as e:
            app.logger.error(f"Failed to create connection pool: {e}")
            _connection_pool = None


def get_db_conn():
    """Get a database connection from the pool or create a new one."""
    global _connection_pool
    
    # Initialize pool if not already done
    if _connection_pool is None:
        init_db_pool()
    
    # Try to get connection from pool
    if _connection_pool:
        try:
            return _connection_pool.getconn()
        except Exception as e:
            app.logger.warning(f"Failed to get connection from pool: {e}, creating new connection")
    
    # Fallback to direct connection
    try:
        conn = psycopg2.connect(
            host=os.environ.get("PGHOST", "localhost"),
            port=int(os.environ.get("PGPORT", "5432")),
            user=os.environ.get("PGUSER", "postgres"),
            password=os.environ.get("PGPASSWORD", "postgres"),
            dbname=os.environ.get("PGDATABASE", "fru_db"),
        )
        return conn
    except Psycopg2Error as e:
        app.logger.error(f"Failed to connect to database: {e}")
        raise


def return_db_conn(conn):
    """Return a connection to the pool."""
    global _connection_pool
    if _connection_pool and conn:
        try:
            _connection_pool.putconn(conn)
        except Exception as e:
            app.logger.warning(f"Failed to return connection to pool: {e}")
            conn.close()
    elif conn:
        conn.close()


_openai_client = None


def get_openai_client() -> OpenAI:
    global _openai_client
    if _openai_client is None:
        _openai_client = OpenAI()
    return _openai_client


def embed_text(text: str) -> List[float]:
    """Get an OpenAI embedding for a single text string."""
    try:
        client = get_openai_client()
        model = os.environ.get("OPENAI_EMBED_MODEL", "text-embedding-3-small")
        resp = client.embeddings.create(model=model, input=[text])
        return resp.data[0].embedding
    except OpenAIError as e:
        app.logger.error(f"OpenAI embedding error: {e}")
        raise ValueError(f"Failed to generate embedding: {e}")
    except Exception as e:
        app.logger.error(f"Unexpected error in embed_text: {e}")
        raise ValueError(f"Failed to generate embedding: {e}")


# ---------- Domain helpers ----------

def validate_query(question: str) -> Tuple[bool, Optional[str]]:
    """Validate user query input."""
    if not question or not question.strip():
        return False, "Query cannot be empty"
    
    if len(question) > 1000:
        return False, "Query too long (max 1000 characters)"
    
    # Basic sanitization check (prevent injection attempts)
    dangerous_chars = [';', '--', '/*', '*/', 'DROP', 'DELETE', 'UPDATE', 'INSERT']
    question_upper = question.upper()
    for char in dangerous_chars:
        if char in question_upper:
            app.logger.warning(f"Potentially dangerous query detected: {question[:50]}...")
            # Don't reject, just log - let the database handle it safely
    
    return True, None


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
    """ANN search over fru_sales_embeddings using pgvector."""
    try:
        vec = embed_text(query_text)
    except Exception as e:
        app.logger.error(f"Failed to generate embedding: {e}")
        raise

    sql = (
        "SELECT id, brand, fridge_model, price, sales_date, store_name, "
        "customer_feedback, feedback_rating "
        "FROM fru_sales_embeddings "
        "ORDER BY embedding <-> %s::vector "
        "LIMIT %s;"
    )

    conn = None
    try:
        conn = get_db_conn()
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            # psycopg2 + pgvector accepts Python lists as vector parameters.
            cur.execute(sql, (vec, limit))
            rows = cur.fetchall()
            return [dict(r) for r in rows]
    except Psycopg2Error as e:
        app.logger.error(f"Database query error: {e}")
        raise ValueError(f"Database query failed: {e}")
    except Exception as e:
        app.logger.error(f"Unexpected error in pgvector_search_feedback: {e}")
        raise
    finally:
        if conn:
            return_db_conn(conn)


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

def _json_safe(value: Any) -> Any:
    """Convert value to JSON-serializable form."""
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if isinstance(value, list):
        return [_json_safe(v) for v in value]
    if isinstance(value, dict):
        return {k: _json_safe(v) for k, v in value.items()}
    
    return value

def build_claude_user_payload(
    question: str,
    rows: List[Dict[str, Any]],
    stats: Dict[str, Any],
) -> str:
    payload = {
        "question": question,
        "stats": stats,
        "sample_records": [_json_safe(r) for r in rows[:10]],
    }
    return json.dumps(payload, ensure_ascii=False)


# ---------- Flask routes ----------

@app.route("/analytics", methods=["GET"])
def get_analytics():
    """Get latest batch analytics results from PostgreSQL."""
    try:
        conn = get_db_conn()
        try:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                # Get latest analytics result
                cur.execute("""
                    SELECT 
                        id,
                        created_at,
                        sales_by_brand,
                        store_performance,
                        feedback_analysis,
                        top_models,
                        price_stats,
                        total_records,
                        total_revenue
                    FROM batch_analytics
                    ORDER BY created_at DESC
                    LIMIT 1
                """)
                
                row = cur.fetchone()
                
                if not row:
                    return jsonify({
                        "error": "No analytics data available yet. Analytics will be available after the first batch run."
                    }), 404
                
                # Convert to dict and format
                result = dict(row)
                result["last_updated_at"] = result["created_at"].isoformat() if result["created_at"] else None
                
                # Parse JSONB fields (they come as strings or dicts depending on psycopg2 version)
                for field in ["sales_by_brand", "store_performance", "feedback_analysis", "top_models", "price_stats"]:
                    if isinstance(result[field], str):
                        try:
                            result[field] = json.loads(result[field])
                        except:
                            pass
                
                return jsonify(result)
        finally:
            return_db_conn(conn)
            
    except Psycopg2Error as e:
        app.logger.error(f"Database error in /analytics: {e}")
        return jsonify({"error": "Database error"}), 500
    except Exception as e:
        app.logger.error(f"Unexpected error in /analytics: {e}", exc_info=True)
        return jsonify({"error": "Internal server error"}), 500


@app.route("/health", methods=["GET"])
def health():
    """Health check endpoint with component status."""
    status = {"status": "ok"}
    
    # Check database connection
    try:
        conn = get_db_conn()
        with conn.cursor() as cur:
            cur.execute("SELECT 1;")
        return_db_conn(conn)
        status["database"] = "connected"
    except Exception as e:
        status["database"] = "disconnected"
        status["database_error"] = str(e)
        app.logger.warning(f"Database health check failed: {e}")
        return jsonify(status), 503
    
    # Check OpenAI API key
    if os.environ.get("OPENAI_API_KEY"):
        status["openai"] = "configured"
    else:
        status["openai"] = "not_configured"
    
    # Check AWS credentials
    try:
        import boto3
        boto3.Session().get_credentials()
        status["aws"] = "configured"
    except Exception:
        status["aws"] = "not_configured"
    
    return jsonify(status)


@app.route("/query", methods=["POST"])
def query():
    """Main query endpoint for natural language questions."""
    try:
        body = request.get_json(silent=True) or {}
        question = body.get("query") or body.get("q") or ""

        # Validate input
        is_valid, error_msg = validate_query(question)
        if not is_valid:
            app.logger.warning(f"Invalid query: {error_msg}")
            return jsonify({"error": error_msg}), 400

        qualitative = is_qualitative(question)

        # 1) Retrieve rows via pgvector
        try:
            rows = pgvector_search_feedback(question, limit=50)
        except ValueError as e:
            app.logger.error(f"Database search error: {e}")
            return jsonify({"error": "Failed to search database"}), 500
        except Exception as e:
            app.logger.error(f"Unexpected error in vector search: {e}")
            return jsonify({"error": "Internal server error during search"}), 500

        stats = compute_simple_stats(rows)

        # 2) Build payload for Claude
        system_prompt = build_claude_system_prompt()
        user_payload = build_claude_user_payload(question, rows, stats)

        # 3) Call Claude via Bedrock
        try:
            answer_text = claude_complete(system_prompt, user_payload)
        except ValueError as e:
            app.logger.error(f"Bedrock error: {e}")
            return jsonify({"error": "Failed to generate answer from AI service"}), 500
        except Exception as e:
            app.logger.error(f"Unexpected error in Bedrock call: {e}")
            return jsonify({"error": "Internal server error during AI processing"}), 500

        response = {
            "question": question,
            "mode": "qualitative" if qualitative else "mixed",
            "stats": stats,
            "sample_records": rows[:5],
            "answer": answer_text,
        }
        return jsonify(response)
    
    except Exception as e:
        app.logger.error(f"Unexpected error in /query endpoint: {e}", exc_info=True)
        return jsonify({"error": "Internal server error"}), 500


if __name__ == "__main__":
    # Initialize connection pool on startup
    init_db_pool()
    
    # Start analytics scheduler (if enabled)
    enable_scheduler = os.environ.get("ENABLE_ANALYTICS_SCHEDULER", "false").lower() == "true"
    scheduler_interval = int(os.environ.get("ANALYTICS_SCHEDULER_INTERVAL_MINUTES", "5"))
    
    if enable_scheduler:
        try:
            scheduler = start_analytics_scheduler(interval_minutes=scheduler_interval)
            app.logger.info(f"Analytics scheduler enabled (runs every {scheduler_interval} minutes)")
        except Exception as e:
            app.logger.warning(f"Failed to start analytics scheduler: {e}. Analytics will not run automatically.")
    else:
        app.logger.info("Analytics scheduler disabled. Set ENABLE_ANALYTICS_SCHEDULER=true to enable.")
    
    app.logger.info("Starting FRU API server...")
    app.run(host="0.0.0.0", port=5000)
