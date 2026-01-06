# Backend Refactoring Plan

## 📋 Overview

This refactoring plan addresses:
1. OS operations compatibility (local vs cloud)
2. Code cleanup and consolidation
3. Multi-environment extensibility (Local, AWS, Azure, GCP)
4. Dependency isolation
5. Factory Pattern implementation for LLM clients

### Environment Types:
- **Local**: Docker Compose, local PostgreSQL, local file system, Claude API (optional Bedrock)
- **AWS**: ECS/EKS, Aurora PostgreSQL, S3/EFS, Bedrock
- **Azure**: Future support
- **GCP**: Future support

---

## 1. OS Operations Clarification

### ✅ Operations that WORK everywhere:
- `os.environ.get()` - Works in containers, AWS, local ✓
- `os.path.join()` - Works for building paths (but result may not work with S3) ✓
- `os.path.dirname()`, `os.path.abspath()` - Works everywhere ✓
- `os.getenv()` - Alias for `os.environ.get()`, works everywhere ✓

### ❌ Operations that DON'T work with S3:
- `os.path.exists()` - **DOESN'T work for S3 paths** ❌
- `os.listdir()` - **DOESN'T work for S3 paths** ❌
- `open()` with local paths - **DOESN'T work for S3 paths** ❌

### 🔧 Solution:
- Replace `os.path.exists()` with environment-aware file system abstraction
- Use `env_utils/` folder for environment-specific implementations

---

## 2. File Usage Analysis

### ✅ Files that ARE referenced (KEEP):

#### backend/services/
- `analytics_scheduler.py` 
  - **Used by:** `backend/api/app.py` (line 18)
  - **Status:** ✅ KEEP - Core scheduler functionality

- `save_analytics_to_db.py`
  - **Used by:** 
    - `spark_jobs/run_analytics.py` (line 13)
    - `backend/scripts/run_batch_analytics_from_db.py` (line 14)
  - **Status:** ✅ KEEP - Shared by Spark jobs and scripts

#### backend/utils/
- `env_helpers.py`
  - **Used by:** 9 files (heavily referenced)
    - `backend/api/app.py`
    - `backend/services/*` (3 files)
    - `backend/llm/bedrock_client.py`
    - `backend/etl/*` (2 files)
    - `backend/scripts/run_batch_analytics_from_db.py`
  - **Status:** ✅ KEEP - Core utility

### ❌ Files that are NOT referenced (REMOVE in Phase 2):

- `backend/services/feature_flags.py`
  - **Used by:** ❌ NONE (not imported anywhere)
  - **Status:** ❌ REMOVE - Dead code

- `backend/scripts/run_batch_analytics_from_db.py`
  - **Used by:** ❌ NONE (standalone script, not imported)
  - **Status:** ❌ REMOVE - Alternative implementation, superseded by Spark-based analytics
  - **Note:** This is a PostgreSQL-only version; we're standardizing on Spark + Delta

### ⚠️ Files needing environment abstraction:

- `backend/llm/bedrock_client.py` - AWS Bedrock specific (needs Factory Pattern refactor)
- `backend/etl/load_openai_embeddings_to_pgvector_rds_api.py` - AWS RDS Data API specific
- `backend/services/analytics_scheduler.py` - Has `os.path.exists()` that needs S3 support

---

## 3. spark_jobs/ vs backend/services/ Consolidation

### Current Structure:
```
spark_jobs/
  ├─ ingest_delta.py          # CSV → Delta Lake (ETL)
  ├─ generate_training_data.py # Generate NLQ→SQL pairs
  └─ run_analytics.py          # Batch analytics (calls backend.services.save_analytics_to_db)

backend/services/
  ├─ analytics_scheduler.py    # Scheduler (calls spark_jobs/run_analytics.py)
  └─ save_analytics_to_db.py   # Save results to PostgreSQL
```

### Analysis:
- **Different execution contexts:**
  - `spark_jobs/` - Runs via `spark-submit` (separate process)
  - `backend/services/` - Runs in Flask container (same process)
  
- **Different dependencies:**
  - `spark_jobs/` - Requires PySpark, Delta Lake
  - `backend/services/` - Requires psycopg2, Flask context

### Recommendation:
- ❌ **DO NOT consolidate** - They serve different purposes:
  - `spark_jobs/` - Spark execution code (external to Flask)
  - `backend/services/` - Flask service code (internal to Flask)
- ✅ **Keep separation** - Clear boundary between Spark jobs and Flask services
- ✅ **Improve organization** - Rename to `backend/services/analytics/`

---

## 4. Dependency Analysis

### Current Dependencies (requirements.txt):
```
flask>=2.3.0,<3.0.0           # ✅ Flask API
pyspark>=3.4.0                # ✅ Spark jobs
delta-spark>=3.0.0            # ✅ Delta Lake
boto3>=1.28.0                 # ⚠️ AWS-specific
psycopg2-binary>=2.9.0        # ✅ PostgreSQL (used by all)
openai>=1.0.0                 # ✅ OpenAI embeddings
pandas>=2.0.0                 # ✅ USED in ETL scripts - KEEP
flask-cors>=4.0.0             # ✅ Flask CORS
APScheduler>=3.10.0           # ✅ Analytics scheduler
anthropic>=0.18.0             # ✅ Claude API client (for local dev)
```

