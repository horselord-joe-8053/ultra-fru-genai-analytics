# Complete Enhancement & Modification List for FRU Project

## Priority Classification
- 🔴 **CRITICAL** - Blocks functionality or causes errors
- 🟡 **HIGH** - Important for production readiness
- 🟢 **MEDIUM** - Improves quality/maintainability
- 🔵 **LOW** - Nice to have

---

## 1. Documentation Enhancements

### 1.1 README_RUN.md Fixes (🔴 CRITICAL)

#### Missing Prerequisites Section
**Location:** Section 0 (Prerequisites)

**Add:**
```markdown
### Local
- Python 3.10+
- Node.js 18+
- Docker Desktop (or compatible)
- **PostgreSQL client tools** (for `psql` command)
  - macOS: `brew install postgresql@16` or `brew install libpq`
  - Linux: `sudo apt-get install postgresql-client`
  - Windows: Install PostgreSQL or use Docker exec alternative
- **Apache Spark** (optional, for Spark jobs in Section 2.5)
  - Download from https://spark.apache.org/downloads.html
  - Or use Databricks / EMR for cloud execution
- OpenAI API key
- AWS credentials configured (for Bedrock)
- **AWS CLI** (optional, for AWS deployment sections)
  - `brew install awscli` or `pip install awscli`
```

#### Missing Python Dependency Installation
**Location:** Section 2, after 2.1

**Add new Section 2.2:**
```markdown
### 2.2 Install Python Dependencies

Create a virtual environment (recommended):

```bash
python3 -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate
```

Install required packages:

```bash
pip install -r requirements.txt
```

Verify installation:

```bash
python -c "import flask, psycopg2, openai, boto3, pandas; print('✓ All dependencies installed')"
```
```

**Renumber subsequent sections:**
- Current 2.2 → New 2.3
- Current 2.3 → New 2.4
- Current 2.4 → New 2.5
- Current 2.5 → New 2.6

#### Add Docker Alternative for Schema Init
**Location:** Section 2.3 (new 2.4)

**Update to include:**
```markdown
1. Initialize schema:

   Option A (if psql installed locally):
   ```bash
   psql "postgresql://postgres:postgres@localhost:5432/fru_db" -f docs/sql/schema_pgvector.sql
   ```

   Option B (using Docker, if psql not installed):
   ```bash
   docker exec -i fru_db psql -U postgres -d fru_db < docs/sql/schema_pgvector.sql
   ```
```

---

### 1.2 Requirements.txt Enhancements (🟡 HIGH)

#### Add Version Pinning
**Current:**
```
flask
pyspark
delta-spark
boto3
psycopg2-binary
openai
pandas
```

**Recommended:**
```
flask>=2.3.0,<3.0.0
pyspark>=3.4.0
delta-spark>=3.0.0
boto3>=1.28.0
psycopg2-binary>=2.9.0
openai>=1.0.0
pandas>=2.0.0
```

#### Consider Adding Development Dependencies
**Optional additions:**
```
# Development dependencies (optional)
python-dotenv>=1.0.0  # For .env file loading
pytest>=7.4.0  # For testing
black>=23.0.0  # Code formatting
flake8>=6.0.0  # Linting
```

**Or create `requirements-dev.txt`:**
```
-r requirements.txt
python-dotenv>=1.0.0
pytest>=7.4.0
black>=23.0.0
flake8>=6.0.0
```

---

## 2. Code Quality & Error Handling

### 2.1 Backend API Error Handling (🟡 HIGH)

#### Missing Error Handling in `/query` Endpoint
**File:** `backend/api/app.py`

**Current Issues:**
- No try/except around database connections
- No error handling for OpenAI API calls
- No error handling for Bedrock API calls
- Errors will crash the API

