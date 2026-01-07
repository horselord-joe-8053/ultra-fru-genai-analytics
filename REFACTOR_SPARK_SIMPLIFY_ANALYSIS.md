# Refactor Analysis: Delta Lake, Spark, and Analytics Services

## Executive Summary

This analysis examines the structure, purpose, and overlaps in the Delta Lake, Spark, and analytics-related code. The codebase shows significant duplication and complexity that can be simplified through strategic refactoring.

---

## 1. Structure and Purpose Analysis

### 1.1 `run_scripts/common/delta-lake/`

**Purpose**: Core Delta Lake setup and verification scripts that work across environments.

**Structure**:
- `setup-delta-lake.sh` - Router script (filesystem vs terraform)
- `verify-delta-lake.sh` - Router script (filesystem vs s3)
- `create-delta-table.sh` - **Core logic** for creating Delta tables from CSV
- `helpers/check-delta-table-exists.sh` - Shared helper to check if Delta table exists
- `helpers/local/` - Local filesystem implementations
  - `setup-delta-lake-local.sh` - Creates local directory structure
  - `run-spark-job-local.sh` - Runs Spark job locally or in Docker
  - `verify-infrastructure-local.sh` - Verifies local Delta table
- `helpers/aws/` - AWS S3 implementations
  - `setup-delta-lake-aws.sh` - Gets S3 bucket info from Terraform
  - `run-spark-job-aws.sh` - Runs Spark job on ECS (one-time task)
  - `verify-infrastructure-aws.sh` - Verifies S3 Delta table

**Key Observations**:
- `create-delta-table.sh` is the **core orchestrator** - it handles mode logic (`standalone` vs `full-workflow`)
- Environment-specific helpers are well-separated
- Router pattern is used for setup/verify methods

### 1.2 `run_scripts/common/spark/`

**Purpose**: Spark environment setup scripts.

**Structure**:
- `setup-spark.sh` - Router script (auto-detects provider)
- `setup-spark-local.sh` - Sets up Spark 4.0.1 locally (optional, idempotent)
- `setup-spark-aws.sh` - Placeholder/documentation only (Spark runs in container)

**Key Observations**:
- Local setup is **optional** (Spark runs in Docker container)
- AWS setup is essentially a no-op (Spark is containerized)
- Minimal complexity, but could be simplified further

### 1.3 `run_scripts/aws/delta-lake/`

**Purpose**: AWS-specific Delta Lake setup orchestrator.

**Structure**:
- `setup-and-verify.sh` - 3-step workflow:
  1. Setup infrastructure (S3 + IAM via Terraform)
  2. Create Delta table in S3
  3. Verify Delta table

**Key Observations**:
- Thin wrapper around common scripts
- Sets environment variables for AWS context
- Uses `full-workflow` mode by default when called from `run.sh`

### 1.4 `run_scripts/local/delta-lake/`

**Purpose**: Local-specific Delta Lake setup orchestrator.

**Structure**:
- `setup-and-verify.sh` - 3-step workflow (same as AWS):
  1. Setup directory structure
  2. Create Delta table from CSV
  3. Verify Delta table

**Key Observations**:
- Nearly identical to AWS version (only differs in paths and execution method)
- Uses `full-workflow` mode by default when called from `run.sh`

### 1.5 `spark_jobs/`

**Purpose**: Python Spark jobs for data processing.

**Structure**:
- `ingest_delta.py` - Creates Delta table from CSV
- `run_analytics.py` - Runs batch analytics and saves to PostgreSQL
- `generate_training_data.py` - Generates training data for NLQ
- `spark_helper.py` - Debugging utilities