### AWS-Specific Dependencies:
- `boto3` - Used by:
  - `backend/llm/bedrock_client.py` (Bedrock)
  - `backend/etl/load_openai_embeddings_to_pgvector_rds_api.py` (RDS Data API)
  - Future S3 checks in `analytics_scheduler.py`

### Cleanup Opportunities:
- Consider making `boto3` optional (only install for AWS deployments)
- Consider making `anthropic` optional (only install for local deployments)

---

## 5. Multi-Environment Architecture Plan

### Proposed Structure:

```
backend/
├─ api/
│   └─ app.py                          # Flask API (environment-agnostic)
│
├─ services/
│   ├─ analytics/
│   │   ├─ scheduler.py                # Analytics scheduler (environment-agnostic)
│   │   └─ save_to_db.py               # Save analytics to DB (environment-agnostic)
│   └─ __init__.py
│
├─ utils/
│   ├─ env_helpers.py                  # Environment variable helpers (environment-agnostic)
│   └─ filesystem.py                   # NEW: File system abstraction (detects local/S3/EFS)
│
├─ llm/
│   ├─ __init__.py
│   ├─ base_client.py                  # NEW: Abstract base class for LLM clients
│   └─ client_factory.py               # NEW: Factory for environment-specific LLM clients
│
├─ env_utils/                          # NEW: Environment-specific utilities
│   ├─ __init__.py
│   ├─ local/                          # Local development environment
│   │   ├─ __init__.py
│   │   ├─ claude_client.py            # NEW: Claude API client (implements LLMClient)
│   │   └─ filesystem.py               # NEW: Local file system operations (os.path.* wrappers)
│   ├─ aws/
│   │   ├─ __init__.py
│   │   ├─ bedrock_client.py           # Moved from backend/llm/ (implements LLMClient)
│   │   ├─ s3_helpers.py               # NEW: S3 file operations (exists, list, etc.)
│   │   └─ rds_data_api.py             # Moved from backend/etl/ (AWS RDS Data API)
│   ├─ azure/                          # FUTURE
│   │   ├─ __init__.py
│   │   └─ cognitive_services.py
│   └─ gcp/                            # FUTURE
│       ├─ __init__.py
│       └─ vertex_ai.py
│
└─ etl/                                # ETL scripts (can have environment-specific variants)
    └─ load_openai_embeddings_to_pgvector.py  # Environment-agnostic (uses psycopg2)
```

### Environment Detection:

The system detects environment type via:
1. **Path detection** (for filesystem): `s3://` → AWS, `/mnt/efs/` → AWS EFS, else → Local
2. **Environment variables** (for LLM): `CLAUDE_API_KEY` → Local Claude API, `AWS_REGION` + Bedrock config → AWS Bedrock
3. **Explicit configuration** (optional): `ENVIRONMENT_TYPE` env var (local/aws/azure/gcp)

### Key Changes:

1. **Create `backend/env_utils/` folder:**
   - Isolate environment-specific code (local, AWS, Azure, GCP)
   - Structure: `env_utils/{environment}/`
   - Each environment has its own folder
   - **Local is first-class**: `env_utils/local/` for local development

2. **Create `backend/utils/filesystem.py`:**
   - Abstract file operations (exists, list, read, write)
   - Environment-aware (detects S3/local/EFS)
   - Uses `env_utils/{environment}/filesystem.py` for environment-specific implementations
   - **Local uses `os.path.*` directly** (no abstraction needed)

3. **Refactor `backend/llm/` with Factory Pattern:**
   - Create `base_client.py` - Abstract base class (`LLMClient` ABC)
   - Create `client_factory.py` - Factory pattern for LLM clients
   - Move `bedrock_client.py` → `env_utils/aws/bedrock_client.py` (implements `LLMClient`)
   - Extract Claude API client → `env_utils/local/claude_client.py` (implements `LLMClient`)
   - Factory detects: Local (Claude API) vs AWS (Bedrock) vs Azure/GCP (future)
   - **Priority**: 
     1. `CLAUDE_API_KEY` set → Local Claude API (for local dev)
     2. `AWS_REGION` + Bedrock config → AWS Bedrock
     3. Future: Azure/GCP config → respective services

4. **Update `backend/services/analytics_scheduler.py`:**
   - Replace `os.path.exists()` with `filesystem.exists()`
   - Use filesystem abstraction for path operations
   - Works for local paths (`data/delta/fru_sales`) and S3 paths (`s3://bucket/path`)

---

## 6. Environment Comments in File Headers

All files must have a clear comment at the top indicating which environment(s) they apply to.

### Format:
```python
"""
File description here.

Applicable environment: [local] [aws {ecs | eks}] [azure {aks}] [gcp {gke}]
"""
```

### Format Explanation:

- `[local]` - Local development environment (Docker Compose, local PostgreSQL)
- `[aws]` - AWS cloud, but not specific to ECS or EKS (e.g., infrastructure-level code, shared services)
- `[aws {ecs}]` - AWS cloud, specifically ECS only (e.g., ECS task definition configs, ECS-specific deployment)
- `[aws {eks}]` - AWS cloud, specifically EKS only (e.g., Kubernetes manifests, EKS-specific deployment)
- `[aws {ecs | eks}]` - AWS cloud, works for ECS OR EKS (e.g., runtime code that runs in containers on both platforms)
- `[azure]` - Azure cloud, but not specific to ACI or AKS (e.g., infrastructure-level code)
- `[azure {aci}]` - Azure cloud, specifically ACI only (Azure Container Instances, similar to ECS Fargate)
- `[azure {aks}]` - Azure cloud, specifically AKS only (Azure Kubernetes Service)
- `[azure {aci | aks}]` - Azure cloud, works for ACI OR AKS (e.g., runtime code that runs in containers on both platforms)
- `[gcp]` - GCP cloud, but not specific to Cloud Run or GKE (e.g., infrastructure-level code)
- `[gcp {cloud-run}]` - GCP cloud, specifically Cloud Run only (serverless containers, similar to ECS Fargate)
- `[gcp {gke}]` - GCP cloud, specifically GKE only (Google Kubernetes Engine)
- `[gcp {cloud-run | gke}]` - GCP cloud, works for Cloud Run OR GKE (e.g., runtime code that runs in containers on both platforms)

### Examples:

**Environment-agnostic files:**
```python
# backend/utils/env_helpers.py
"""
Environment variable helpers with fail-fast validation.
Ensures .env is the single source of truth for configuration.

Applicable environment: [local] [aws {ecs | eks}] [azure {aks}] [gcp {gke}]
"""
```

**Local-specific files:**
```python
# backend/env_utils/local/claude_client.py
"""
Claude API client for local development.
Implements LLMClient interface for local Claude API usage.

Applicable environment: [local]
"""
```

**AWS files that work for both ECS and EKS:**
```python
# backend/env_utils/aws/bedrock_client.py
"""
AWS Bedrock client for AWS production.
Implements LLMClient interface for AWS Bedrock usage.
Works in both ECS and EKS containers (uses IAM role or AWS credentials).

Applicable environment: [aws {ecs | eks}]
"""
```

```python
# backend/env_utils/aws/s3_helpers.py
"""
AWS S3-specific file operations.
Provides S3-compatible file system operations.
Works in both ECS and EKS containers (uses IAM role or AWS credentials).

Applicable environment: [aws {ecs | eks}]
"""
```

```python
# backend/env_utils/aws/rds_data_api.py
"""
AWS RDS Data API client for Aurora PostgreSQL.
Works in both ECS and EKS containers (uses IAM role or AWS credentials).

Applicable environment: [aws {ecs | eks}]
"""
```

**AWS files that are not platform-specific (infrastructure-level):**
```python
# Example: Infrastructure/Terraform configuration files (if in backend code)
"""
AWS infrastructure configuration.
Not specific to ECS or EKS, works at infrastructure level.

Applicable environment: [aws]
"""
```

**Multi-environment files:**
```python
# backend/utils/filesystem.py
"""
File system abstraction for multi-environment support.
Works with local, S3, EFS, and future storage backends.

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
"""
```

**Files that work across environments:**
```python
# backend/api/app.py
"""
Flask API application.
Environment-agnostic, works in local, AWS (ECS/EKS), Azure (ACI/AKS), GCP (Cloud Run/GKE).

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
"""
```

**Abstract base class (platform-agnostic interface):**
```python
# backend/llm/base_client.py
"""
Abstract base class for LLM clients.
This is an abstract interface, platform-agnostic and works in any container environment.

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
"""
```

### Files Requiring Environment Comments:

All new and refactored files must include environment comments:
- ✅ All files in `backend/env_utils/` (environment-specific)
- ✅ All files in `backend/utils/` (environment-agnostic or multi-environment)
- ✅ All files in `backend/llm/` (environment-agnostic or multi-environment)
- ✅ All files in `backend/services/` (environment-agnostic)
- ✅ All files in `backend/api/` (environment-agnostic)

---

## 7. Detailed Refactoring Phases

### Phase 1: Create Infrastructure and Factory Pattern

#### Step 1.1: Create File System Abstraction

**New file: `backend/utils/filesystem.py`**
```python
"""
File system abstraction for multi-environment support.
Works with local, S3, EFS, and future storage backends.

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
"""
from typing import Optional
import os

def detect_storage_type(path: str) -> str:
    """
    Detect storage type from path.
    
    Returns:
        's3' for S3 paths (s3://bucket/key)
        'efs' for EFS paths (/mnt/efs/...)
        'local' for local file system paths
    """
    if path.startswith('s3://'):
        return 's3'
    elif path.startswith('/mnt/efs/'):
        return 'efs'
    else:
        return 'local'

def exists(path: str) -> bool:
    """
    Check if path exists (works for S3, local, EFS).
    
    Args:
        path: File or directory path (can be s3://, /mnt/efs/, or local)
    
    Returns:
        bool: True if path exists, False otherwise
    """
    storage_type = detect_storage_type(path)
    
    if storage_type == 's3':
        from backend.env_utils.aws.s3_helpers import s3_exists
        return s3_exists(path)
    elif storage_type == 'efs':
        # EFS is mounted, so use local filesystem operations
        return os.path.exists(path)
    else:
        # Local file system - use os.path directly
        return os.path.exists(path)

def listdir(path: str) -> list:
    """List directory contents (works for S3, local, EFS)"""
    storage_type = detect_storage_type(path)
    
    if storage_type == 's3':
        from backend.env_utils.aws.s3_helpers import s3_listdir
        return s3_listdir(path)
    else:
        return os.listdir(path)

# Similar functions: read_file(), write_file(), mkdir(), etc.
```

