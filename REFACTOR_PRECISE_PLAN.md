# Precise Refactoring Plan: What Stays Shell, What Goes Python

## Clarification: NOT Moving Everything to Python

**I am NOT proposing to replace all shell scripts with Python.** The refactoring is about **consolidating duplicated logic** and **simplifying mode complexity**, not rewriting everything.

---

## What STAYS as Shell Scripts (No Changes)

### ✅ `run_scripts/common/delta-lake/` - **KEEP AS SHELL**

**All scripts remain shell scripts:**
- `setup-delta-lake.sh` - Router script (stays shell)
- `verify-delta-lake.sh` - Router script (stays shell)
- `create-delta-table.sh` - Core orchestrator (stays shell, but simplify mode logic)
- `helpers/local/setup-delta-lake-local.sh` - Directory creation (stays shell)
- `helpers/local/run-spark-job-local.sh` - Spark execution (stays shell)
- `helpers/local/verify-infrastructure-local.sh` - Verification (stays shell, but call Python helper)
- `helpers/aws/setup-delta-lake-aws.sh` - Terraform output (stays shell)
- `helpers/aws/run-spark-job-aws.sh` - ECS task execution (stays shell, but use Python config)
- `helpers/aws/verify-infrastructure-aws.sh` - S3 verification (stays shell, but call Python helper)

**Why keep as shell?**
- These are deployment/setup scripts that run on host machines
- Shell is appropriate for orchestrating external tools (Terraform, AWS CLI, Docker, spark-submit)
- No need to rewrite working shell scripts

### ✅ `run_scripts/common/spark/` - **KEEP AS SHELL**

**All scripts remain shell scripts:**
- `setup-spark.sh` - Router script (stays shell)
- `setup-spark-local.sh` - Local Spark setup (stays shell)
- `setup-spark-aws.sh` - AWS Spark setup (stays shell, or remove if truly no-op)

**Why keep as shell?**
- These are environment setup scripts
- Shell is appropriate for checking system tools, setting PATH, etc.

### ✅ `run_scripts/aws/delta-lake/setup-and-verify.sh` - **KEEP AS SHELL**

**Stays shell script:**
- Orchestrates 3-step workflow (stays shell)
- Calls common scripts (stays shell)
- Only change: Remove `DATA_LAKE_SETUP_MODE` export

### ✅ `run_scripts/local/delta-lake/setup-and-verify.sh` - **KEEP AS SHELL**

**Stays shell script:**
- Orchestrates 3-step workflow (stays shell)
- Calls common scripts (stays shell)
- Only change: Remove `DATA_LAKE_SETUP_MODE` export

### ✅ `spark_jobs/` - **ALREADY PYTHON, NO CHANGES**

**These are already Python and stay Python:**
- `ingest_delta.py` - No changes
- `run_analytics.py` - Minor: Use centralized path conversion helper
- `generate_training_data.py` - No changes
- `spark_helper.py` - No changes

---

## What GETS CREATED in Python (New Files)

### 🆕 `backend/utils/spark_config.py` - **NEW PYTHON MODULE**

**Purpose**: Centralize Spark configuration that's currently duplicated

**Functions to add:**
```python
def get_s3a_spark_config() -> List[str]:
    """Returns S3A configuration flags for Spark (currently duplicated in bash and Python)"""
    return [
        "--conf", "spark.hadoop.fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem",
        "--conf", "spark.hadoop.fs.s3a.aws.credentials.provider=org.apache.hadoop.fs.s3a.auth.IAMInstanceCredentialsProvider",
        # ... all other S3A configs
    ]

def get_spark_packages(is_aws_deployment: bool) -> str:
    """Returns Spark packages string (currently duplicated in bash and Python)"""
    base = os.getenv("DELTA_LAKE_PACKAGE")
    if is_aws_deployment:
        return f"{base},org.apache.hadoop:hadoop-aws:3.3.6,com.amazonaws:aws-java-sdk-bundle:1.12.470"
    return base
```

**Why Python?**
- This logic is already in Python (`scheduler.py`)
- Shell scripts can call Python to get these values
- Single source of truth

