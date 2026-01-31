# Refactor Plan: Single venv for All Python in fru-genai-analytics-all

**Goal:** Install `requirements.txt` once (via one venv). Every script that runs Python uses that venv so dependencies (boto3, flask, pandas, etc.) are always resolved.

---

## 1. Current State

### 1.1 Where Python is used

| Category | Location | How Python is invoked | Uses venv? |
|----------|----------|------------------------|------------|
| **Root deps** | `requirements.txt` (root) | N/A | — |
| **Setup** | `run_scripts/.../local/setup-python.sh` | Creates `$REPO_ROOT/venv`, `pip install -r requirements.txt` | Yes (creates it) |
| **Already use venv** | `load_data_aws.sh`, `load_data_local.sh` | Check `$REPO_ROOT/venv`, `source …/activate`, then `python` | Yes |
| **Already use venv** | `check-delta-table-exists.sh` | `VENV_PYTHON="$REPO_ROOT/venv/bin/python3"`; use it if exists | Yes |
| **Hardcode python3** | `teardown-resources-all.sh` | `python3` for pre_destroy + cleanup_orphaned | **No** |
| **Hardcode python3** | `remove-all-aws-resources.sh` | `python3` (+ on-the-fly `pip install boto3`) | **No** |
| **Hardcode python3** | `ensure-release-address-policy.sh` | `exec python3 …` | **No** |
| **Hardcode python3** | `find-all-current-aws-resources.sh` | `PYTHON_CMD="python3 \"...\""` | **No** |
| **Inline python3 -c** | `reference_check_frontend_bucket.sh` | `python3 -c "..."` (json) | **No** |
| **Inline python3 -c** | `delete-recreatable-resources.sh` | `python3 -c "..."` (json) | **No** |
| **Inline python3 -c** | `stop-ecs-services.sh` | `python3 -c "..."` (json) | **No** |
| **Inline python3** | `kubernetes-manifests.sh` | `python3 <<HEREDOC` | **No** |
| **Inline python3** | `terraform/deploy.sh` | `python3 -c "..."` (datetime) | **No** |
| **Inline python3** | `init_schema_aws.sh` | `python3 "$PARSE_SQL_SCRIPT"` | **No** |
| **Inline python3** | `run-spark-job-aws.sh` | `python3 -c "..."` | **No** |
| **Inline python3** | `setup-and-verify.sh` (delta-lake) | `python3 -c "..."` | **No** |
| **Docker** | `docker-entrypoint.sh` | Container image Python | N/A (image has deps) |

### 1.2 Existing convention

- **Venv path:** `$REPO_ROOT/venv` (used by `setup-python.sh`, `load_data_*.sh`, `check-delta-table-exists.sh`).
- **.gitignore:** Both `venv/` and `.venv` are ignored.
- **Entry points that ensure venv:** `local/run.sh` and `aws/run.sh` call `setup-python.sh` before Python-dependent steps.

### 1.3 Problem

- Many scripts call `python3` directly. That may be system Python, which often does **not** have `requirements.txt` installed.
- Result: teardown, remove-all-aws-resources, find-all-current-aws-resources, etc. can fail with "No module named 'boto3'" unless the user has activated the venv or installed deps globally.
- We want: **one** install (`pip install -r requirements.txt` inside the project venv), and **all** these scripts use that venv automatically.

---

## 2. Design: Single Source of Truth for “Project Python”

### 2.1 Shared helper: `orchestration/shared/load-python-env.sh`

- **Purpose:** Set `PYTHON_CMD` to the project Python (venv if present, else system `python3`).
- **Contract:** Scripts that need Python **source** this after setting (or sourcing) `REPO_ROOT`. Then they use `"$PYTHON_CMD"` instead of `python3`.
- **Logic (pseudo):**
  - If `$REPO_ROOT/venv/bin/python3` exists → `PYTHON_CMD="$REPO_ROOT/venv/bin/python3"`.
  - Else → `PYTHON_CMD="python3"` (fallback).
- **Optional:** Export `PYTHON_CMD` so child processes and inline scripts can use it. Scripts that run `python3 -c "..."` or `python3 <<HEREDOC` can use `"$PYTHON_CMD" -c "..."` etc.

### 2.2 Venv directory

- **Keep:** `$REPO_ROOT/venv` (already used in 3+ scripts and in `setup-python.sh`).
- **One-time setup:** User (or CI) runs once:
  - `run_scripts/main_application_scripts/local/setup-python.sh`
  - or: `python3 -m venv venv && venv/bin/pip install -r requirements.txt`
- After that, any script that uses `load-python-env.sh` and `"$PYTHON_CMD"` will get `requirements.txt` deps without extra installs.

### 2.3 Out of scope

- **Docker:** Containers use their own image and `Dockerfile` deps; no change.
- **System Python version:** Still required 3.10+; `check-and-install.sh` and docs stay as-is.

---

## 3. Refactor Steps (Checklist)

### 3.1 Add shared helper

- [ ] **Create** `orchestration/shared/load-python-env.sh`:
  - Require `REPO_ROOT` (set by caller or by sourcing `load-env.sh` first).
  - Set `VENV_PYTHON="$REPO_ROOT/venv/bin/python3"`.
  - If `[ -f "$VENV_PYTHON" ]` then `export PYTHON_CMD="$VENV_PYTHON"`, else `export PYTHON_CMD="python3"`.
  - Optional: add a one-line comment at top describing usage.

### 3.2 Scripts that run a Python script (use `PYTHON_CMD` instead of `python3`)