**New file: `backend/env_utils/local/filesystem.py`**
```python
"""
Local file system operations.
Wrapper around os.path.* for consistency with other environments.

Applicable environment: [local]
"""
import os

def exists(path: str) -> bool:
    """Check if local path exists"""
    return os.path.exists(path)

def listdir(path: str) -> list:
    """List local directory contents"""
    return os.listdir(path)

# Other local file operations...
```

**New file: `backend/env_utils/aws/s3_helpers.py`**
```python
"""
AWS S3-specific file operations.
Provides S3-compatible file system operations.
Works in both ECS and EKS containers (uses IAM role or AWS credentials).

Applicable environment: [aws {ecs | eks}]
"""
import boto3
from urllib.parse import urlparse
from typing import Optional

def s3_exists(s3_path: str) -> bool:
    """
    Check if S3 path exists.
    
    Args:
        s3_path: S3 path in format s3://bucket/key
    
    Returns:
        bool: True if path exists, False otherwise
    """
    parsed = urlparse(s3_path)
    bucket = parsed.netloc
    key = parsed.path.lstrip('/')
    
    s3_client = boto3.client('s3')
    try:
        # For directories (keys ending with /), list objects
        if key.endswith('/') or key == '':
            response = s3_client.list_objects_v2(
                Bucket=bucket,
                Prefix=key,
                MaxKeys=1
            )
            return response.get('KeyCount', 0) > 0
        else:
            # For files, use head_object
            s3_client.head_object(Bucket=bucket, Key=key)
            return True
    except s3_client.exceptions.NoSuchKey:
        return False
    except s3_client.exceptions.ClientError as e:
        if e.response['Error']['Code'] == '404':
            return False
        raise

def s3_listdir(s3_path: str) -> list:
    """List S3 directory contents"""
    # Implementation for S3 directory listing
    pass
```

#### Step 1.2: Create LLM Factory Pattern

**New file: `backend/llm/base_client.py`**
```python
"""
Abstract base class for LLM clients.
All LLM implementations must implement this interface.
This is an abstract interface, platform-agnostic and works in any environment.

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
"""
from abc import ABC, abstractmethod
from typing import Dict, Any, Optional

class LLMClient(ABC):
    """Abstract base class for LLM clients."""
    
    @abstractmethod
    def complete(
        self,
        system_prompt: str,
        user_message: str,
        model_id: Optional[str] = None,
        max_tokens: int = 2000
    ) -> Dict[str, Any]:
        """
        Generate a completion using the LLM.
        
        Args:
            system_prompt: System prompt for the LLM
            user_message: User message content
            model_id: Optional model ID
            max_tokens: Maximum tokens in response
        
        Returns:
            Dict with keys: 'text' (str), 'tokens' (dict with input/output/total)
        """
        pass
    
    @abstractmethod
    def stream_complete(
        self,
        system_prompt: str,
        user_message: str,
        model_id: Optional[str] = None,
        max_tokens: int = 2000
    ):
        """
        Generate a streaming completion (yields chunks).
        
        Args:
            system_prompt: System prompt for the LLM
            user_message: User message content
            model_id: Optional model ID
            max_tokens: Maximum tokens in response
        
        Yields:
            Dict with 'text' chunk and optional 'tokens'
        """
        pass
```

**New file: `backend/env_utils/local/claude_client.py`**
```python
"""
Claude API client for local development.
Implements LLMClient interface for local Claude API usage.

Applicable environment: [local]
"""
from backend.llm.base_client import LLMClient
from anthropic import Anthropic
import os
import logging
from typing import Dict, Any, Optional

logger = logging.getLogger(__name__)

class LocalClaudeClient(LLMClient):
    """Claude API client (local development)."""
    
    def __init__(self):
        api_key = os.environ.get("CLAUDE_API_KEY", "").strip()
        if not api_key:
            raise ValueError("CLAUDE_API_KEY must be set for local Claude API")
        self.client = Anthropic(api_key=api_key)
        self.model = "claude-3-5-haiku-20241022"  # Match Bedrock model
    
    def complete(
        self,
        system_prompt: str,
        user_message: str,
        model_id: Optional[str] = None,
        max_tokens: int = 2000
    ) -> Dict[str, Any]:
        """Generate completion using Claude API."""
        model = model_id or self.model
        response = self.client.messages.create(
            model=model,
            max_tokens=max_tokens,
            system=system_prompt,
            messages=[{"role": "user", "content": user_message}]
        )
        
        usage = response.usage
        return {
            "text": response.content[0].text,
            "tokens": {
                "input": usage.input_tokens,
                "output": usage.output_tokens,
                "total": usage.input_tokens + usage.output_tokens
            }
        }
    
    def stream_complete(self, system_prompt, user_message, model_id=None, max_tokens=2000):
        """Generate streaming completion using Claude API."""
        # Implementation for streaming...
        pass
```