**Key Observations**:
- Well-structured, minimal duplication
- `run_analytics.py` imports `save_analytics_to_db` from backend
- Path conversion logic (s3:// → s3a://) is duplicated in multiple places

### 1.6 `backend/services/analytics/`

**Purpose**: Backend services for analytics scheduling and database operations.

**Structure**:
- `scheduler.py` - Runs Spark analytics periodically (APScheduler)
- `save_to_db.py` - Saves analytics results to PostgreSQL
- `verify_delta_table.py` - Verifies Delta table exists (uses filesystem abstraction)

**Key Observations**:
- `scheduler.py` has complex logic for:
  - Detecting deployment type (ECS vs local)
  - Building Spark packages (adds S3A packages for AWS)
  - Configuring S3A settings (duplicated from `run-spark-job-aws.sh`)
- `verify_delta_table.py` uses `backend.utils.filesystem` abstraction

### 1.7 `backend/utils/filesystem.py`

**Purpose**: File system abstraction layer.

**Structure**:
- `detect_storage_type()` - Detects s3, efs, or local
- `exists()` - Checks if path exists (works for S3, local, EFS)
- `listdir()` - Lists directory contents
- `isdir()` - Checks if path is directory

**Key Observations**:
- Clean abstraction, delegates to `backend.env_utils.aws.s3_helpers`
- Handles s3a:// → s3:// normalization

### 1.8 `backend/env_utils/aws/s3_helpers.py`

**Purpose**: AWS S3-specific file operations.

**Structure**:
- `s3_exists()` - Checks if S3 path exists
- `s3_listdir()` - Lists S3 directory contents
- `s3_isdir()` - Checks if S3 path is directory

**Key Observations**:
- Low-level S3 operations using boto3
- Well-isolated, no duplication

---

## 2. Overlapping and Duplicate Logic

### 2.1 **Delta Table Existence Checking** (3 implementations)

**Locations**:
1. `run_scripts/common/delta-lake/helpers/check-delta-table-exists.sh` (bash)
2. `backend/services/analytics/verify_delta_table.py` (Python)
3. `run_scripts/common/delta-lake/helpers/local/verify-infrastructure-local.sh` (bash)
4. `run_scripts/common/delta-lake/helpers/aws/verify-infrastructure-aws.sh` (bash)

**Duplication**:
- All check for `_delta_log` directory
- Bash scripts use `find` or `aws s3 ls`
- Python script uses `backend.utils.filesystem.exists()`
- Logic is essentially the same, just different implementations

**Impact**: Medium - Different languages, but same logic

### 2.2 **S3A Configuration** (2 implementations)

**Locations**:
1. `run_scripts/common/delta-lake/helpers/aws/run-spark-job-aws.sh` (lines 88-103)
2. `backend/services/analytics/scheduler.py` (lines 128-143)

**Duplication**:
- Identical S3A configuration flags (connection timeout, retry, threads, etc.)
- Same pattern: adds S3A packages + configuration flags
- Both used for ECS deployments

**Impact**: High - Exact duplication, maintenance burden

### 2.3 **Path Conversion (s3:// → s3a://)** (3+ locations)

**Locations**:
1. `spark_jobs/run_analytics.py` (line 44)
2. `run_scripts/aws/delta-lake/setup-and-verify.sh` (lines 52-54)
3. `backend/utils/filesystem.py` (line 46) - but only for normalization, not conversion

**Duplication**:
- Same logic: `delta_path.replace("s3://", "s3a://", 1)`
- Needed because Spark uses s3a://, but AWS CLI uses s3://

**Impact**: Medium - Simple but repeated

### 2.4 **Spark Package Building** (2 locations)

**Locations**:
1. `run_scripts/aws/delta-lake/setup-and-verify.sh` (line 58)
2. `backend/services/analytics/scheduler.py` (lines 114-119)

**Duplication**:
- Both build Spark packages string: Delta Lake + S3A packages for AWS
- Same logic: if ECS deployment, add hadoop-aws and aws-java-sdk-bundle

**Impact**: Medium - Logic duplication

### 2.5 **Deployment Type Detection** (2 locations)

**Locations**:
1. `backend/services/analytics/scheduler.py` (lines 42-67)
2. `backend/services/analytics/verify_delta_table.py` (uses parameters)

**Duplication**:
- `scheduler.py` detects from `DEPLOYMENT_TYPE` env var
- `verify_delta_table.py` receives as parameters
- Both determine if S3-based or local

**Impact**: Low - Different contexts, but could be unified

### 2.6 **Mode Logic (standalone vs full-workflow)** (Multiple locations)

**Locations**:
1. `run_scripts/common/delta-lake/create-delta-table.sh` (lines 63-84)
2. `run_scripts/common/delta-lake/helpers/local/setup-delta-lake-local.sh` (lines 19-31)
3. `run_scripts/common/delta-lake/helpers/local/verify-infrastructure-local.sh` (lines 28-36)
4. `run_scripts/common/delta-lake/helpers/aws/verify-infrastructure-aws.sh` (lines 38-46)

**Duplication**:
- `standalone`: Skip if exists (idempotent)
- `full-workflow`: Verify and fail if doesn't exist
- Logic is scattered across multiple scripts

**Impact**: High - Complex conditional logic, hard to maintain

---

## 3. Linking Backend Services with Scripts

### 3.1 Purpose Alignment

**Backend Services (`backend/services/analytics/`)**:
- **Purpose**: Runtime operations (scheduling, verification, database saves)
- **Context**: Runs inside container (Docker/ECS)
- **Dependencies**: Uses filesystem abstraction, S3 helpers

**Scripts (`run_scripts/`)**:
- **Purpose**: Setup and deployment operations
- **Context**: Runs on host machine or in one-time ECS tasks
- **Dependencies**: Direct AWS CLI, Terraform, Spark submit

### 3.2 Overlaps and Synergies

**Overlap 1: Delta Table Verification**
- Scripts: `verify-delta-lake.sh` → `check-delta-table-exists.sh`
- Backend: `verify_delta_table.py` → `filesystem.exists()`
- **Synergy Opportunity**: Backend could use the same helper, or scripts could use Python helper

**Overlap 2: S3A Configuration**
- Scripts: `run-spark-job-aws.sh` builds S3A config
- Backend: `scheduler.py` builds same S3A config
- **Synergy Opportunity**: Extract to shared config file or Python module

**Overlap 3: Path Handling**
- Scripts: Convert s3:// → s3a:// in bash
- Backend: Convert s3:// → s3a:// in Python
- **Synergy Opportunity**: Centralize in filesystem abstraction

**Overlap 4: Deployment Detection**
- Scripts: Use environment variables (SETUP_METHOD, EXECUTION_METHOD)
- Backend: Use DEPLOYMENT_TYPE env var
- **Synergy Opportunity**: Unified deployment detection utility

### 3.3 "Fat" to Trim

1. **Mode Logic (`standalone` vs `full-workflow`)**:
   - **Current**: Complex conditional logic in multiple scripts
   - **Issue**: Unclear purpose, adds complexity
   - **Recommendation**: Simplify to single idempotent behavior

2. **Duplicate Verification Logic**:
   - **Current**: Bash scripts + Python script both verify Delta tables
   - **Issue**: Maintenance burden, potential inconsistencies
   - **Recommendation**: Use Python helper from scripts (via python -c) or consolidate

3. **S3A Configuration Duplication**:
   - **Current**: Identical config in bash script and Python
   - **Issue**: Changes must be made in two places
   - **Recommendation**: Extract to Python config module, import in both contexts

4. **Spark Package Building**:
   - **Current**: Logic duplicated in bash and Python
   - **Issue**: Inconsistency risk
   - **Recommendation**: Centralize in Python, call from bash if needed

---

## 4. Analysis of User's Questions

### 4.1 Core Goal Confirmation

**User's Understanding**: ✅ **Correct**

The goal is:
1. Setup Spark and Delta Lake, verify table exists
2. Load data into Delta Lake
3. Setup scheduled job for analytics
4. Store analytics results in PostgreSQL `batch_analytics` table

**Current Implementation**:
- ✅ Step 1: `setup-delta-lake.sh` + `create-delta-table.sh` + `verify-delta-lake.sh`
- ✅ Step 2: `ingest_delta.py` (called by `create-delta-table.sh`)
- ✅ Step 3: `scheduler.py` (runs `run_analytics.py` periodically)
- ✅ Step 4: `save_to_db.py` (called by `run_analytics.py`)

**Assessment**: Implementation matches goal, but complexity is high.

### 4.2 Local vs AWS Run.sh Differences

#### 4.2.1 Local `run.sh` - Combine Step 3.5 into Step 7.5?

**Current Structure**:
- **Step 3.5**: Setup Spark environment (optional)
- **Step 7.5**: Setup data-lake (Delta table)

**Analysis**:
- **Step 3.5** purpose: Setup local Spark installation (optional, Spark runs in Docker)
- **Step 7.5** purpose: Setup Delta Lake table (required if analytics enabled)
- **Relationship**: Step 3.5 is **independent** - it's for local Spark development, not required for Delta Lake setup
- **Recommendation**: ✅ **Yes, combine them** - Both are related to analytics/data-lake setup, and Step 3.5 is optional anyway

**Proposed**: Move Step 3.5 logic into Step 7.5 as a conditional check:
- If user wants local Spark: Setup Spark first, then Delta Lake
- Otherwise: Skip Spark setup, proceed to Delta Lake

#### 4.2.2 AWS `run.sh` - Missing Step 3.5 Equivalent?

**Current Structure**:
- **Step 3.7**: Setup data-lake (S3 + Delta table)
- **No Step 3.5**: No Spark setup step

**Analysis**:
- **Why no Step 3.5?**: Spark runs in ECS container (built into Docker image), no local setup needed
- **Step 3.7** corresponds to **Step 7.5** in local (both setup Delta Lake)
- **Assessment**: ✅ **Correct** - AWS doesn't need Step 3.5 because Spark is containerized

**However**: There's a **conceptual mismatch**:
- Local: Step 3.5 (Spark) + Step 7.5 (Delta Lake) = 2 separate steps
- AWS: Step 3.7 (Delta Lake only) = 1 step
- **Recommendation**: Keep as-is, but document why AWS doesn't need Spark setup step

### 4.3 `full-workflow` vs `standalone` Mode Analysis

**Current Usage**:
- `standalone`: Idempotent mode - skip if table exists
- `full-workflow`: Verification mode - fail if table doesn't exist

**Locations**:
- Set in `run_scripts/local/run.sh` line 215: `export DATA_LAKE_SETUP_MODE="full-workflow"`
- Set in `run_scripts/aws/run.sh` line 369: `export DATA_LAKE_SETUP_MODE="full-workflow"`
- Used in `create-delta-table.sh` lines 63-84

**Analysis**:

**Problem 1: Unclear Purpose**
- `standalone`: Sounds like "run independently", but actually means "idempotent"
- `full-workflow`: Sounds like "complete workflow", but actually means "strict verification"
- **Better names**: `idempotent` vs `strict` or `skip-if-exists` vs `fail-if-missing`

**Problem 2: Over-Complication**
- The difference is minimal:
  - `standalone`: If table exists → skip (exit 0)
  - `full-workflow`: If table exists → verify and exit 0 (same result!)
- Both modes create table if it doesn't exist
- The only real difference is error handling when verification fails

**Problem 3: Inconsistent Behavior**
- In `verify-infrastructure-local.sh` (line 28): `standalone` mode exits silently if table doesn't exist
- In `verify-infrastructure-aws.sh` (line 39): `standalone` mode exits silently if table doesn't exist
- In `create-delta-table.sh` (line 64): `standalone` mode skips if table exists
- **Inconsistency**: Verification scripts use mode differently than creation script

**Recommendation**: ✅ **Yes, it's over-complicated**

**Simplified Approach**:
1. **Single mode**: Always idempotent (skip if exists, create if not)
2. **Verification**: Always verify after creation (or if exists)
3. **Error handling**: Fail on verification errors (regardless of mode)

**Alternative (if mode is needed)**:
- `--force`: Recreate table even if exists
- `--verify-only`: Only verify, don't create
- Default: Idempotent create + verify

---

## 5. Refactoring Recommendations

### 5.1 High Priority

#### 5.1.1 Remove `full-workflow` vs `standalone` Mode
- **Action**: Simplify to single idempotent behavior
- **Impact**: Reduces complexity, eliminates confusion
- **Files to change**:
  - `create-delta-table.sh` - Remove mode logic
  - `setup-delta-lake-local.sh` - Remove mode logic
  - `verify-infrastructure-*.sh` - Remove mode logic
  - `run.sh` files - Remove `DATA_LAKE_SETUP_MODE` exports

#### 5.1.2 Consolidate S3A Configuration
- **Action**: Extract to Python config module
- **Impact**: Single source of truth, easier maintenance
- **New file**: `backend/utils/spark_config.py`
  ```python
  def get_s3a_spark_config():
      """Returns S3A configuration flags for Spark"""
      return [
          "--conf", "spark.hadoop.fs.s3a.impl=...",
          # ... all configs
      ]
  ```
- **Files to change**:
  - `run-spark-job-aws.sh` - Import and use Python config
  - `scheduler.py` - Import and use Python config

#### 5.1.3 Consolidate Spark Package Building
- **Action**: Extract to Python utility
- **Impact**: Single source of truth
- **New file**: `backend/utils/spark_config.py` (add function)
  ```python
  def get_spark_packages(is_aws_deployment: bool) -> str:
      """Returns Spark packages string"""
      base = os.getenv("DELTA_LAKE_PACKAGE")
      if is_aws_deployment:
          return f"{base},org.apache.hadoop:hadoop-aws:3.3.6,..."
      return base
  ```
- **Files to change**:
  - `setup-and-verify.sh` (AWS) - Use Python utility
  - `scheduler.py` - Use Python utility

### 5.2 Medium Priority

#### 5.2.1 Consolidate Delta Table Verification
- **Action**: Use Python helper from bash scripts
- **Impact**: Single implementation, consistent behavior
- **Approach**: Bash scripts call Python helper:
  ```bash
  python3 -c "from backend.services.analytics.verify_delta_table import verify_delta_table_exists; exit(0 if verify_delta_table_exists('$PATH', ...) else 1)"
  ```
- **Files to change**:
  - `check-delta-table-exists.sh` - Call Python helper
  - Remove duplicate logic from `verify-infrastructure-*.sh`

#### 5.2.2 Consolidate Path Conversion
- **Action**: Add to filesystem abstraction
- **Impact**: Single implementation
- **New function**: `backend/utils/filesystem.py`
  ```python
  def to_spark_path(path: str) -> str:
      """Convert s3:// to s3a:// for Spark compatibility"""
      return path.replace("s3://", "s3a://", 1) if path.startswith("s3://") else path
  ```
- **Files to change**:
  - `run_analytics.py` - Use helper
  - `setup-and-verify.sh` - Use Python helper or inline function

#### 5.2.3 Combine Step 3.5 and Step 7.5 in Local Run.sh
- **Action**: Merge Spark setup into Delta Lake setup step
- **Impact**: Cleaner workflow, less confusion
- **Files to change**:
  - `run_scripts/local/run.sh` - Remove Step 3.5, add Spark check to Step 7.5

### 5.3 Low Priority

#### 5.3.1 Unify Deployment Detection
- **Action**: Create shared deployment detection utility
- **Impact**: Consistent detection logic
- **New file**: `backend/utils/deployment.py`
  ```python
  def detect_deployment_type() -> Dict[str, bool]:
      """Returns deployment type flags"""
      deployment_type = os.getenv("DEPLOYMENT_TYPE", "").lower()
      return {
          "is_ecs": "ecs" in deployment_type,
          "is_eks": "eks" in deployment_type,
          "is_aws": "ecs" in deployment_type or "eks" in deployment_type,
          "is_local": not deployment_type
      }
  ```

#### 5.3.2 Simplify Spark Setup Scripts
- **Action**: Remove AWS Spark setup script (it's a no-op)
- **Impact**: Less confusion
- **Files to change**:
  - `setup-spark-aws.sh` - Remove or document as no-op more clearly

---

## 6. Proposed Simplified Architecture

### 6.1 Delta Lake Setup Flow

**Before** (Complex):
```
run.sh → setup-and-verify.sh → [setup-delta-lake.sh → helpers/*] → create-delta-table.sh → [mode logic] → run-spark-job-*.sh
```

**After** (Simplified):
```
run.sh → setup-and-verify.sh → [setup-delta-lake.sh → helpers/*] → create-delta-table.sh → run-spark-job-*.sh
                                                                    (always idempotent)
```

### 6.2 Verification Flow

**Before** (Duplicated):
```
verify-delta-lake.sh → verify-infrastructure-*.sh → check-delta-table-exists.sh (bash)
                                                      verify_delta_table.py (Python)
```

**After** (Unified):
```
verify-delta-lake.sh → verify-infrastructure-*.sh → check-delta-table-exists.sh → Python helper
```

### 6.3 Spark Configuration

**Before** (Duplicated):
```
run-spark-job-aws.sh: S3A config (bash)
scheduler.py: S3A config (Python, duplicated)
```

**After** (Centralized):
```
run-spark-job-aws.sh → Python config module
scheduler.py → Python config module
```

---

## 7. Implementation Plan

### Phase 1: Remove Mode Complexity (High Impact, Low Risk)
1. Remove `DATA_LAKE_SETUP_MODE` from all scripts
2. Simplify `create-delta-table.sh` to always be idempotent
3. Update `run.sh` files to remove mode exports
4. Test: Verify idempotent behavior works

### Phase 2: Consolidate S3A Configuration (High Impact, Medium Risk)
1. Create `backend/utils/spark_config.py`
2. Extract S3A config to Python module
3. Update `run-spark-job-aws.sh` to use Python config
4. Update `scheduler.py` to use Python config
5. Test: Verify Spark jobs work in both contexts

### Phase 3: Consolidate Verification (Medium Impact, Low Risk)
1. Update `check-delta-table-exists.sh` to call Python helper
2. Remove duplicate verification logic
3. Test: Verify both local and AWS verification work

### Phase 4: Combine Steps in Local Run.sh (Low Impact, Low Risk)
1. Merge Step 3.5 into Step 7.5
2. Test: Verify local setup still works

---

## 8. Conclusion

The codebase has significant duplication and complexity that can be simplified:

1. **Mode Logic**: Over-complicated, unclear purpose → **Remove**
2. **S3A Configuration**: Duplicated in bash and Python → **Centralize**
3. **Verification Logic**: Duplicated in bash and Python → **Unify**
4. **Step Organization**: Local has extra step → **Combine**

**Estimated Complexity Reduction**: ~30% reduction in code complexity, ~50% reduction in maintenance burden.

**Risk Level**: Low to Medium (changes are mostly consolidation, not functional changes)

**Recommended Approach**: Incremental refactoring, test after each phase.