**Add:**
```python
@app.route("/query", methods=["POST"])
def query():
    try:
        body = request.get_json(silent=True) or {}
        question = body.get("query") or body.get("q") or ""

        if not question:
            return jsonify({"error": "Missing 'query' in JSON body"}), 400

        qualitative = is_qualitative(question)

        # 1) Retrieve rows via pgvector
        try:
            rows = pgvector_search_feedback(question, limit=50)
        except psycopg2.Error as e:
            app.logger.error(f"Database error: {e}")
            return jsonify({"error": "Database connection failed"}), 500
        
        stats = compute_simple_stats(rows)

        # 2) Build payload for Claude
        system_prompt = build_claude_system_prompt()
        user_payload = build_claude_user_payload(question, rows, stats)

        # 3) Call Claude via Bedrock
        try:
            answer_text = claude_complete(system_prompt, user_payload)
        except Exception as e:
            app.logger.error(f"Bedrock error: {e}")
            return jsonify({"error": "Failed to generate answer"}), 500

        response = {
            "question": question,
            "mode": "qualitative" if qualitative else "mixed",
            "stats": stats,
            "sample_records": rows[:5],
            "answer": answer_text,
        }
        return jsonify(response)
    except Exception as e:
        app.logger.error(f"Unexpected error: {e}")
        return jsonify({"error": "Internal server error"}), 500
```

#### Add Error Handling to Database Functions
**File:** `backend/api/app.py`

**Update `get_db_conn()`:**
```python
def get_db_conn():
    try:
        conn = psycopg2.connect(
            host=os.environ.get("PGHOST", "localhost"),
            port=int(os.environ.get("PGPORT", "5432")),
            user=os.environ.get("PGUSER", "postgres"),
            password=os.environ.get("PGPASSWORD", "postgres"),
            dbname=os.environ.get("PGDATABASE", "fru_db"),
        )
        return conn
    except psycopg2.Error as e:
        app.logger.error(f"Failed to connect to database: {e}")
        raise
```

**Update `pgvector_search_feedback()`:**
```python
def pgvector_search_feedback(query_text: str, limit: int = 30) -> List[Dict[str, Any]]:
    try:
        vec = embed_text(query_text)
    except Exception as e:
        app.logger.error(f"OpenAI embedding error: {e}")
        raise

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
            cur.execute(sql, (vec, limit))
            rows = cur.fetchall()
            return [dict(r) for r in rows]
    except psycopg2.Error as e:
        app.logger.error(f"Database query error: {e}")
        raise
    finally:
        conn.close()
```

---

### 2.2 Bedrock Client Error Handling (🟡 HIGH)

**File:** `backend/llm/bedrock_client.py`

**Current Issues:**
- No error handling for boto3 exceptions
- No error handling for JSON parsing
- No error handling for missing API keys
- No retry logic

**Add:**
```python
import os
import json
import boto3
from botocore.exceptions import ClientError, BotoCoreError
import logging

logger = logging.getLogger(__name__)

def get_bedrock_client():
    region = os.environ.get("AWS_REGION", "us-east-1")
    try:
        return boto3.client("bedrock-runtime", region_name=region)
    except Exception as e:
        logger.error(f"Failed to create Bedrock client: {e}")
        raise

def claude_complete(system_prompt, user_message, model_id=None, max_tokens=800):
    if model_id is None:
        model_id = os.environ.get(
            "BEDROCK_MODEL_ID",
            "anthropic.claude-3-haiku-20240229-v1:0",
        )

    try:
        client = get_bedrock_client()
    except Exception as e:
        logger.error(f"Bedrock client initialization failed: {e}")
        raise ValueError("Failed to initialize Bedrock client")

    body = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": max_tokens,
        "system": system_prompt,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": user_message}
                ],
            }
        ],
    }

    try:
        response = client.invoke_model(
            modelId=model_id,
            body=json.dumps(body),
            accept="application/json",
            contentType="application/json",
        )
    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code", "Unknown")
        logger.error(f"Bedrock API error ({error_code}): {e}")
        raise ValueError(f"Bedrock API error: {error_code}")
    except BotoCoreError as e:
        logger.error(f"Boto3 error: {e}")
        raise ValueError("AWS service error")

    try:
        resp_body = json.loads(response["body"].read())
    except json.JSONDecodeError as e:
        logger.error(f"Failed to parse Bedrock response: {e}")
        raise ValueError("Invalid response from Bedrock")

    chunks = []
    for block in resp_body.get("content", []):
        if block.get("type") == "text":
            chunks.append(block.get("text", ""))
    
    if not chunks:
        logger.warning("Empty response from Bedrock")
        return ""
    
    return "".join(chunks)
```

---

### 2.3 ETL Script Error Handling (🟡 HIGH)

**File:** `backend/etl/load_openai_embeddings_to_pgvector.py`

**Current Issues:**
- Limited error handling
- No retry logic for API calls
- No progress tracking for large datasets
- No validation of environment variables