**New file: `backend/env_utils/aws/bedrock_client.py`**
```python
"""
AWS Bedrock client for AWS production.
Implements LLMClient interface for AWS Bedrock usage.
Works in both ECS and EKS containers (uses IAM role or AWS credentials).

Applicable environment: [aws {ecs | eks}]
"""
from backend.llm.base_client import LLMClient
from backend.utils.env_helpers import get_required_env
import boto3
import os
import logging
import json
from typing import Dict, Any, Optional

logger = logging.getLogger(__name__)

class AWSBedrockClient(LLMClient):
    """AWS Bedrock client (AWS production)."""
    
    def __init__(self):
        region = get_required_env("AWS_REGION", "AWS region for Bedrock API")
        profile = os.environ.get("AWS_PROFILE", "")
        
        if profile:
            session = boto3.Session(profile_name=profile)
        else:
            session = boto3.Session()
        
        self.client = session.client("bedrock-runtime", region_name=region)
        self.inference_profile_id = os.environ.get("AWS_BEDROCK_INFERENCE_PROFILE_ID", "").strip()
        self.model_id = os.environ.get("AWS_BEDROCK_MODEL_ID", "").strip()
    
    def complete(
        self,
        system_prompt: str,
        user_message: str,
        model_id: Optional[str] = None,
        max_tokens: int = 2000
    ) -> Dict[str, Any]:
        """Generate completion using AWS Bedrock."""
        # Implementation from current bedrock_client.py
        # Use inference profile if available, else model ID
        pass
    
    def stream_complete(self, system_prompt, user_message, model_id=None, max_tokens=2000):
        """Generate streaming completion using AWS Bedrock."""
        # Implementation for streaming...
        pass
```

**New file: `backend/llm/client_factory.py`**
```python
"""
Factory for creating LLM clients based on environment.
This is the Factory Pattern implementation.
Works in any environment - detects and creates appropriate client.

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
"""
from backend.llm.base_client import LLMClient
from typing import Optional
import os
import logging

logger = logging.getLogger(__name__)

def create_llm_client() -> LLMClient:
    """
    Factory function that creates the appropriate LLM client based on environment.
    
    This encapsulates the decision logic of which concrete implementation to use.
    The caller doesn't need to know which specific implementation is returned.
    
    Priority:
    1. CLAUDE_API_KEY set → Local Claude API client
    2. AWS_REGION + Bedrock config → AWS Bedrock client
    3. Future: Azure/GCP config → respective clients
    
    Returns:
        LLMClient: Concrete implementation (LocalClaudeClient, AWSBedrockClient, etc.)
    
    Raises:
        ValueError: If no suitable LLM client can be created
    """
    # Priority 1: Check for local Claude API
    claude_api_key = os.environ.get("CLAUDE_API_KEY", "").strip()
    if claude_api_key:
        try:
            from backend.env_utils.local.claude_client import LocalClaudeClient
            logger.info("Creating Local Claude API client")
            return LocalClaudeClient()
        except ImportError as e:
            logger.warning(f"Claude API client not available: {e}")
        except Exception as e:
            logger.error(f"Failed to create Local Claude client: {e}")
            raise
    
    # Priority 2: Check for AWS Bedrock
    aws_region = os.environ.get("AWS_REGION", "").strip()
    bedrock_profile_id = os.environ.get("AWS_BEDROCK_INFERENCE_PROFILE_ID", "").strip()
    bedrock_model_id = os.environ.get("AWS_BEDROCK_MODEL_ID", "").strip()
    
    if aws_region and (bedrock_profile_id or bedrock_model_id):
        try:
            from backend.env_utils.aws.bedrock_client import AWSBedrockClient
            logger.info("Creating AWS Bedrock client")
            return AWSBedrockClient()
        except ImportError as e:
            logger.warning(f"Bedrock client not available: {e}")
        except Exception as e:
            logger.error(f"Failed to create AWS Bedrock client: {e}")
            raise
    
    # Priority 3: Future - Azure Cognitive Services
    # Priority 4: Future - GCP Vertex AI
    
    # If no suitable client found, raise error
    raise ValueError(
        "No LLM client available. Set one of:\n"
        "  - CLAUDE_API_KEY (for local Claude API)\n"
        "  - AWS_REGION + AWS_BEDROCK_INFERENCE_PROFILE_ID or AWS_BEDROCK_MODEL_ID (for AWS Bedrock)"
    )


# Convenience function for backward compatibility
def claude_complete(
    system_prompt: str, 
    user_message: str, 
    model_id: Optional[str] = None, 
    max_tokens: int = 2000
) -> Dict[str, Any]:
    """
    Convenience function for backward compatibility.
    Creates LLM client using factory and calls complete().
    
    This maintains the same API as the old claude_complete() function,
    but now uses the Factory pattern internally.
    """
    client = create_llm_client()
    return client.complete(system_prompt, user_message, model_id, max_tokens)
```

#### Step 1.3: Move Environment-Specific Code

1. **Move Bedrock client (AWS):**
   - Extract current implementation from `backend/llm/bedrock_client.py`
   - Move to `backend/env_utils/aws/bedrock_client.py` as `AWSBedrockClient` class
   - Implement `LLMClient` interface
   - Add environment comment: `Applicable environment: [aws {ecs | eks}]`

