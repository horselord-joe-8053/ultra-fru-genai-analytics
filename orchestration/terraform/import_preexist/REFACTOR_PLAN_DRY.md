# DRY Refactor Plan: orchestration/terraform/import_preexist/

**Status: Implemented (Option A).** Shared library: `common/lib_import_common.sh`. All six scripts migrated.

## 1. Current state

- **6 scripts:** `import-existing-{eks,ecs,infrastructure,longterm,frontend-eks,frontend-ecs}.sh`
- **Callers:** `deploy.sh` and `teardown-resources-all.sh` invoke them as `"$SCRIPT" "$ENVIRONMENT" "$PROJECT_NAME"` (e.g. `dev`, `fru`). Interface must stay the same.
- **Duplication:** Bootstrap, import logic (success/skip/fail/state-lock), lock-ID parsing, and (for frontend-*) OAC/S3/CF flow are repeated.

---

## 2. Duplicated logic (what to centralize)

| Area | Where it’s duplicated | Proposed shared piece |
|------|------------------------|------------------------|
| **Bootstrap** | All 6 | `SCRIPT_DIR`/`REPO_ROOT`, source logger + load-env, `ENVIRONMENT`/`PROJECT_NAME` from args, validate `dev|staging|prod`, default `AWS_PROFILE`/`AWS_REGION`. |
| **Dir validation** | All 6 | Check layer dir exists, `cd` to it, optional `terragrunt init` (strict vs `|| true`). |
| **Single import** | EKS, ECS, frontend-eks, frontend-ecs, infra, longterm | One function: run `terragrunt import addr id`, capture output; classify as success / already-in-state / skip (resource not exist) / state-lock / failure; on state-lock parse lock ID, `force-unlock`, retry once; log and return success/fail. |
| **Lock ID parsing** | frontend-eks, infrastructure (and teardown.sh) | Strip ANSI from file, grep for `ID: <uuid>`, extract UUID (same regex everywhere). |
| **Skip patterns** | EKS/ECS (extended) vs infra/longterm (minimal) | Single list of “resource does not exist” patterns (extended set everywhere for consistency). |
| **List-based loop** | infrastructure, longterm | Loop over `resource:id` list, call shared import function, count failures, final “Some imports failed” / “Import phase completed.” |
| **Frontend OAC/S3/CF** | frontend-eks, frontend-ecs | Shared helper: OAC lookup by name → import or skip; S3 bucket name + head-bucket → import or skip; CF by comment → import or skip; optional OAC state verification. Parameterized by layer (frontend-eks vs frontend-ecs) for names/comment. |

---

## 3. Option A: Shared shell library (recommended)

**Idea:** One shell library under `import_preexist/` that all existing scripts source. Scripts stay as the entry points (no change to callers). Shared code lives in one place.

### 3.1 New file

- **`lib_import_common.sh`** (in `orchestration/terraform/import_preexist/`)

  - **Bootstrap (optional use):**  
    - `import_parse_args` – set `ENVIRONMENT`, `PROJECT_NAME` from `$1`/`$2`, default `dev`/`fru`.  
    - `import_validate_env` – exit if `ENVIRONMENT` not in `dev|staging|prod`.  
    - `import_ensure_repo_env` – set `REPO_ROOT` if unset, source `logger.sh` and `load-env.sh`, `load_env_file || true`.  
  - **Dir:**  
    - `import_ensure_dir_and_cd "$layer_dir" "$layer_name"` – check dir exists, log error and exit if not, `cd` to dir.  
  - **Terragrunt init:**  
    - `import_init_strict` – `terragrunt init -input=false`; exit 1 on failure.  
    - `import_init_soft` – same, but `|| true`.  
  - **Lock ID:**  
    - `import_parse_lock_id_from_file "$tmp_log"` – strip ANSI, grep `ID:` line, extract UUID; output lock ID or empty.  
  - **Single import (core):**  
    - `import_one_resource "$addr" "$id"` – run `terragrunt import "$addr" "$id"` capturing output to temp file; detect already-in-state, skip (resource not exist), state-lock; on state-lock call `import_parse_lock_id_from_file`, `terragrunt force-unlock -force "$lock_id"`, retry import once; log success/skip/failure and optional tail of output; return 0 on success/skip, 1 on failure. Uses shared “skip” patterns (extended set).  
  - **Batch loop:**  
    - `import_batch "resource1:id1" "resource2:id2" ...` – for each, log “Importing …”, call `import_one_resource`, increment failure count on non-zero return; at end log “Some imports failed (N)” or “Import phase completed.” Return 0 if no failures, 1 otherwise.

  Scripts that currently use a list (infrastructure, longterm) call `import_batch`. Others keep their current structure but replace inline `run_import` / ad‑hoc logic with `import_one_resource`.

### 3.2 Script changes (no CLI change)