**Add:**
```python
import os
import time
import pandas as pd
import psycopg2
from psycopg2.extras import execute_batch
from openai import OpenAI
import logging
from typing import Optional

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def validate_env():
    """Validate required environment variables."""
    required = ["OPENAI_API_KEY", "PGHOST", "PGUSER", "PGPASSWORD", "PGDATABASE"]
    missing = [var for var in required if not os.environ.get(var)]
    if missing:
        raise ValueError(f"Missing required environment variables: {', '.join(missing)}")

def get_openai_client() -> OpenAI:
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise ValueError("OPENAI_API_KEY not set")
    return OpenAI(api_key=api_key)

def embed_texts(client: OpenAI, texts, max_retries=3):
    """Embed texts with retry logic."""
    for attempt in range(max_retries):
        try:
            resp = client.embeddings.create(
                model=OPENAI_MODEL,
                input=texts,
            )
            return [item.embedding for item in resp.data]
        except Exception as e:
            if attempt == max_retries - 1:
                logger.error(f"Failed to embed texts after {max_retries} attempts: {e}")
                raise
            logger.warning(f"Embedding attempt {attempt + 1} failed, retrying...")
            time.sleep(2 ** attempt)  # Exponential backoff

def main():
    validate_env()
    
    csv_path = os.environ.get("FRU_CSV_PATH", "data/raw/fridge_sales_with_rating.csv")
    
    if not os.path.exists(csv_path):
        raise FileNotFoundError(f"CSV file not found: {csv_path}")
    
    try:
        df = pd.read_csv(csv_path)
    except Exception as e:
        raise ValueError(f"Failed to read CSV: {e}")

    # ... rest of the function with better error handling
```

---

## 3. Logging & Monitoring

### 3.1 Add Structured Logging (🟡 HIGH)

**File:** `backend/api/app.py`

**Add:**
```python
import logging
from logging.handlers import RotatingFileHandler
import os

# Configure logging
log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, log_level),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        RotatingFileHandler('logs/app.log', maxBytes=10485760, backupCount=5),
        logging.StreamHandler()
    ]
)

app.logger = logging.getLogger(__name__)
```

**Create logs directory:**
- Add `logs/` to `.gitignore` (already present)
- Create `logs/.gitkeep` to track directory

---

### 3.2 Add Health Check with Database Status (🟢 MEDIUM)

**File:** `backend/api/app.py`

**Update `/health` endpoint:**
```python
@app.route("/health", methods=["GET"])
def health():
    status = {"status": "ok"}
    
    # Check database connection
    try:
        conn = get_db_conn()
        conn.close()
        status["database"] = "connected"
    except Exception as e:
        status["database"] = "disconnected"
        status["database_error"] = str(e)
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
```

---

## 4. Configuration Management

### 4.1 Add Configuration File Support (🟢 MEDIUM)

**Create:** `backend/config.py`

```python
import os
from typing import Optional

class Config:
    # Database
    PGHOST: str = os.environ.get("PGHOST", "localhost")
    PGPORT: int = int(os.environ.get("PGPORT", "5432"))
    PGUSER: str = os.environ.get("PGUSER", "postgres")
    PGPASSWORD: str = os.environ.get("PGPASSWORD", "postgres")
    PGDATABASE: str = os.environ.get("PGDATABASE", "fru_db")
    
    # OpenAI
    OPENAI_API_KEY: Optional[str] = os.environ.get("OPENAI_API_KEY")
    OPENAI_EMBED_MODEL: str = os.environ.get("OPENAI_EMBED_MODEL", "text-embedding-3-small")
    
    # AWS
    AWS_REGION: str = os.environ.get("AWS_REGION", "us-east-1")
    BEDROCK_MODEL_ID: str = os.environ.get(
        "BEDROCK_MODEL_ID",
        "anthropic.claude-3-haiku-20240229-v1:0"
    )
    
    # Application
    LOG_LEVEL: str = os.environ.get("LOG_LEVEL", "INFO")
    MAX_QUERY_LIMIT: int = int(os.environ.get("MAX_QUERY_LIMIT", "50"))
```

**Update code to use Config class instead of direct `os.environ.get()`**

---

### 4.2 Add .env.example File (🟢 MEDIUM)

**Create:** `.env.example`