2. **Extract Claude API client (Local):**
   - Extract `get_claude_client()` logic from `backend/llm/bedrock_client.py`
   - Move to `backend/env_utils/local/claude_client.py` as `LocalClaudeClient` class
   - Implement `LLMClient` interface
   - Add environment comment: `Applicable environment: [local]`

3. **Move RDS Data API (AWS):**
   - `backend/etl/load_openai_embeddings_to_pgvector_rds_api.py` → `backend/env_utils/aws/rds_data_api.py`
   - Keep environment-agnostic version: `backend/etl/load_openai_embeddings_to_pgvector.py`
   - Add environment comment: `Applicable environment: [aws {ecs | eks}]`

4. **Update scheduler:**
   - Replace `os.path.exists()` with `filesystem.exists()`
   - Use filesystem abstraction throughout
   - Works for both local paths (`data/delta/fru_sales`) and S3 paths (`s3://bucket/path`)

#### Step 1.4: Update Application Code to Use Factory

**Update `backend/api/app.py`:**
```python
# Before:
from backend.llm.bedrock_client import claude_complete, get_bedrock_client

# After:
from backend.llm.client_factory import create_llm_client, claude_complete  # Backward compat
```

**Update agent initialization:**
```python
# Before:
bedrock_client = get_bedrock_client()

# After:
llm_client = create_llm_client()  # Factory creates appropriate client
```

#### Step 1.5: Reorganize Services Directory

1. **Create `backend/services/analytics/` directory**
2. **Move files:**
   - `backend/services/analytics_scheduler.py` → `backend/services/analytics/scheduler.py`
   - `backend/services/save_analytics_to_db.py` → `backend/services/analytics/save_to_db.py`
3. **Update imports** in all files that reference these modules
4. **Add environment comments** to both files:
   - `Applicable environment: [local] [aws] [azure] [gcp]`

---

### Phase 2: Add Environment Comments and Documentation

#### Step 2.1: Add Environment Comments to All Files

Add environment comments to the top of every file:

**Environment-agnostic files:**
- `backend/api/app.py` - `Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]`
- `backend/utils/env_helpers.py` - `Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]`
- `backend/utils/filesystem.py` - `Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]`
- `backend/services/analytics/scheduler.py` - `Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]`
- `backend/services/analytics/save_to_db.py` - `Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]`
- `backend/llm/base_client.py` - `Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]` (abstract interface, platform-agnostic)
- `backend/llm/client_factory.py` - `Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]`

**Local-specific files:**
- `backend/env_utils/local/claude_client.py` - `Applicable environment: [local]`
- `backend/env_utils/local/filesystem.py` - `Applicable environment: [local]`

**AWS-specific files (works for both ECS and EKS):**
- `backend/env_utils/aws/bedrock_client.py` - `Applicable environment: [aws {ecs | eks}]`
- `backend/env_utils/aws/s3_helpers.py` - `Applicable environment: [aws {ecs | eks}]`
- `backend/env_utils/aws/rds_data_api.py` - `Applicable environment: [aws {ecs | eks}]`

#### Step 2.2: Update Documentation

1. **Update README.md** with new structure
2. **Update code comments** explaining environment-specific logic
3. **Create migration guide** for developers

---

### Phase 3: Remove Dead Code and Clean Up

#### Step 3.1: Remove Unused Files

1. **Remove `backend/services/feature_flags.py`**
   - Check for any remaining imports
   - Remove file
   - Update `backend/services/__init__.py` if needed

2. **Remove `backend/scripts/run_batch_analytics_from_db.py`**
   - Standalone script, not imported anywhere
   - Superseded by Spark-based analytics
   - Remove file

3. **Remove old `backend/llm/bedrock_client.py`**
   - After migration to Factory Pattern is complete
   - Ensure no imports remain
   - Remove file

#### Step 3.2: Clean Up Imports

1. **Remove unused imports** from all files
2. **Update import statements** to use new paths:
   - `backend.services.analytics_scheduler` → `backend.services.analytics.scheduler`
   - `backend.services.save_analytics_to_db` → `backend.services.analytics.save_to_db`
   - `backend.llm.bedrock_client` → `backend.llm.client_factory` or `backend.env_utils.aws.bedrock_client`

#### Step 3.3: Clean Up Dependencies

1. **Analyze boto3 usage:**
   - Consider making `boto3` optional (only install for AWS deployments)
   - Create `requirements-aws.txt` or use `extras` in setup.py

2. **Analyze anthropic usage:**
   - Consider making `anthropic` optional (only install for local deployments)
   - Create `requirements-local.txt` or use `extras` in setup.py

3. **Update requirements.txt:**
   - Add comments indicating which dependencies are environment-specific
   - Consider splitting into:
     - `requirements.txt` (core dependencies)
     - `requirements-local.txt` (local development)
     - `requirements-aws.txt` (AWS deployments)

---

## 8. File Organization After Refactoring

