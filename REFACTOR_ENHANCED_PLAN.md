# Enhanced Refactor Plan: Centralize Spark & Delta Lake Logic

## Executive Summary

This enhanced plan centralizes **all Spark and Delta Lake logic** into `spark_jobs/` and reorganizes deployment scripts into `run_scripts/spark_delta-lake_scripts/`. The backend API will **only** interact with PostgreSQL `batch_analytics` table, not Spark/Delta Lake directly.

---

## 1. Core Principle

**Separation of Concerns**:
- **Backend API** (`backend/api/app.py`): 
  - ✅ Reads from PostgreSQL `batch_analytics` table
  - ✅ Provides `/analytics` endpoint
  - ❌ Does NOT know about Spark, Delta Lake, S3, or Delta tables
  - ❌ Does NOT start Spark scheduler (moved to separate process/script)

- **Spark Jobs** (`spark_jobs/`):
  - ✅ All Spark/Delta Lake logic
  - ✅ Delta table verification
  - ✅ Spark job execution
  - ✅ Analytics computation
  - ✅ Saving results to PostgreSQL
  - ✅ Scheduler (runs Spark jobs periodically)

- **Deployment Scripts** (`run_scripts/spark_delta-lake_scripts/`):
  - ✅ Spark setup
  - ✅ Delta Lake setup
  - ✅ Data population
  - ✅ Infrastructure verification

---

## 2. Current State Analysis

### 2.1 Backend Files That Need to Move

| File | Current Location | Purpose | Move To |
|------|-----------------|---------|---------|
| `scheduler.py` | `backend/services/analytics/` | Runs Spark analytics periodically | `spark_jobs/scheduler.py` |
| `verify_delta_table.py` | `backend/services/analytics/` | Verifies Delta table exists | `spark_jobs/utils/verify_delta_table.py` |
| `save_to_db.py` | `backend/services/analytics/` | Saves analytics to PostgreSQL | `spark_jobs/utils/save_to_db.py` |
| `filesystem.py` | `backend/utils/` | File system abstraction (S3/local) | `spark_jobs/utils/filesystem.py` |
| `s3_helpers.py` | `backend/env_utils/aws/` | S3 operations | `spark_jobs/utils/s3_helpers.py` |
| `filesystem.py` | `backend/env_utils/local/` | Local filesystem wrapper | **DELETE** (not needed, use `os.path` directly) |

### 2.2 Backend API Current Dependencies

**`backend/api/app.py`**:
- Line 24: `from backend.services.analytics.scheduler import start_analytics_scheduler`
- Line 802-816: Starts scheduler if `ENABLE_ANALYTICS_SCHEDULER=true`
- Line 311-312: `/analytics` endpoint (reads from PostgreSQL only)

**After Refactor**:
- ❌ Remove scheduler import
- ❌ Remove scheduler startup code
- ✅ Keep `/analytics` endpoint (reads PostgreSQL only)
- ✅ Scheduler runs as separate process/script (not in Flask app)

### 2.3 Scripts That Need Reorganization

| Current Location | Purpose | Move To |
|-----------------|---------|---------|
| `run_scripts/common/delta-lake/` | Delta Lake setup/verify scripts | `run_scripts/spark_delta-lake_scripts/common/delta-lake/` |
| `run_scripts/common/spark/` | Spark setup scripts | `run_scripts/spark_delta-lake_scripts/common/spark/` |
| `run_scripts/aws/delta-lake/` | AWS Delta Lake orchestrator | `run_scripts/spark_delta-lake_scripts/aws/delta-lake/` |
| `run_scripts/local/delta-lake/` | Local Delta Lake orchestrator | `run_scripts/spark_delta-lake_scripts/local/delta-lake/` |

---

## 3. Proposed New Structure

### 3.1 `spark_jobs/` Structure (After Refactor)