```bash
# Database Configuration
PGUSER=postgres
PGPASSWORD=postgres
PGDATABASE=fru_db
PGHOST=localhost
PGPORT=5432

# OpenAI Configuration
OPENAI_API_KEY=sk-your-key-here
OPENAI_EMBED_MODEL=text-embedding-3-small

# AWS Configuration
AWS_REGION=us-east-1
BEDROCK_MODEL_ID=anthropic.claude-3-haiku-20240229-v1:0

# Application Configuration
LOG_LEVEL=INFO
MAX_QUERY_LIMIT=50

# Data Paths
FRU_CSV_PATH=data/raw/fridge_sales_with_rating.csv
```

---

## 5. Security Enhancements

### 5.1 Add Input Validation (🟡 HIGH)

**File:** `backend/api/app.py`

**Add validation:**
```python
def validate_query(question: str) -> tuple[bool, Optional[str]]:
    """Validate user query input."""
    if not question or not question.strip():
        return False, "Query cannot be empty"
    
    if len(question) > 1000:
        return False, "Query too long (max 1000 characters)"
    
    # Add more validation as needed
    return True, None

@app.route("/query", methods=["POST"])
def query():
    body = request.get_json(silent=True) or {}
    question = body.get("query") or body.get("q") or ""

    is_valid, error_msg = validate_query(question)
    if not is_valid:
        return jsonify({"error": error_msg}), 400
    
    # ... rest of function
```

---

### 5.2 Add Rate Limiting (🟢 MEDIUM)

**Add to requirements.txt:**
```
flask-limiter>=3.0.0
```

**File:** `backend/api/app.py`

```python
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address

limiter = Limiter(
    app=app,
    key_func=get_remote_address,
    default_limits=["100 per hour"]
)

@app.route("/query", methods=["POST"])
@limiter.limit("10 per minute")
def query():
    # ... existing code
```

---

### 5.3 Add CORS Configuration (🟡 HIGH)

**Add to requirements.txt:**
```
flask-cors>=4.0.0
```

**File:** `backend/api/app.py`

```python
from flask_cors import CORS

app = Flask(__name__)
CORS(app, resources={
    r"/query": {"origins": os.environ.get("ALLOWED_ORIGINS", "*").split(",")},
    r"/health": {"origins": "*"}
})
```

---

## 6. Testing Infrastructure

### 6.1 Add Unit Tests (🟢 MEDIUM)

**Create:** `backend/tests/`
- `test_app.py` - API endpoint tests
- `test_bedrock_client.py` - Bedrock client tests
- `test_etl.py` - ETL script tests
- `conftest.py` - Pytest configuration

**Add to requirements-dev.txt:**
```
pytest>=7.4.0
pytest-cov>=4.1.0
pytest-mock>=3.11.0
```

---

### 6.2 Add Integration Tests (🟢 MEDIUM)

**Create:** `backend/tests/integration/`
- Test database connections
- Test end-to-end query flow
- Test ETL pipeline

---

## 7. Database Enhancements

### 7.1 Add Connection Pooling (🟡 HIGH)

**Add to requirements.txt:**
```
psycopg2-pool>=1.1  # Or use SQLAlchemy with connection pooling
```

**Or implement simple connection pool:**
```python
from psycopg2 import pool

connection_pool = None

def init_db_pool():
    global connection_pool
    connection_pool = psycopg2.pool.SimpleConnectionPool(
        1, 20,
        host=os.environ.get("PGHOST", "localhost"),
        port=int(os.environ.get("PGPORT", "5432")),
        user=os.environ.get("PGUSER", "postgres"),
        password=os.environ.get("PGPASSWORD", "postgres"),
        dbname=os.environ.get("PGDATABASE", "fru_db")
    )

def get_db_conn():
    if connection_pool:
        return connection_pool.getconn()
    else:
        # Fallback to direct connection
        return psycopg2.connect(...)
```

---

### 7.2 Add Database Migration Scripts (🟢 MEDIUM)

**Create:** `backend/db/migrations/`
- Use Alembic or simple SQL migration scripts
- Track schema versions

---

## 8. Frontend Enhancements

### 8.1 Add Environment Variable Support (🟢 MEDIUM)

**File:** `frontend/vite.config.ts`

**Add:**
```typescript
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/query": {
        target: process.env.VITE_API_URL || "http://localhost:5000",
        changeOrigin: true,
      },
    },
  },
});
```