```
backend/
├─ api/
│   └─ app.py                          # Flask API (environment-agnostic)
│
├─ services/
│   ├─ analytics/
│   │   ├─ scheduler.py                # Refactored (uses filesystem abstraction)
│   │   └─ save_to_db.py               # Renamed from save_analytics_to_db.py
│   └─ __init__.py
│
├─ utils/
│   ├─ env_helpers.py                  # Keep (environment-agnostic)
│   └─ filesystem.py                   # NEW: File system abstraction
│
├─ llm/
│   ├─ __init__.py
│   ├─ base_client.py                  # NEW: Abstract base class
│   └─ client_factory.py               # NEW: Factory for LLM clients
│
├─ env_utils/                          # NEW: Environment-specific utilities
│   ├─ __init__.py
│   ├─ local/
│   │   ├─ __init__.py
│   │   ├─ claude_client.py            # NEW: Claude API client (implements LLMClient)
│   │   └─ filesystem.py               # NEW: Local file system wrappers
│   └─ aws/
│       ├─ __init__.py
│       ├─ bedrock_client.py           # Moved from llm/ (implements LLMClient)
│       ├─ s3_helpers.py               # NEW: S3 operations
│       └─ rds_data_api.py             # Moved from etl/
│
├─ etl/
│   └─ load_openai_embeddings_to_pgvector.py  # Keep (environment-agnostic)
│
└─ agents/                             # Keep as-is (environment-agnostic)
    └─ ...
```

---

## 9. Summary of Changes

### Files to CREATE:
1. `backend/env_utils/__init__.py`
2. `backend/env_utils/local/__init__.py`
3. `backend/env_utils/local/claude_client.py` (new - extracted from bedrock_client.py)
4. `backend/env_utils/local/filesystem.py` (optional - for consistency)
5. `backend/env_utils/aws/__init__.py`
6. `backend/env_utils/aws/bedrock_client.py` (moved from llm/, refactored to class)
7. `backend/env_utils/aws/s3_helpers.py` (new)
8. `backend/env_utils/aws/rds_data_api.py` (moved from etl/)
9. `backend/utils/filesystem.py` (new - abstraction layer)
10. `backend/llm/base_client.py` (new - ABC interface)
11. `backend/llm/client_factory.py` (new - Factory pattern)
12. `backend/services/analytics/__init__.py` (new)
13. `backend/services/analytics/scheduler.py` (renamed from analytics_scheduler.py)
14. `backend/services/analytics/save_to_db.py` (renamed from save_analytics_to_db.py)

### Files to MOVE:
1. `backend/llm/bedrock_client.py` → `backend/env_utils/aws/bedrock_client.py` (refactored to class)
2. `backend/etl/load_openai_embeddings_to_pgvector_rds_api.py` → `backend/env_utils/aws/rds_data_api.py`

### Files to REMOVE (Phase 3):
1. `backend/services/feature_flags.py` (unused)
2. `backend/scripts/run_batch_analytics_from_db.py` (superseded)
3. `backend/llm/bedrock_client.py` (after migration complete)

### Files to UPDATE:
1. `backend/services/analytics_scheduler.py` → `backend/services/analytics/scheduler.py` - Use filesystem abstraction
2. `backend/api/app.py` - Update LLM client imports to use factory
3. `backend/agents/query_agent.py` - Update to use factory for LLM client
4. `backend/etl/load_openai_embeddings_to_pgvector.py` - Update if needed
5. `spark_jobs/run_analytics.py` - Update imports (save_to_db.py path change)
6. `requirements.txt` - Clean up dependencies, consider splitting

### Files to RENAME:
1. `backend/services/analytics_scheduler.py` → `backend/services/analytics/scheduler.py`
2. `backend/services/save_analytics_to_db.py` → `backend/services/analytics/save_to_db.py`

---

## 10. Testing Checklist

### Local Environment:
- [ ] Local development: Spark analytics with local Delta table (`data/delta/fru_sales`)
- [ ] Local development: LLM client using Claude API (via `CLAUDE_API_KEY`)
- [ ] Local development: Filesystem operations using `os.path.*` (local paths)
- [ ] Local development: Docker Compose setup works end-to-end
- [ ] Local development: Factory creates `LocalClaudeClient` correctly

### AWS Environment:
- [ ] AWS: Spark analytics with S3 Delta table (`s3://bucket/delta/fru_sales`)
- [ ] AWS: Analytics scheduler with S3 path detection
- [ ] AWS: LLM client using Bedrock (via `AWS_REGION` + Bedrock config)
- [ ] AWS: Filesystem operations using S3 helpers (S3 paths)
- [ ] AWS: ECS deployment works end-to-end
- [ ] AWS: Factory creates `AWSBedrockClient` correctly

### Cross-Environment:
- [ ] Multi-environment: Verify no AWS imports in environment-agnostic code
- [ ] Multi-environment: Factory pattern works for all environments
- [ ] Multi-environment: Filesystem abstraction works for all storage types
- [ ] All existing functionality still works in both local and AWS
- [ ] No dead code remains
- [ ] Dependencies are minimal and correct
- [ ] All files have environment comments
- [ ] Backward compatibility maintained (convenience function `claude_complete()`)

---

## 11. Environment-Specific Considerations

### Local Development:
- **File System**: Uses `os.path.*` directly (standard Python)
- **Database**: PostgreSQL via Docker Compose (local connection)
- **LLM**: Claude API directly (via `CLAUDE_API_KEY`) OR Bedrock (via `AWS_PROFILE`)
- **Delta Tables**: Local path (`data/delta/fru_sales`)
- **Storage**: Local file system (no abstraction needed, but wrapper for consistency)