- [ ] **teardown-resources-all.sh**  
  - Source `load-python-env.sh` (after `load-env.sh` / once REPO_ROOT is set).  
  - Replace `python3 "$pre_script"` with `"$PYTHON_CMD" "$pre_script"`.  
  - Replace `python3 "$helper"` with `"$PYTHON_CMD" "$helper"`.

- [ ] **remove-all-aws-resources.sh**  
  - Source `load-python-env.sh`.  
  - Replace `python3` with `"$PYTHON_CMD"` for running the .py script.  
  - Remove on-the-fly `pip install boto3` (venv already has it).

- [ ] **ensure-release-address-policy.sh**  
  - Source `load-python-env.sh` (need REPO_ROOT; set or source from parent).  
  - Replace `exec python3` with `exec "$PYTHON_CMD"`.

- [ ] **find-all-current-aws-resources.sh**  
  - Source `load-python-env.sh`.  
  - Set `PYTHON_CMD` to venv if present; use `"$PYTHON_CMD"` in the constructed command instead of `python3`.

- [ ] **init_schema_aws.sh**  
  - Source `load-python-env.sh`.  
  - Replace `python3 "$PARSE_SQL_SCRIPT"` with `"$PYTHON_CMD" "$PARSE_SQL_SCRIPT"`.

### 3.3 Scripts that use inline `python3 -c` or heredoc

Use `"$PYTHON_CMD"` so the same interpreter (and thus venv) is used:

- [ ] **reference_check_frontend_bucket.sh**  
  - Source `load-python-env.sh`.  
  - Replace every `python3 -c` with `"$PYTHON_CMD" -c`.

- [ ] **delete-recreatable-resources.sh** (older)  
  - Source `load-python-env.sh`.  
  - Replace every `python3 -c` with `"$PYTHON_CMD" -c`.

- [ ] **stop-ecs-services.sh**  
  - Source `load-python-env.sh`.  
  - Replace `python3 -c` with `"$PYTHON_CMD" -c`.

- [ ] **kubernetes-manifests.sh**  
  - Source `load-python-env.sh`.  
  - Replace `python3 <<PYTHON_SCRIPT` with `"$PYTHON_CMD" <<PYTHON_SCRIPT`.

- [ ] **terraform/deploy.sh**  
  - Source `load-python-env.sh`.  
  - Replace `python3 -c` with `"$PYTHON_CMD" -c`.

- [ ] **run-spark-job-aws.sh** (delta-lake)  
  - Source `load-python-env.sh`.  
  - Replace `python3 -c` with `"$PYTHON_CMD" -c`.

- [ ] **setup-and-verify.sh** (delta-lake aws)  
  - Source `load-python-env.sh`.  
  - Replace `python3 -c` with `"$PYTHON_CMD" -c`.

### 3.4 Scripts that already use venv

- [ ] **check-delta-table-exists.sh**  
  - Option A: Switch to sourcing `load-python-env.sh` and use `"$PYTHON_CMD"` (same behavior, single pattern).  
  - Option B: Leave as-is (already correct).

- [ ] **load_data_aws.sh** / **load_data_local.sh**  
  - Keep current behavior (source venv activate, then `python`).  
  - Optional: also source `load-python-env.sh` and use `"$PYTHON_CMD"` for the ETL command so all scripts share the same pattern.

### 3.5 Documentation and CI

- [ ] **README or DEV doc**  
  - Add “One-time setup” section: run `./run_scripts/main_application_scripts/local/setup-python.sh` (or equivalent) once; then all Python in scripts uses the project venv and `requirements.txt`.

- [ ] **CI (if any)**  
  - Ensure CI runs `setup-python.sh` (or `venv/bin/pip install -r requirements.txt`) before any step that runs Python scripts.

### 3.6 Optional: Ensure venv before Python-dependent commands

- [ ] **aws/run.sh**  
  - Already calls `setup-python.sh`; no change required unless you want to centralize “ensure venv” in one place.

- [ ] **local/run.sh**  
  - Same as above.

---

## 4. File List Summary

| Action | File |
|--------|------|
| **Create** | `orchestration/shared/load-python-env.sh` |
| **Edit** | `teardown-resources-all.sh` |
| **Edit** | `remove-all-aws-resources.sh` |
| **Edit** | `ensure-release-address-policy.sh` |
| **Edit** | `find-all-current-aws-resources.sh` |
| **Edit** | `init_schema_aws.sh` |
| **Edit** | `reference_check_frontend_bucket.sh` |
| **Edit** | `delete-recreatable-resources.sh` (older) |
| **Edit** | `stop-ecs-services.sh` |
| **Edit** | `kubernetes-manifests.sh` |
| **Edit** | `terraform/deploy.sh` |
| **Edit** | `run-spark-job-aws.sh` |
| **Edit** | `setup-and-verify.sh` (delta-lake aws) |
| **Optional** | `check-delta-table-exists.sh`, `load_data_*.sh` (unify on `PYTHON_CMD`) |
| **Doc** | README / DEV: one-time venv setup |

---

## 5. Result

- **One install:** `pip install -r requirements.txt` once inside `$REPO_ROOT/venv` (via `setup-python.sh` or equivalent).
- **Everywhere Python runs:** Scripts that source `load-python-env.sh` and use `"$PYTHON_CMD"` get that venv’s interpreter and thus all dependencies (boto3, flask, pandas, etc.) without per-script or global installs.
- **Fallback:** If venv is missing, `PYTHON_CMD="python3"` so scripts still run (may fail on missing modules until venv is created).