---

## What GETS MODIFIED (Shell Scripts Call Python Helpers)

### 🔧 `run_scripts/common/delta-lake/helpers/check-delta-table-exists.sh`

**Current**: Pure bash implementation
```bash
# Check for _delta_log directory
if [ -d "$PATH_TO_CHECK/_delta_log" ]; then
    # ... bash logic
fi
```

**After**: Call existing Python helper
```bash
# Call Python helper (backend already has this)
python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT')
from backend.services.analytics.verify_delta_table import verify_delta_table_exists
exit(0 if verify_delta_table_exists('$PATH_TO_CHECK', '$REPO_ROOT', $IS_AWS) else 1)
"
```

**Why?**
- Python helper already exists and works
- Avoids maintaining duplicate logic
- Shell script becomes a thin wrapper

### 🔧 `run_scripts/common/delta-lake/helpers/aws/run-spark-job-aws.sh`

**Current**: Hardcoded S3A config in bash
```bash
SPARK_CMD="/opt/spark/bin/spark-submit \
  --packages $SPARK_PACKAGES \
  --conf spark.hadoop.fs.s3a.impl=... \
  --conf spark.hadoop.fs.s3a.connection.timeout=60000 \
  # ... 10+ more --conf flags
"
```

**After**: Get config from Python module
```bash
# Get S3A config from Python
S3A_CONFIG=$(python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT')
from backend.utils.spark_config import get_s3a_spark_config
import shlex
print(' '.join(shlex.quote(arg) for arg in get_s3a_spark_config()))
")

SPARK_CMD="/opt/spark/bin/spark-submit \
  --packages $SPARK_PACKAGES \
  $S3A_CONFIG \
  /app/spark_jobs/ingest_delta.py $INPUT_PATH $OUTPUT_PATH"
```

**Why?**
- Eliminates duplication (same config in `scheduler.py`)
- Single source of truth
- Shell script still orchestrates, but config comes from Python

### 🔧 `run_scripts/aws/delta-lake/setup-and-verify.sh`

**Current**: Hardcoded Spark packages
```bash
export SPARK_PACKAGES="${DELTA_LAKE_PACKAGE},org.apache.hadoop:hadoop-aws:3.3.6,com.amazonaws:aws-java-sdk-bundle:1.12.470"
```

**After**: Get from Python
```bash
export SPARK_PACKAGES=$(python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT')
from backend.utils.spark_config import get_spark_packages
print(get_spark_packages(is_aws_deployment=True))
")
```

**Why?**
- Eliminates duplication (same logic in `scheduler.py`)
- Single source of truth

### 🔧 `run_scripts/common/delta-lake/create-delta-table.sh`

**Current**: Complex mode logic
```bash
if [ "$MODE" = "standalone" ]; then
    if [ "$TABLE_EXISTS" = true ]; then
        exit 0  # Skip
    fi
else
    if [ "$TABLE_EXISTS" = true ]; then
        # Verify and exit 0
    fi
fi
```

**After**: Simplified (remove mode, always idempotent)
```bash
# Always idempotent: skip if exists, create if not
if [ "$TABLE_EXISTS" = true ]; then
    log_info "Delta table already exists, skipping creation"
    exit 0
fi
# Create table...
```

**Why?**
- Mode logic is over-complicated
- Both modes do essentially the same thing
- Simplifies maintenance

### 🔧 `backend/services/analytics/scheduler.py`

**Current**: Hardcoded S3A config
```python
cmd.extend([
    "--conf", "spark.hadoop.fs.s3a.impl=...",
    # ... 10+ more --conf flags
])
```

**After**: Use centralized config
```python
from backend.utils.spark_config import get_s3a_spark_config, get_spark_packages

# Use centralized functions
spark_packages = get_spark_packages(is_aws_deployment=is_ecs_deployment)
cmd = [spark_submit, "--packages", spark_packages]

if is_ecs_deployment:
    cmd.extend(get_s3a_spark_config())
```

**Why?**
- Eliminates duplication
- Single source of truth

### 🔧 `spark_jobs/run_analytics.py`