**Create:** `frontend/.env.example`
```
VITE_API_URL=http://localhost:5000
```

---

### 8.2 Add Error Boundary (🟢 MEDIUM)

**Create:** `frontend/src/components/ErrorBoundary.tsx`

```typescript
import React, { Component, ErrorInfo, ReactNode } from "react";

interface Props {
  children: ReactNode;
}

interface State {
  hasError: boolean;
  error?: Error;
}

class ErrorBoundary extends Component<Props, State> {
  public state: State = {
    hasError: false
  };

  public static getDerivedStateFromError(error: Error): State {
    return { hasError: true, error };
  }

  public componentDidCatch(error: Error, errorInfo: ErrorInfo) {
    console.error("Uncaught error:", error, errorInfo);
  }

  public render() {
    if (this.state.hasError) {
      return (
        <div className="error-boundary">
          <h2>Something went wrong.</h2>
          <details>{this.state.error?.toString()}</details>
        </div>
      );
    }

    return this.props.children;
  }
}

export default ErrorBoundary;
```

---

## 9. Infrastructure Improvements

### 9.1 Add Docker Health Checks (🟢 MEDIUM)

**File:** `infra/docker/docker-compose.yml`

**Add to API service:**
```yaml
api:
  # ... existing config
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:5000/health"]
    interval: 30s
    timeout: 10s
    retries: 3
    start_period: 40s
```

---

### 9.2 Add Docker Compose Override Files (🟢 MEDIUM)

**Create:** `infra/docker/docker-compose.override.yml.example`
- For local development overrides
- Different port mappings
- Volume mounts for development

---

### 9.3 Add Terraform Improvements (🟢 MEDIUM)

**File:** `infra/terraform/main.tf`

**Add:**
- VPC configuration
- Security groups
- ECS task definitions
- CloudWatch logging
- Secrets Manager integration

---

## 10. Documentation Improvements

### 10.1 Add API Documentation (🟢 MEDIUM)

**Add Swagger/OpenAPI:**
- Add `flask-swagger-ui` or `flasgger`
- Document all endpoints
- Add request/response examples

---

### 10.2 Add Architecture Diagrams (🟢 MEDIUM)

**Create:** `docs/architecture/`
- System architecture diagram
- Data flow diagram
- Deployment diagram

---

### 10.3 Add Troubleshooting Guide (🟡 HIGH)

**Add to README_RUN.md Section 7:**
- Common errors and solutions
- Database connection issues
- API key configuration problems
- Docker issues

---

## 11. Performance Optimizations

### 11.1 Add Caching (🟢 MEDIUM)

**Add Redis caching for:**
- Frequently asked questions
- Embedding results (with TTL)
- Stats calculations

---

### 11.2 Add Async Processing (🟢 MEDIUM)

**For ETL:**
- Use async/await for OpenAI API calls
- Batch processing improvements
- Progress tracking

---

## 12. Code Organization

### 12.1 Refactor into Modules (🟢 MEDIUM)

**Current structure is flat, consider:**
```
backend/
  api/
    routes/
      query.py
      health.py
    services/
      embedding_service.py
      database_service.py
      bedrock_service.py
    models/
      response_models.py
  etl/
    load_openai_embeddings_to_pgvector.py
  llm/
    bedrock_client.py
  config/
    settings.py
  utils/
    validators.py
```

---

## Summary by Priority

### 🔴 CRITICAL (Must Fix)
1. Add Python dependency installation to README_RUN.md
2. Add system prerequisites to README_RUN.md
3. Add Docker alternative for schema initialization

### 🟡 HIGH (Should Fix)
1. Add version pinning to requirements.txt
2. Add error handling to API endpoints
3. Add error handling to Bedrock client
4. Add input validation
5. Add CORS configuration
6. Add connection pooling
7. Add troubleshooting guide

### 🟢 MEDIUM (Nice to Have)
1. Add structured logging
2. Add configuration management
3. Add .env.example
4. Add unit tests
5. Add health check improvements
6. Add rate limiting
7. Add frontend error boundary
8. Add API documentation

### 🔵 LOW (Future Enhancements)
1. Add caching
2. Add async processing
3. Add architecture diagrams
4. Refactor code organization

---

**Total Enhancements: 40+ items across 12 categories**

