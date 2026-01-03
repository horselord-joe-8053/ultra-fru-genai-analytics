import os
import json
import logging
from typing import List, Dict, Any, Optional, Tuple
from decimal import Decimal
from datetime import datetime, date, timezone

from flask import Flask, request, jsonify
from flask_cors import CORS
import psycopg2
from psycopg2 import pool
from psycopg2 import Error as Psycopg2Error
from psycopg2.extras import RealDictCursor
from openai import OpenAI
from openai import APIError as OpenAIError

from backend.llm.bedrock_client import claude_complete, get_bedrock_client
from backend.services.analytics_scheduler import start_analytics_scheduler
from backend.utils.env_helpers import get_required_env, get_optional_env, get_optional_bool_env, get_optional_int_env, get_required_int_env

# Feature flag for agent-based query processing
# Single source of truth: .env file (USE_AGENT_QUERY=true/false)
# Default: True (enabled by default, but should be set in .env)
USE_AGENT_QUERY = get_optional_bool_env('USE_AGENT_QUERY', True)

# Agent will be initialized after DB pool is ready
query_agent = None

def init_agent():
    """Initialize agent if feature flag is enabled."""
    global query_agent
    if USE_AGENT_QUERY and _connection_pool is not None:
        try:
            from backend.agents.query_agent import QueryAgent
            from openai import OpenAI as OpenAIClient
            
            # Initialize OpenAI client for embeddings
            openai_api_key = get_required_env("OPENAI_API_KEY", "OpenAI API key for embeddings")
            
            openai_client = OpenAIClient(api_key=openai_api_key)
            
            query_agent = QueryAgent(
                db_pool=_connection_pool,
                bedrock_client=get_bedrock_client(),
                openai_client=openai_client
            )
            app.logger.info("Agent-based query processing enabled")
        except Exception as e:
            app.logger.error(f"Failed to initialize agent: {e}", exc_info=True)
            query_agent = None