```
spark_jobs/
├── ingest_delta.py                    # ✅ Keep (creates Delta table from CSV)
├── run_analytics.py                    # ✅ Keep (runs analytics)
├── generate_training_data.py           # ✅ Keep (generates NLQ training data)
├── spark_helper.py                     # ✅ Keep (debugging utilities)
│
├── scheduler.py                        # 🆕 MOVED from backend/services/analytics/
│   └── Runs Spark jobs periodically (APScheduler)
│
└── utils/                              # 🆕 NEW directory
    ├── __init__.py
    ├── verify_delta_table.py           # 🆕 MOVED from backend/services/analytics/
    ├── save_to_db.py                   # 🆕 MOVED from backend/services/analytics/
    ├── filesystem.py                   # 🆕 MOVED from backend/utils/
    ├── s3_helpers.py                   # 🆕 MOVED from backend/env_utils/aws/
    └── spark_config.py                 # 🆕 NEW (centralized Spark config)
```

### 3.2 `run_scripts/spark_delta-lake_scripts/` Structure (After Refactor)

```
run_scripts/spark_delta-lake_scripts/
├── common/
│   ├── delta-lake/
│   │   ├── setup-delta-lake.sh         # ✅ MOVED from run_scripts/common/delta-lake/
│   │   ├── verify-delta-lake.sh         # ✅ MOVED
│   │   ├── create-delta-table.sh       # ✅ MOVED
│   │   └── helpers/
│   │       ├── check-delta-table-exists.sh
│   │       ├── local/
│   │       └── aws/
│   │
│   └── spark/
│       ├── setup-spark.sh              # ✅ MOVED from run_scripts/common/spark/
│       ├── setup-spark-local.sh        # ✅ MOVED
│       └── setup-spark-aws.sh          # ✅ MOVED
│
├── aws/
│   └── delta-lake/
│       └── setup-and-verify.sh         # ✅ MOVED from run_scripts/aws/delta-lake/
│
└── local/
    └── delta-lake/
        └── setup-and-verify.sh         # ✅ MOVED from run_scripts/local/delta-lake/
```

### 3.3 `backend/` Structure (After Refactor)

```
backend/
├── api/
│   └── app.py                          # ✅ Keep, but remove scheduler code
│       └── Only has /analytics endpoint (reads PostgreSQL)
│
├── services/
│   └── analytics/                      # ❌ DELETE (moved to spark_jobs/)
│
├── utils/
│   └── filesystem.py                   # ❌ DELETE (moved to spark_jobs/utils/)
│
└── env_utils/
    ├── aws/
    │   └── s3_helpers.py               # ❌ DELETE (moved to spark_jobs/utils/)
    └── local/
        └── filesystem.py               # ❌ DELETE (not needed)
```

---

## 4. Detailed Refactoring Steps

### Phase 1: Create New Structure in `spark_jobs/`

#### Step 1.1: Create `spark_jobs/utils/` Directory
```bash
mkdir -p spark_jobs/utils
touch spark_jobs/utils/__init__.py
```

#### Step 1.2: Move Files from `backend/` to `spark_jobs/`

**Move `backend/services/analytics/scheduler.py` → `spark_jobs/scheduler.py`**:
- Update imports:
  - `from backend.services.analytics.verify_delta_table` → `from spark_jobs.utils.verify_delta_table`
  - `from backend.utils.env_helpers` → Keep (env_helpers is still in backend, used by API too)
- Update paths (repo_root calculation)
- **Key Change**: Make it a standalone script that can be run independently (not imported by Flask)

**Move `backend/services/analytics/verify_delta_table.py` → `spark_jobs/utils/verify_delta_table.py`**:
- Update imports:
  - `from backend.utils.filesystem` → `from spark_jobs.utils.filesystem`
  - `from backend.utils.env_helpers` → Keep (shared utility)

**Move `backend/services/analytics/save_to_db.py` → `spark_jobs/utils/save_to_db.py`**:
- Update imports:
  - `from backend.utils.env_helpers` → Keep (shared utility)
- No other changes needed

**Move `backend/utils/filesystem.py` → `spark_jobs/utils/filesystem.py`**:
- Update imports:
  - `from backend.env_utils.aws.s3_helpers` → `from spark_jobs.utils.s3_helpers`

**Move `backend/env_utils/aws/s3_helpers.py` → `spark_jobs/utils/s3_helpers.py`**:
- No import changes needed (uses boto3, urllib.parse)

**Delete `backend/env_utils/local/filesystem.py`**:
- Not needed (just wraps `os.path`, can use directly)