**Current**: Inline path conversion
```python
spark_delta_path = delta_path.replace("s3://", "s3a://", 1) if delta_path.startswith("s3://") else delta_path
```

**After**: Use helper (optional, low priority)
```python
from backend.utils.filesystem import to_spark_path
spark_delta_path = to_spark_path(delta_path)
```

**Why?**
- Minor cleanup, not critical
- Centralizes path conversion logic

---

## Summary: What Changes

### Shell Scripts: **STAY SHELL, BUT:**
1. **Remove mode logic** (`standalone` vs `full-workflow`) - simplify to always idempotent
2. **Call Python helpers** for:
   - Delta table verification (use existing Python helper)
   - Spark S3A configuration (get from new Python module)
   - Spark packages (get from new Python module)

### Python: **ADD NEW MODULE:**
1. **Create `backend/utils/spark_config.py`** with:
   - `get_s3a_spark_config()` - Returns S3A config flags
   - `get_spark_packages(is_aws_deployment)` - Returns packages string

### Python: **MODIFY EXISTING:**
1. **`scheduler.py`** - Use new `spark_config.py` module instead of hardcoded config
2. **`run_analytics.py`** - Use path conversion helper (optional)

---

## Architecture After Refactoring

```
Shell Scripts (orchestration layer)
├── setup-and-verify.sh
│   ├── setup-delta-lake.sh
│   ├── create-delta-table.sh
│   │   └── run-spark-job-aws.sh ──┐
│   └── verify-delta-lake.sh        │
│       └── check-delta-table-exists.sh ──┐
│                                          │
Python (business logic layer)             │
├── backend/utils/spark_config.py ◄───────┼─── Called by shell scripts
│   ├── get_s3a_spark_config()            │
│   └── get_spark_packages()              │
├── backend/services/analytics/           │
│   ├── scheduler.py ◄────────────────────┘ Uses spark_config.py
│   └── verify_delta_table.py ◄──────────┘ Called by shell scripts
└── spark_jobs/
    └── run_analytics.py (uses spark_config.py)
```

**Key Principle**: Shell scripts remain for orchestration, but call Python for business logic that's duplicated or complex.

---

## What Does NOT Change

❌ **NOT converting shell scripts to Python**
❌ **NOT rewriting deployment scripts**
❌ **NOT changing spark_jobs/** (already Python)
❌ **NOT changing core orchestration flow**

✅ **ONLY consolidating duplicated logic**
✅ **ONLY simplifying mode complexity**
✅ **ONLY creating thin Python helpers that shell scripts can call**

---

## Example: Before vs After

### Before (Duplicated S3A Config)

**In `run-spark-job-aws.sh`:**
```bash
SPARK_CMD="/opt/spark/bin/spark-submit \
  --conf spark.hadoop.fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem \
  --conf spark.hadoop.fs.s3a.connection.timeout=60000 \
  # ... 10 more lines
"
```

**In `scheduler.py`:**
```python
cmd.extend([
    "--conf", "spark.hadoop.fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem",
    "--conf", "spark.hadoop.fs.s3a.connection.timeout=60000",
    # ... 10 more lines (duplicated!)
])
```

### After (Centralized)

**New `backend/utils/spark_config.py`:**
```python
def get_s3a_spark_config():
    return [
        "--conf", "spark.hadoop.fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem",
        "--conf", "spark.hadoop.fs.s3a.connection.timeout=60000",
        # ... single source of truth
    ]
```

**In `run-spark-job-aws.sh` (still shell):**
```bash
S3A_CONFIG=$(python3 -c "from backend.utils.spark_config import get_s3a_spark_config; ...")
SPARK_CMD="/opt/spark/bin/spark-submit $S3A_CONFIG ..."
```

**In `scheduler.py` (Python):**
```python
from backend.utils.spark_config import get_s3a_spark_config
cmd.extend(get_s3a_spark_config())
```

**Result**: Single source of truth, shell script calls Python helper, Python code imports Python module.

---

## Conclusion

**Shell scripts stay shell scripts.** They just call Python helpers for duplicated business logic. This is a **consolidation refactoring**, not a **rewrite refactoring**.