### AWS Production:
- **File System**: S3 (via boto3) or EFS (mounted, uses `os.path.*`)
- **Database**: Aurora PostgreSQL (RDS) via psycopg2 OR RDS Data API
- **LLM**: AWS Bedrock (via IAM role in ECS/EKS)
- **Delta Tables**: S3 path (`s3://bucket/delta/fru_sales`)
- **Storage**: S3 (primary) or EFS (optional, for POSIX semantics)

### Key Differences:
1. **Local**: Claude API can be used without AWS account
2. **AWS**: Bedrock requires AWS account and IAM permissions
3. **Local**: Delta tables in local file system
4. **AWS**: Delta tables in S3 (requires boto3)
5. **Local**: `os.path.exists()` works directly
6. **AWS**: `os.path.exists()` doesn't work for S3 (needs boto3)

---

## 12. Risks and Considerations

### Risks:
1. **Breaking changes** - Need careful import updates
2. **S3 implementation** - Must handle S3 paths correctly
3. **Local vs AWS differences** - Must maintain compatibility for both
4. **Backward compatibility** - Existing deployments may need updates
5. **Factory Pattern migration** - Need to ensure all callers updated

### Mitigations:
1. **Gradual migration** - Keep old imports working temporarily via convenience function
2. **Comprehensive testing** - Test all paths in both local and AWS before removing old code
3. **Clear documentation** - Document new structure, migration path, and environment differences
4. **Environment detection** - Automatic detection (path-based, env var-based) reduces configuration
5. **Backward compatibility** - Provide `claude_complete()` convenience function for gradual migration

---

## Next Steps

1. **Review and approve this plan**
2. **Execute Phase 1**: Create infrastructure and Factory Pattern
   - Step 1.1: Create file system abstraction
   - Step 1.2: Create LLM Factory Pattern
   - Step 1.3: Move environment-specific code
   - Step 1.4: Update application code to use factory
   - Step 1.5: Reorganize services directory
3. **Execute Phase 2**: Add environment comments and documentation
   - Step 2.1: Add environment comments to all files
   - Step 2.2: Update documentation
4. **Execute Phase 3**: Remove dead code and clean up
   - Step 3.1: Remove unused files
   - Step 3.2: Clean up imports
   - Step 3.3: Clean up dependencies
5. **Test thoroughly** in both local and AWS environments
6. **Update documentation** and migration guides

---

**Status:** 📋 Plan created, awaiting approval before execution

---

## 12. Delta Table Verification Logic Consolidation (Future)

### 📋 Overview
There is significant functional overlap between Python-based verification (runtime) and shell script-based verification (setup/deployment). Both implementations need to be kept (different contexts), but should follow unified logic patterns.

**Analysis Document**: See `cursor_gen/DELTA_TABLE_VERIFICATION_ANALYSIS.md` for detailed analysis.

### 🔍 Key Findings

#### Overlap:
- Both check for `_delta_log` directory existence
- Both support S3 and local filesystem paths
- Both handle path construction (absolute vs relative)

#### Differences:
- **Python**: Runs in containers at runtime, uses boto3
- **Shell**: Runs during setup/deployment, uses AWS CLI
- **Cannot replace each other** due to different execution contexts

#### Issues Found:
1. ✅ **FIXED**: Python normalizes `s3a://` → `s3://` (boto3 compatibility)
2. ❌ **TODO**: Shell scripts don't normalize `s3a://` → `s3://`
3. ⚠️ **Consider**: Shell scripts validate log file count; Python only checks existence
4. ⚠️ **Consider**: Different error handling (exceptions vs exit codes)

### 📝 Action Items (Future)

#### Immediate (High Priority):
1. **Fix shell script `s3a://` support**
   - Update `run_scripts/common/delta-lake/helpers/check-delta-table-exists.sh`
   - Normalize `s3a://` → `s3://` before AWS CLI calls
   - Match Python implementation

2. **Consider adding log file validation to Python**
   - Optional check for `.json` file count in `_delta_log`
   - Match shell script validation depth
   - Make it optional to not break existing behavior

#### Medium-Term:
3. **Create verification specification document**
   - Define what "valid Delta table" means
   - Document path normalization rules
   - Document error handling expectations
   - Single source of truth for both implementations

4. **Add integration tests**
   - Test both implementations against same Delta tables
   - Verify they produce same results
   - Catch regressions early

5. **Improve logging consistency**
   - Align log message formats
   - Use same terminology
   - Ensure same information is logged

### 🎯 Implementation Notes

**Python Normalization** (current):
```python
# backend/utils/filesystem.py line 46
normalized_path = path.replace('s3a://', 's3://', 1) if path.startswith('s3a://') else path
```

**Shell Script Needed**:
```bash
# Normalize s3a:// to s3:// for AWS CLI (which only supports s3://)
if [[ "$PATH_TO_CHECK" == s3a://* ]]; then
    PATH_TO_CHECK="${PATH_TO_CHECK/s3a:\/\//s3:\/\/}"
fi
```

**Status:** 📋 Planned for future refactoring phase