#### Step 1.3: Create `spark_jobs/utils/spark_config.py` (NEW)
```python
"""
Centralized Spark configuration.
Single source of truth for S3A config and Spark packages.
"""
import os
from typing import List

def get_s3a_spark_config() -> List[str]:
    """Returns S3A configuration flags for Spark."""
    return [
        "--conf", "spark.hadoop.fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem",
        "--conf", "spark.hadoop.fs.s3a.aws.credentials.provider=org.apache.hadoop.fs.s3a.auth.IAMInstanceCredentialsProvider",
        "--conf", "spark.hadoop.fs.s3a.connection.timeout=60000",
        "--conf", "spark.hadoop.fs.s3a.connection.establish.timeout=5000",
        "--conf", "spark.hadoop.fs.s3a.connection.maximum=15",
        "--conf", "spark.hadoop.fs.s3a.attempts.maximum=3",
        "--conf", "spark.hadoop.fs.s3a.retry.interval=1000",
        "--conf", "spark.hadoop.fs.s3a.threads.max=10",
        "--conf", "spark.hadoop.fs.s3a.threads.core=5",
        "--conf", "spark.hadoop.fs.s3a.threads.keepalivetime=60",
        "--conf", "spark.hadoop.fs.s3a.multipart.uploads.expiration=86400",
        "--conf", "spark.hadoop.fs.s3a.multipart.purge.age=86400",
        "--conf", "spark.hadoop.fs.s3a.fast.upload=true",
        "--conf", "spark.hadoop.fs.s3a.block.size=134217728",
    ]

def get_spark_packages(is_aws_deployment: bool) -> str:
    """Returns Spark packages string."""
    base = os.getenv("DELTA_LAKE_PACKAGE")
    if not base:
        raise ValueError("DELTA_LAKE_PACKAGE environment variable is required")
    
    if is_aws_deployment:
        return f"{base},org.apache.hadoop:hadoop-aws:3.3.6,com.amazonaws:aws-java-sdk-bundle:1.12.470"
    return base

def to_spark_path(path: str) -> str:
    """Convert s3:// to s3a:// for Spark compatibility."""
    return path.replace("s3://", "s3a://", 1) if path.startswith("s3://") else path
```

#### Step 1.4: Update `spark_jobs/run_analytics.py`
- Update import:
  - `from backend.services.analytics.save_to_db` → `from spark_jobs.utils.save_to_db`
- Use `spark_jobs.utils.spark_config.to_spark_path()` for path conversion

#### Step 1.5: Update `spark_jobs/scheduler.py` (moved file)
- Use `spark_jobs.utils.spark_config` for S3A config and packages
- Update all imports to use `spark_jobs.utils.*`

### Phase 2: Update Backend API

#### Step 2.1: Remove Scheduler from `backend/api/app.py`
- **Remove** line 24: `from backend.services.analytics.scheduler import start_analytics_scheduler`
- **Remove** lines 802-816: Scheduler startup code
- **Keep** lines 311-312: `/analytics` endpoint (reads PostgreSQL only)

**New `backend/api/app.py` (scheduler section)**:
```python
# Analytics endpoint - reads from PostgreSQL batch_analytics table
# Spark scheduler runs as separate process (see spark_jobs/scheduler.py)
@app.route("/analytics", methods=["GET"])
def get_analytics():
    """Get latest batch analytics results from PostgreSQL."""
    # ... existing code (no changes) ...
```

#### Step 2.2: Create Standalone Scheduler Entry Point