- **import-existing-eks.sh** – Source lib; use `import_parse_args`, `import_validate_env`, `import_ensure_repo_env`, `import_ensure_dir_and_cd "$EKS_DIR" "EKS"`, `import_init_soft`; replace local `run_import` with `import_one_resource` for each resource; keep EKS-specific IAM/KMS/CloudWatch names and order.
- **import-existing-ecs.sh** – Same pattern; use `import_one_resource`; keep ECS-specific CloudWatch/ALB/target group logic.
- **import-existing-infrastructure.sh** – Source lib; bootstrap + `import_ensure_dir_and_cd`, `import_init_strict`; replace loop with `import_batch "module.aurora...." "module.iam...." ...` (list built from `PROJECT_NAME`/`ENVIRONMENT`).
- **import-existing-longterm.sh** – Same as infrastructure but with longterm resource list; optionally add state-lock handling in lib and use it here (longterm currently has no lock handling).
- **import-existing-frontend-eks.sh** – Source lib; use shared bootstrap and dir/init; replace local `run_import` with `import_one_resource`; optionally extract OAC/S3/CF + OAC verification into a shared function `import_frontend_layer "$layer" "$ENVIRONMENT" "$PROJECT_NAME"` (layer = frontend-eks | frontend-ecs) that uses `import_one_resource` and layer-specific names. If not extracted, at least use `import_one_resource` and `import_parse_lock_id_from_file` so frontend-eks shares the same lock handling as the lib.
- **import-existing-frontend-ecs.sh** – Same as frontend-eks; either call shared `import_frontend_layer frontend-ecs ...` or use `import_one_resource` and keep minimal layer-specific logic.

### 3.3 Pros/cons

- **Pros:** No new runtime; callers unchanged; same CLI; DRY in one place; easy to add state-lock + extended skip patterns to longterm; lock parsing and retry logic match teardown behavior.  
- **Cons:** Shell is less pleasant for complex branching; shared lib must be sourced and used consistently.

---

## 4. Option B: Python driver + layer config

**Idea:** One Python script and one config (YAML or Python) that describe per-layer resources. Callers invoke Python instead of shell scripts.

### 4.1 New files

- **`import_layer.py`** – Entry point: `python import_layer.py --layer eks --env dev --project fru` (or positional args). Reads layer config, runs `terragrunt import` via subprocess, parses stdout/stderr, applies skip patterns and state-lock handling (parse lock ID, force-unlock, retry). Logging: print to stdout in a format similar to current scripts (or call back into logger.sh via a small wrapper).
- **`layer_config.yaml`** (or `layer_config.py`):  
  - For each layer (eks, ecs, infrastructure, longterm, frontend-eks, frontend-ecs): `terragrunt_dir`, list of imports. Each import: `address` + `id` (string or “lookup”: `aws kms ...` / `aws cloudfront ...` etc.). Frontend layers: optional OAC verification step.

### 4.2 Caller changes

- **deploy.sh / teardown-resources-all.sh** – Replace:
  - `"$REPO_ROOT/.../import-existing-eks.sh" "$ENVIRONMENT" "$PROJECT_NAME"`
  with:
  - `python "$REPO_ROOT/.../import_layer.py" --layer eks --env "$ENVIRONMENT" --project "$PROJECT_NAME"`  
  (and similarly for ecs, infrastructure, longterm, frontend-eks, frontend-ecs). Ensure `python3` is available (or use `python` and document requirement).

### 4.3 Pros/cons

- **Pros:** Single place for all import logic; easier to add patterns, retries, and structured output; config-driven resource list; no duplicated lock parsing.  
- **Cons:** New dependency (Python); all callers must change; need to keep Python output compatible with current “human + log” expectations; frontend OAC/S3/CF lookups (AWS CLI) and optional verification are more natural in shell unless we reimplement in Python (or shell out from Python).

---

## 5. Recommendation

- **Prefer Option A (shared shell library)** so that:
  - No callers change.
  - No new runtime.
  - We still get one implementation for: bootstrap, dir/init, lock parsing, state-lock retry, skip patterns, and `import_one_resource` / `import_batch`.
- **Consider Option B** only if you want a single Python entry point and are willing to:
  - Change every `deploy.sh` / `teardown-resources-all.sh` reference, and
  - Rely on Python for all import and (optionally) AWS lookups.

---

## 6. Implementation order (Option A)

1. **Add `lib_import_common.sh`**  
   - Implement: `import_parse_args`, `import_validate_env`, `import_ensure_repo_env`, `import_ensure_dir_and_cd`, `import_init_strict`, `import_init_soft`, `import_parse_lock_id_from_file`, `import_one_resource` (with state-lock + extended skip patterns), `import_batch`.
2. **Migrate infrastructure and longterm**  
   - Use lib for bootstrap, dir, init, and `import_batch` with current resource lists. Ensures batch path and failure counting work.
3. **Migrate EKS and ECS**  
   - Use lib for bootstrap, dir, init; replace local `run_import` with `import_one_resource`; keep layer-specific resource names and ordering.
4. **Migrate frontend-eks and frontend-ecs**  
   - Use lib and `import_one_resource`; add optional `import_frontend_oac_s3_cf` (or keep inline but call `import_one_resource`) and OAC verification.
5. **Optional:** Add a small “import_usage” helper and document in README that scripts rely on `lib_import_common.sh`.
6. **Leave `TERRA_LEARN_IMPORT_PREEXIST.md` and quick reference as-is** (script names and CLI unchanged).

---

## 7. Summary

| Approach | New files | Caller changes | DRY scope |
|----------|-----------|----------------|-----------|
| **A. Shell lib** | `lib_import_common.sh` | None | Bootstrap, dir/init, lock parse, one-import + batch, skip patterns; optional frontend helper. |
| **B. Python** | `import_layer.py`, `layer_config.yaml` (or .py) | deploy.sh, teardown-resources-all.sh | Full; single entry point and config. |

Recommendation: **Option A**. If you confirm, the next step is to implement `lib_import_common.sh` and migrate the six scripts in the order above.