# Configure logging
logging.basicConfig(
    level=get_required_env("LOG_LEVEL", "Logging level (e.g., INFO, DEBUG, WARNING)").upper(),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
app = Flask(__name__)
app.logger = logging.getLogger(__name__)

# Configure CORS
allowed_origins = get_required_env("ALLOWED_ORIGINS", "Comma-separated list of allowed CORS origins").split(",")
CORS(app, resources={
    r"/query": {"origins": allowed_origins},
    r"/query-v2": {"origins": allowed_origins},
    r"/analytics": {"origins": allowed_origins},
    r"/metrics/agent": {"origins": allowed_origins},
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
                host=get_required_env("PGHOST", "Database host"),
                port=get_optional_int_env("PGPORT", 5432),
                user=get_required_env("PGUSER", "Database username"),
                password=get_required_env("PGPASSWORD", "Database password"),
                dbname=get_required_env("PGDATABASE", "Database name"),
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
        init_agent()
    
    # Try to get connection from pool
    if _connection_pool:
        try:
            return _connection_pool.getconn()
        except Exception as e:
            app.logger.warning(f"Failed to get connection from pool: {e}, creating new connection")
    
    # Fallback to direct connection
    try:
        conn = psycopg2.connect(
            host=get_required_env("PGHOST", "Database host"),
            port=get_optional_int_env("PGPORT", 5432),
            user=get_required_env("PGUSER", "Database username"),
            password=get_required_env("PGPASSWORD", "Database password"),
            dbname=get_required_env("PGDATABASE", "Database name"),
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
        model = get_required_env("OPENAI_EMBED_MODEL", "OpenAI embedding model (e.g., text-embedding-3-small)")
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
        "customer_feedback, feedback_rating, feedback_sentiment_category "
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
) -> str:
    payload = {
        "question": question,
        "sample_records": [_json_safe(r) for r in rows[:10]],
    }
    return json.dumps(payload, ensure_ascii=False)

# Trying to ensure agent is initialized
def ensure_agent():
    if _connection_pool is None:
        init_db_pool()
    if query_agent is None:
        init_agent()

# ---------- Flask routes ----------

@app.route("/analytics", methods=["GET"])
def get_analytics():
    """Get latest batch analytics results from PostgreSQL."""
    import uuid
    request_id = str(uuid.uuid4())[:8]
    app.logger.info(f"[{request_id}] Analytics request received")
    
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
                    app.logger.warning(f"[{request_id}] No analytics data available")
                    # Return 200 (not 404) to avoid CloudFront custom error responses
                    # that would serve frontend HTML instead of JSON
                    return jsonify({
                        "error": "No analytics data available yet. Analytics will be available after the first batch run.",
                        "request_id": request_id
                    }), 200
                
                # Convert to dict and format
                result = dict(row)
                # Ensure timestamp is UTC and includes 'Z' suffix for JavaScript to parse correctly
                if result["created_at"]:
                    # PostgreSQL returns timezone-aware datetime, ensure it's UTC
                    if result["created_at"].tzinfo is None:
                        # If naive datetime, assume it's UTC
                        result["created_at"] = result["created_at"].replace(tzinfo=timezone.utc)
                    else:
                        # Convert to UTC if it has timezone info
                        result["created_at"] = result["created_at"].astimezone(timezone.utc)
                    # Format with 'Z' suffix to indicate UTC
                    result["last_updated_at"] = result["created_at"].isoformat().replace('+00:00', 'Z')
                else:
                    result["last_updated_at"] = None
                
                # Parse JSONB fields (they come as strings or dicts depending on psycopg2 version)
                for field in ["sales_by_brand", "store_performance", "feedback_analysis", "top_models", "price_stats"]:
                    if isinstance(result[field], str):
                        try:
                            result[field] = json.loads(result[field])
                        except:
                            pass
                
                app.logger.info(f"[{request_id}] Analytics data returned successfully")
                return jsonify(result)
        finally:
            return_db_conn(conn)
            
    except Psycopg2Error as e:
        app.logger.error(f"[{request_id}] Database error: {e}")
        return jsonify({"error": "Database error", "request_id": request_id}), 500
    except Exception as e:
        app.logger.error(f"[{request_id}] Unexpected error: {e}", exc_info=True)
        return jsonify({"error": "Internal server error", "request_id": request_id}), 500


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
    try:
        get_required_env("OPENAI_API_KEY")
        status["openai"] = "configured"
    except ValueError:
        status["openai"] = "not_configured"
    
    # Check AWS credentials
    try:
        import boto3
        boto3.Session().get_credentials()
        status["aws"] = "configured"
    except Exception:
        status["aws"] = "not_configured"
    
    return jsonify(status)


@app.route("/query-v2", methods=["POST"])
def query_v2():
    """New agent-based query endpoint."""
    
    # Trying to ensure agent is initialized
    global query_agent
    if USE_AGENT_QUERY and query_agent is None:
        ensure_agent()
    
    if not USE_AGENT_QUERY or query_agent is None:
        return jsonify({
            "error": "Agent-based query processing is disabled",
            "use_endpoint": "/query",
            "message": "Set USE_AGENT_QUERY=true to enable"
        }), 404
    
    try:
        body = request.get_json(silent=True) or {}
        question = body.get("query") or body.get("q") or ""
        
        # Validate input
        is_valid, error_msg = validate_query(question)
        if not is_valid:
            app.logger.warning(f"Invalid query: {error_msg}")
            return jsonify({"error": error_msg}), 400
        
        # Process with agent
        result = query_agent.process_query(question)
        
        # Build response
        response = {
            "question": question,
            "answer": result.get("answer", ""),
            "method": result.get("method", "agentic"),
            "iterations": result.get("iterations", 0),
            "execution_time_ms": result.get("execution_time_ms", 0),
        }
        
        # Add debug info if in debug mode
        if app.debug:
            response["debug_info"] = result.get("debug_info")
            response["tool_calls"] = result.get("tool_calls", [])
        
        return jsonify(response)
    
    except Exception as e:
        app.logger.error(f"Agent query error: {e}", exc_info=True)
        return jsonify({"error": "Failed to process query with agent"}), 500


@app.route("/metrics/agent", methods=["GET"])
def agent_metrics_endpoint():
    """Get agent performance metrics."""
    if not USE_AGENT_QUERY:
        return jsonify({"error": "Agent not enabled"}), 404
    
    try:
        from backend.agents.metrics import agent_metrics
        return jsonify(agent_metrics.get_stats())
    except Exception as e:
        app.logger.error(f"Failed to get agent metrics: {e}")
        return jsonify({"error": "Failed to retrieve metrics"}), 500


@app.route("/query", methods=["POST"])
def query():
    """Main query endpoint - uses agent if available, falls back to simple method."""
    import uuid
    request_id = str(uuid.uuid4())[:8]
    
    try:
        body = request.get_json(silent=True) or {}
        question = body.get("query") or body.get("q") or ""
        
        app.logger.info(f"[{request_id}] Received query: '{question}'")
        
        # Validate input
        is_valid, error_msg = validate_query(question)
        if not is_valid:
            app.logger.warning(f"[{request_id}] Invalid query: {error_msg}")
            return jsonify({"error": error_msg}), 400
        
        # Try agent first (if enabled)
        app.logger.debug(f"[{request_id}] USE_AGENT_QUERY={USE_AGENT_QUERY}, query_agent is None={query_agent is None}")
        if USE_AGENT_QUERY and query_agent is not None:
            app.logger.info(f"[{request_id}] ===== AGENT PROCESSING START =====")
            app.logger.info(f"[{request_id}] Query: '{question}'")
            app.logger.info(f"[{request_id}] Using agent-based processing")
            try:
                result = query_agent.process_query(question)
                
                # Build response compatible with existing frontend
                response = {
                    "question": question,
                    "answer": result.get("answer", ""),
                    "method": "agentic",
                    "mode": "agentic",  # For compatibility
                    "iterations": result.get("iterations", 0),
                    "execution_time_ms": result.get("execution_time_ms", 0),
                    "request_id": request_id,
                    "token_usage": result.get("token_usage", {})  # Include token usage
                }
                
                # Always include tool_calls (needed for test result extraction)
                response["tool_calls"] = result.get("tool_calls", [])
                # Add metadata for validation (data availability, result type, row count)
                if "data_available" in result:
                    response["data_available"] = result.get("data_available")
                if "primary_result_type" in result:
                    response["primary_result_type"] = result.get("primary_result_type")
                if "primary_result_row_count" in result:
                    response["primary_result_row_count"] = result.get("primary_result_row_count")
                # Add debug info if available
                if app.debug or app.logger.level <= logging.DEBUG:
                    response["debug_info"] = result.get("debug_info")
                
                app.logger.info(f"[{request_id}] ===== AGENT PROCESSING COMPLETE =====")
                app.logger.info(f"[{request_id}] Method: {response.get('method')}, Iterations: {response.get('iterations')}, Time: {response.get('execution_time_ms', 0):.2f}ms")
                app.logger.info(f"[{request_id}] Answer length: {len(response.get('answer', ''))} chars")
                if response.get('tool_calls'):
                    app.logger.info(f"[{request_id}] Tool calls: {len(response.get('tool_calls'))}")
                    for i, tool_call in enumerate(response.get('tool_calls', []), 1):
                        app.logger.info(f"[{request_id}]   Tool {i}: {tool_call.get('tool')} - Success: {tool_call.get('output', {}).get('success', False)}")
                app.logger.info(f"[{request_id}] Agent processing completed successfully")
                
                # Future Improvement: Implement async query pattern using Redis job status store for queries exceeding 45s.
                # This handles queries >60s (CloudFront max timeout) while maintaining CloudFront benefits (HTTPS, single domain, security).
                # 
                # Implementation pattern:
                # 1. POST /query → Check if query estimated >45s → If yes: create job_id, store status="pending" in Redis, return {job_id, status="processing"}, start async processing
                # 2. Async worker: Update Redis status="processing" → Process query → Store status="completed" with full result in Redis (key="job:{job_id}", TTL=3600s)
                # 3. GET /query/status/{job_id} → Return current status from Redis (pending/processing/completed/failed)
                # 4. GET /query/result/{job_id} → Return full result when status="completed" (or error when status="failed")
                # 5. Frontend: Poll /query/status/{job_id} every 3s until completed, then fetch /query/result/{job_id}
                #
                # Redis structure: key="job:{job_id}", value=JSON({status, query, result, created_at, started_at, completed_at, error}), TTL=3600s
                # Use Redis SETEX for atomic set-with-TTL. Use threading.Thread or Celery for async processing.
                # For queries <45s, keep current synchronous pattern for simplicity.
                
                return jsonify(response)
                
            except Exception as e:
                app.logger.error(f"[{request_id}] Agent processing failed: {e}", exc_info=True)
                # Fall through to simple method as fallback
        
        # Fallback to simple method (existing logic)
        if USE_AGENT_QUERY and query_agent is None:
            app.logger.warning(f"[{request_id}] Agent is enabled but not initialized. Attempting to initialize...")
            ensure_agent()
            if query_agent is not None:
                app.logger.info(f"[{request_id}] Agent initialized, retrying with agent...")
                # Retry with agent
                try:
                    result = query_agent.process_query(question)
                    response = {
                        "question": question,
                        "answer": result.get("answer", ""),
                        "method": "agentic",
                        "mode": "agentic",
                        "stats": result.get("stats", {}),  # Extract stats from agent result
                        "sample_records": result.get("sample_records", []),  # Extract sample records from agent result
                        "iterations": result.get("iterations", 0),
                        "execution_time_ms": result.get("execution_time_ms", 0),
                        "request_id": request_id
                    }
                    if app.debug or app.logger.level <= logging.DEBUG:
                        response["debug_info"] = result.get("debug_info")
                        response["tool_calls"] = result.get("tool_calls", [])
                    app.logger.info(f"[{request_id}] Agent processing completed successfully (after retry)")
                    return jsonify(response)
                except Exception as e:
                    app.logger.error(f"[{request_id}] Agent processing failed after retry: {e}", exc_info=True)
        
        app.logger.info(f"[{request_id}] Using simple processing (agent not available)")
        
        qualitative = is_qualitative(question)
        
        # 1) Retrieve rows via pgvector
        try:
            rows = pgvector_search_feedback(question, limit=50)
        except ValueError as e:
            app.logger.error(f"[{request_id}] Database search error: {e}")
            return jsonify({"error": "Failed to search database"}), 500
        except Exception as e:
            app.logger.error(f"[{request_id}] Unexpected error in vector search: {e}")
            return jsonify({"error": "Internal server error during search"}), 500
        
        app.logger.info(f"[{request_id}] Found {len(rows)} matching records")
        
        # 2) Build payload for Claude
        system_prompt = build_claude_system_prompt()
        user_payload = build_claude_user_payload(question, rows)
        
        app.logger.debug(f"[{request_id}] Sending to Claude: {user_payload[:200]}...")
        
        # 3) Call Claude via Bedrock
        try:
            answer_result = claude_complete(system_prompt, user_payload)
            
            # Handle both dict (new format) and str (backward compatibility)
            if isinstance(answer_result, dict):
                answer_text = answer_result.get("text", "")
                tokens = answer_result.get("tokens", {})
                if tokens.get("total", 0) > 0:
                    app.logger.info(f"[{request_id}] Token usage: input={tokens.get('input', 0)}, output={tokens.get('output', 0)}, total={tokens.get('total', 0)}")
            else:
                answer_text = answer_result
                tokens = {}
            
            app.logger.info(f"[{request_id}] Claude response received ({len(answer_text)} chars)")
        except ValueError as e:
            app.logger.error(f"[{request_id}] Bedrock error: {e}")
            return jsonify({"error": "Failed to generate answer from AI service"}), 500
        except Exception as e:
            app.logger.error(f"[{request_id}] Unexpected error in Bedrock call: {e}")
            return jsonify({"error": "Internal server error during AI processing"}), 500
        
        response = {
            "question": question,
            "mode": "qualitative" if qualitative else "mixed",
            "answer": answer_text,
            "request_id": request_id,
            "token_usage": {
                "input_tokens": tokens.get("input", 0),
                "output_tokens": tokens.get("output", 0),
                "total_tokens": tokens.get("total", 0)
            } if tokens else {}
        }
        
        app.logger.info(f"[{request_id}] Query completed successfully")
        return jsonify(response)
    
    except Exception as e:
        app.logger.error(f"[{request_id}] Unexpected error in /query endpoint: {e}", exc_info=True)
        return jsonify({"error": "Internal server error"}), 500


if __name__ == "__main__":
    # Initialize connection pool on startup
    init_db_pool()

    init_agent()
    
    # Start analytics scheduler (if enabled)
    enable_scheduler = get_optional_bool_env("ENABLE_ANALYTICS_SCHEDULER", False)
    
    if enable_scheduler:
        try:
            scheduler_interval_seconds = get_required_int_env(
                "ANALYTICS_SCHEDULER_INTERVAL_SECONDS",
                "Analytics scheduler interval in seconds (required when ENABLE_ANALYTICS_SCHEDULER=true)"
            )
            scheduler = start_analytics_scheduler(interval_seconds=scheduler_interval_seconds)
            app.logger.info(f"Analytics scheduler enabled (runs every {scheduler_interval_seconds} seconds)")
        except Exception as e:
            app.logger.warning(f"Failed to start analytics scheduler: {e}. Analytics will not run automatically.")
    else:
        app.logger.info("Analytics scheduler disabled. Set ENABLE_ANALYTICS_SCHEDULER=true to enable.")
    
    app.logger.info("Starting FRU API server...")
    app.run(host="0.0.0.0", port=5000)