**New `spark_jobs/run_scheduler.py`**:
```python
"""
Standalone entry point for Spark analytics scheduler.
Can be run independently of Flask app.

Usage:
    python -m spark_jobs.run_scheduler
    # Or: python spark_jobs/run_scheduler.py
"""
import os
import sys
import logging
from spark_jobs.scheduler import start_analytics_scheduler
from backend.utils.env_helpers import get_optional_bool_env, get_required_int_env

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

if __name__ == "__main__":
    enable_scheduler = get_optional_bool_env("ENABLE_ANALYTICS_SCHEDULER", False)
    
    if not enable_scheduler:
        logger.info("Analytics scheduler disabled. Set ENABLE_ANALYTICS_SCHEDULER=true to enable.")
        sys.exit(0)
    
    try:
        scheduler_interval_seconds = get_required_int_env(
            "ANALYTICS_SCHEDULER_INTERVAL_SECONDS",
            "Analytics scheduler interval in seconds (required when ENABLE_ANALYTICS_SCHEDULER=true)"
        )
        scheduler = start_analytics_scheduler(interval_seconds=scheduler_interval_seconds)
        logger.info(f"Analytics scheduler started (runs every {scheduler_interval_seconds} seconds)")
        
        # Keep process alive
        import time
        try:
            while True:
                time.sleep(60)
        except KeyboardInterrupt:
            logger.info("Stopping scheduler...")
            scheduler.shutdown()
    except Exception as e:
        logger.error(f"Failed to start analytics scheduler: {e}", exc_info=True)
        sys.exit(1)
```

### Phase 3: Reorganize Scripts

#### Step 3.1: Create New Directory Structure
```bash
mkdir -p run_scripts/spark_delta-lake_scripts/{common/{delta-lake,spark},aws/delta-lake,local/delta-lake}
```

#### Step 3.2: Move Scripts
```bash
# Move common scripts
mv run_scripts/common/delta-lake/* run_scripts/spark_delta-lake_scripts/common/delta-lake/
mv run_scripts/common/spark/* run_scripts/spark_delta-lake_scripts/common/spark/

# Move environment-specific scripts
mv run_scripts/aws/delta-lake/* run_scripts/spark_delta-lake_scripts/aws/delta-lake/
mv run_scripts/local/delta-lake/* run_scripts/spark_delta-lake_scripts/local/delta-lake/
```

#### Step 3.3: Update Script Paths in `run.sh` Files

**`run_scripts/local/run.sh`**:
- Update Step 7.5:
  ```bash
  # OLD:
  "$SCRIPT_DIR/delta-lake/setup-and-verify.sh"
  
  # NEW:
  "$SCRIPT_DIR/../spark_delta-lake_scripts/local/delta-lake/setup-and-verify.sh"
  ```

**`run_scripts/aws/run.sh`**:
- Update Step 3.7:
  ```bash
  # OLD:
  "$SCRIPT_DIR/delta-lake/setup-and-verify.sh"
  
  # NEW:
  "$SCRIPT_DIR/../spark_delta-lake_scripts/aws/delta-lake/setup-and-verify.sh"
  ```

#### Step 3.4: Update Script Internal Paths

All scripts that reference `run_scripts/common/` need to update paths:
- `setup-and-verify.sh` scripts → Update paths to `run_scripts/spark_delta-lake_scripts/common/`
- Helper scripts → Update relative paths

### Phase 4: Update Docker Configuration

#### Step 4.1: Update Dockerfile to Run Scheduler Separately

**Option A: Run scheduler in same container (separate process)**
```dockerfile
# Add to Dockerfile.api
# Create entrypoint script that runs both Flask and scheduler
COPY scripts/docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh
ENTRYPOINT ["/app/docker-entrypoint.sh"]
```

**New `scripts/docker-entrypoint.sh`**:
```bash
#!/bin/bash
set -e

# Start scheduler in background (if enabled)
if [ "${ENABLE_ANALYTICS_SCHEDULER}" = "true" ]; then
    python -m spark_jobs.run_scheduler &
    SCHEDULER_PID=$!
    echo "Analytics scheduler started (PID: $SCHEDULER_PID)"
fi

# Start Flask app
exec python -m backend.api.app
```

**Option B: Run scheduler in separate container** (more complex, better isolation)

#### Step 4.2: Update docker-compose.yml
- No changes needed if using Option A (same container, separate process)
- If using Option B, add separate scheduler service

### Phase 5: Update Shell Scripts to Use Python Helpers

#### Step 5.1: Update `run-spark-job-aws.sh`
- Get S3A config from Python:
  ```bash
  S3A_CONFIG=$(python3 -c "
  import sys
  sys.path.insert(0, '$REPO_ROOT')
  from spark_jobs.utils.spark_config import get_s3a_spark_config
  import shlex
  print(' '.join(shlex.quote(arg) for arg in get_s3a_spark_config()))
  ")
  ```

#### Step 5.2: Update `setup-and-verify.sh` (AWS)
- Get Spark packages from Python:
  ```bash
  SPARK_PACKAGES=$(python3 -c "
  import sys
  sys.path.insert(0, '$REPO_ROOT')
  from spark_jobs.utils.spark_config import get_spark_packages
  print(get_spark_packages(is_aws_deployment=True))
  ")
  ```

#### Step 5.3: Update `check-delta-table-exists.sh`
- Call Python helper:
  ```bash
  python3 -c "
  import sys
  sys.path.insert(0, '$REPO_ROOT')
  from spark_jobs.utils.verify_delta_table import verify_delta_table_exists
  import os
  exit(0 if verify_delta_table_exists('$PATH', '$REPO_ROOT', $IS_AWS, False) else 1)
  "
  ```

---

## 5. Dependency Graph After Refactor

```
┌─────────────────────────────────────────────────────────────┐
│ Backend API (backend/api/app.py)                            │
│                                                             │
│  ✅ Reads from PostgreSQL batch_analytics table             │
│  ✅ Provides /analytics endpoint                            │
│  ❌ No Spark/Delta Lake dependencies                        │
└─────────────────────────────────────────────────────────────┘
                          │
                          │ (reads data written by)
                          ▼
┌─────────────────────────────────────────────────────────────┐
│ PostgreSQL batch_analytics table                            │
│                                                             │
│  Stores analytics results (JSONB)                          │
└─────────────────────────────────────────────────────────────┘
                          ▲
                          │ (writes to)
                          │
┌─────────────────────────────────────────────────────────────┐
│ Spark Jobs (spark_jobs/)                                    │
│                                                             │
│  scheduler.py                                               │
│    ├── Uses: spark_jobs/utils/spark_config.py              │
│    ├── Uses: spark_jobs/utils/verify_delta_table.py        │
│    └── Calls: spark_jobs/run_analytics.py                  │
│                                                             │
│  run_analytics.py                                           │
│    ├── Uses: spark_jobs/utils/save_to_db.py               │
│    └── Uses: spark_jobs/utils/spark_config.py             │
│                                                             │
│  utils/                                                     │
│    ├── spark_config.py (NEW)                               │
│    ├── verify_delta_table.py                               │
│    │   └── Uses: spark_jobs/utils/filesystem.py            │
│    ├── save_to_db.py                                       │
│    ├── filesystem.py                                       │
│    │   └── Uses: spark_jobs/utils/s3_helpers.py           │
│    └── s3_helpers.py                                       │
└─────────────────────────────────────────────────────────────┘
                          │
                          │ (uses)
                          ▼
┌─────────────────────────────────────────────────────────────┐
│ Deployment Scripts                                          │
│ (run_scripts/spark_delta-lake_scripts/)                     │
│                                                             │
│  setup-and-verify.sh                                       │
│    ├── Calls: common/delta-lake/create-delta-table.sh      │
│    └── Calls: Python helpers (spark_config, verify)        │
│                                                             │
│  create-delta-table.sh                                     │
│    └── Calls: helpers/run-spark-job-*.sh                  │
│                                                             │
│  run-spark-job-*.sh                                        │
│    └── Calls: Python helpers (spark_config)                │
└─────────────────────────────────────────────────────────────┘
```

---

## 6. Benefits of This Refactor

### 6.1 Clear Separation of Concerns
- ✅ Backend API: Only PostgreSQL, no Spark knowledge
- ✅ Spark Jobs: All Spark/Delta Lake logic centralized
- ✅ Deployment Scripts: All setup logic in one place

### 6.2 Easier Maintenance
- ✅ Single location for Spark/Delta Lake code
- ✅ No confusion about where Spark logic lives
- ✅ Easier to test Spark jobs independently

### 6.3 Better Scalability
- ✅ Scheduler can run in separate container/process
- ✅ Backend API can scale independently
- ✅ Spark jobs can be triggered externally (not just scheduler)

### 6.4 Reduced Dependencies
- ✅ Backend API has fewer dependencies
- ✅ Spark jobs are self-contained
- ✅ Clearer dependency graph

---

## 7. Migration Checklist

### Phase 1: Create New Structure
- [ ] Create `spark_jobs/utils/` directory
- [ ] Move `backend/services/analytics/scheduler.py` → `spark_jobs/scheduler.py`
- [ ] Move `backend/services/analytics/verify_delta_table.py` → `spark_jobs/utils/verify_delta_table.py`
- [ ] Move `backend/services/analytics/save_to_db.py` → `spark_jobs/utils/save_to_db.py`
- [ ] Move `backend/utils/filesystem.py` → `spark_jobs/utils/filesystem.py`
- [ ] Move `backend/env_utils/aws/s3_helpers.py` → `spark_jobs/utils/s3_helpers.py`
- [ ] Delete `backend/env_utils/local/filesystem.py`
- [ ] Create `spark_jobs/utils/spark_config.py`
- [ ] Update all imports in moved files

### Phase 2: Update Backend API
- [ ] Remove scheduler import from `backend/api/app.py`
- [ ] Remove scheduler startup code from `backend/api/app.py`
- [ ] Create `spark_jobs/run_scheduler.py` (standalone entry point)
- [ ] Test `/analytics` endpoint still works

### Phase 3: Reorganize Scripts
- [ ] Create `run_scripts/spark_delta-lake_scripts/` structure
- [ ] Move all delta-lake scripts
- [ ] Move all spark scripts
- [ ] Update paths in `run_scripts/local/run.sh`
- [ ] Update paths in `run_scripts/aws/run.sh`
- [ ] Update internal script paths

### Phase 4: Update Docker
- [ ] Create `scripts/docker-entrypoint.sh` (if using Option A)
- [ ] Update `Dockerfile.api` to use entrypoint script
- [ ] Test scheduler runs in Docker

### Phase 5: Consolidate Config
- [ ] Update `run-spark-job-aws.sh` to use Python config
- [ ] Update `setup-and-verify.sh` to use Python config
- [ ] Update `check-delta-table-exists.sh` to use Python helper
- [ ] Remove mode logic (`standalone` vs `full-workflow`)

### Phase 6: Testing
- [ ] Test local deployment (run.sh)
- [ ] Test AWS deployment (run.sh ecs-full)
- [ ] Test scheduler runs independently
- [ ] Test `/analytics` endpoint
- [ ] Test Delta table creation
- [ ] Test analytics computation

### Phase 7: Cleanup
- [ ] Delete old `backend/services/analytics/` directory
- [ ] Delete old `backend/utils/filesystem.py`
- [ ] Delete old `backend/env_utils/aws/s3_helpers.py`
- [ ] Delete old `backend/env_utils/local/filesystem.py`
- [ ] Delete old script directories (after confirming new ones work)
- [ ] Update documentation

---

## 8. Risk Assessment

### Low Risk
- Moving files (mechanical, just update imports)
- Reorganizing scripts (mechanical, just update paths)
- Removing scheduler from Flask app (scheduler runs separately)

### Medium Risk
- Import path updates (need to test all imports work)
- Docker entrypoint changes (need to test container starts correctly)
- Script path updates (need to test all scripts execute correctly)

### High Risk
- None identified (this is mostly reorganization, not functional changes)

---

## 9. Rollback Plan

If issues arise:
1. **Keep old directories** until new ones are fully tested
2. **Use feature flag** to switch between old/new scheduler location
3. **Gradual migration**: Move one module at a time, test, then move next

---

## 10. Timeline Estimate

- **Phase 1**: 2-3 hours (file moves + import updates)
- **Phase 2**: 1-2 hours (backend API updates)
- **Phase 3**: 2-3 hours (script reorganization)
- **Phase 4**: 1-2 hours (Docker updates)
- **Phase 5**: 2-3 hours (config consolidation)
- **Phase 6**: 4-6 hours (testing)
- **Phase 7**: 1-2 hours (cleanup)

**Total**: ~13-21 hours

---

## Conclusion

This enhanced refactor plan centralizes all Spark and Delta Lake logic into `spark_jobs/` and reorganizes deployment scripts into `run_scripts/spark_delta-lake_scripts/`. The backend API becomes a pure PostgreSQL consumer, with no Spark/Delta Lake dependencies.

The refactor maintains all existing functionality while improving code organization, maintainability, and scalability.

