# Final Refactor Plan: Sub-Projects + Cleanup

Single source of truth for the major refactor. Execute phases in order. Each phase ends with a smoke check before moving on.

---

## Decisions (locked)

- **Entrypoint:** Root `run.sh` and `teardown.sh` delegate to `orchestration/run.sh` and `orchestration/teardown.sh`.
- **Sub-projects:** `orchestration/`, `module_app_core/`, `module_infra_basic/`, `module_infra_db/`, `module_infra_spark/`, `module_infra_kube/`, `module_infra_nonkube/`, `module_test_verification/`.
- **docs/:** Top-level `docs/`; move all top-level `.md` there **except** `README.md` and `README_WAR_STORIES.md`. Update docs when touching related code.
- **Uncertain items:** Put in an appropriately named subdir of `orchestration/`.
- **Env:** Single `.env` at repo root; no `env/` or `env-examples/`. `.env.example` has sections: COMMON, AWS, GCP, ORACLE, AZURE. Workflow: update `.env` first, then run `scripts/refresh-env-example.sh` to redact → `.env.example`.
- **Local:** Docker Postgres; use current working flows; prefer Docker where no flow exists yet.

---

## Phase 0: Prep (no moves)

1. **Contract:** Document `REPO_ROOT` (parent of `orchestration/`, `module_*`), env vars, and script sourcing order.
2. **Smoke:** Run `./run_scripts/main_application_scripts/local/run.sh --help` and AWS teardown `--dry-run`; record success.
3. **Backup/tag:** Create a refactor branch or tag so you can revert.

---

## Phase 1: docs/ and scripts/

1. **Create `docs/`** at repo root.
2. **Move** into `docs/` (from repo root):
   - `README_ALL_TEARDOWN.md`
   - `README_INFRA.md`
   - `README_MULTI_CLOUD.md`
   - `README_RUN.md`
   - `README_TERRA_SH_RESPONSIBILITIES.md`
   - `README_WORKFLOW_EKS_NOTES.md`
   - `REFACTOR_PLAN_VENV_SINGLE_SOURCE.md`
   - `ENVIRONMENT_MANAGEMENT_BEST_PRACTICES.md`
3. **Leave at root:** `README.md`, `README_WAR_STORIES.md`.
4. **Update `README.md`:** Fix links to moved docs (e.g. `README_RUN.md` → `docs/README_RUN.md`). Do minimal path fixes only; full doc edits when touching that area.
5. **Ensure `scripts/` exists** with `scripts/refresh-env-example.sh` (already added). `.env.example` header points to it.
6. **Smoke:** Grep for `README_RUN.md` etc.; update any in-repo references to `docs/...`.

---

## Phase 2: Create module dirs + orchestration shell

1. **Create directories** (empty or with README only):
   - `orchestration/`
   - `module_app_core/`
   - `module_infra_basic/`
   - `module_infra_db/`
   - `module_infra_spark/`
   - `module_infra_kube/`
   - `module_infra_nonkube/`
   - `module_test_verification/`
2. **Orchestration:**
   - Add `orchestration/shared/` and **move** from `run_scripts/shared/`: `logger.sh`, `load-env.sh`, `load-image-identifiers.sh`, `load-python-env.sh`, `performance-tracker.sh`, `progress-indicator.sh`, `git_helpers.sh`.
   - Update every `source "$REPO_ROOT/run_scripts/shared/...` to `source "$REPO_ROOT/orchestration/shared/...` (or set `REPO_ROOT` in root scripts and use `$REPO_ROOT/orchestration/shared/...`). **Important:** After move, `load-env.sh` lives under `orchestration/`; REPO_ROOT detection in load-env.sh must be updated (e.g. `DETECTED_REPO_ROOT="$(cd "$ENV_SCRIPT_DIR/../.." && pwd)"` → one more `..` if orchestration is at root). So: if `orchestration/shared/load-env.sh`, then repo root = `$(cd "$ENV_SCRIPT_DIR/../.." && pwd)` (orchestration = parent of shared, repo = parent of orchestration). Verify and fix.
   - Add `orchestration/run.sh`: usage `run.sh <local|aws> <kube|nonkube> [env] [options]`. It sources `orchestration/shared/`, then dispatches to the correct script (see Phase 6–7 for targets). For now, dispatch to existing paths: `run_scripts/main_application_scripts/local/run.sh` or `run_scripts/main_application_scripts/aws/run.sh` with the right args.
   - Add `orchestration/teardown.sh`: usage `teardown.sh <local|aws> <kube|nonkube|all> [env] [options]`. Dispatch to existing teardown scripts.
   - Add **root** `run.sh` and `teardown.sh` that call `orchestration/run.sh` and `orchestration/teardown.sh` with "$@".
3. **Prerequisites:** Move `run_scripts/main_application_scripts/common/prerequisites/` → `orchestration/prerequisites/` (or keep in place and have orchestration call it; either way, orchestration/run.sh invokes check-and-install for the chosen provider).
4. **Smoke:** From repo root, `./run.sh --help` (or equivalent) and `./teardown.sh --help`; ensure they delegate and existing local/aws run still works when called via old path.

---

## Phase 3: Move app core (module_app_core)

1. **Move** into `module_app_core/`:
   - `frontend/`
   - `backend/`
   - `data/`
   - `sql/`
   - `spark_jobs/`
2. **Path updates:** Replace all references to `$REPO_ROOT/frontend`, `$REPO_ROOT/backend`, `$REPO_ROOT/data`, `$REPO_ROOT/sql`, `$REPO_ROOT/spark_jobs` with `$REPO_ROOT/module_app_core/frontend`, etc. (or define `APP_ROOT="$REPO_ROOT/module_app_core"` and use `$APP_ROOT/...`).
3. **requirements.txt:** Move to `module_app_core/` or keep at root and point install at `module_app_core/`; update any script that runs `pip install -r requirements.txt`.
4. **Smoke:** Local run (nonkube) and AWS deploy (ecs or eks); fix broken paths.

---

## Phase 4: Move basic infra (module_infra_basic)

1. **Move** Terraform “infrastructure” (shared only: VPC, IAM, Secrets, S3 state) into `module_infra_basic/aws/`:
   - From `infra/terraform/providers/aws/`: take `environments/dev/infrastructure/`, `environments/prod/infrastructure/`, `environments/_component/infrastructure-base.hcl`, and modules used only by infrastructure: `vpc/`, `iam/`, `secrets-manager/`, `infrastructure/` (wrapper). Do **not** move Aurora, ECS, EKS, ALB, frontend modules yet.
2. **Terragrunt:** Update `config_path` and `include` paths in terragrunt.hcl so they point to `module_infra_basic/aws/...`. Update any script that runs terragrunt to use `module_infra_basic/aws/` as the infra layer.
3. **Smoke:** AWS “infrastructure only” deploy; fix Terragrunt paths.

---

## Phase 5: Move database infra (module_infra_db)

1. **Move** Aurora Terraform + DB bootstrap into `module_infra_db/aws/`:
   - Aurora module and Terragrunt configs (environments/dev, prod that reference Aurora) from current infra.
   - Schema/pgvector scripts: move `run_scripts/main_application_scripts/common/database/` into `module_infra_db/common/` and `module_infra_db/aws/` as appropriate; or keep under a single `module_infra_db/` and have orchestration call them. DB init scripts reference `module_app_core/sql/` for schema SQL.
2. **Local:** Document that local DB = Docker Postgres (Compose in module_infra_nonkube). No separate “install PostgreSQL” for local.
3. **Smoke:** Full AWS deploy including DB; local run with DB.

---

## Phase 6: Move Spark/Delta infra (module_infra_spark)

1. **Move** `run_scripts/spark_delta-lake_scripts/` into `module_infra_spark/` (e.g. `module_infra_spark/common/`, `module_infra_spark/local/`, `module_infra_spark/aws/`).
2. **Path updates:** Scripts that reference `REPO_ROOT/run_scripts/spark_delta-lake_scripts` or `REPO_ROOT/spark_jobs` → `module_infra_spark/` and `module_app_core/spark_jobs`.
3. **Smoke:** Run with ENABLE_ANALYTICS_SCHEDULER=true locally and on AWS.

---

## Phase 7: Move Kubernetes route (module_infra_kube)

1. **Move** into `module_infra_kube/`:
   - **AWS:** From `infra/terraform/providers/aws/`: EKS Terragrunt + EKS module → `module_infra_kube/aws/`. `infra/k8s/` (manifests) → `module_infra_kube/shared/manifests/` or `module_infra_kube/aws/manifests/`.
   - **Local:** `run_scripts/main_application_scripts/local/kube/` → `module_infra_kube/local/`.
   - **Scripts:** `run_scripts/main_application_scripts/aws/eks/` → `module_infra_kube/aws/` (deploy, helpers, verification).
2. **Path updates:** All references to old eks/ and k8s paths point to `module_infra_kube/`.
3. **Orchestration:** `orchestration/run.sh` and `teardown.sh` dispatch aws+kube to `module_infra_kube/aws/` and local+kube to `module_infra_kube/local/`.
4. **Smoke:** Local kube and AWS EKS full run and teardown.

---

## Phase 8: Move non-Kubernetes route (module_infra_nonkube)

1. **Move** into `module_infra_nonkube/`:
   - **AWS:** From `infra/terraform/providers/aws/`: ECS Terragrunt + ECS, ALB, frontend modules → `module_infra_nonkube/aws/`. `run_scripts/main_application_scripts/aws/ecs/` and shared build/deploy (build-push-ecr, deploy-frontend, container-deploy-common) → `module_infra_nonkube/aws/` (or keep shared bits in orchestration).
   - **Local:** `infra/docker/` (docker-compose.yml, Dockerfile.api, docker-entrypoint.sh) → `module_infra_nonkube/local/`. `run_scripts/main_application_scripts/local/` (start-services, stop-services, deploy-app, etc.) → `module_infra_nonkube/local/`.
2. **Path updates:** All references to old ecs/ and docker paths point to `module_infra_nonkube/`.
3. **Orchestration:** Dispatch local+nonkube and aws+nonkube to `module_infra_nonkube/local/` and `module_infra_nonkube/aws/`.
4. **Smoke:** Local Compose and AWS ECS full run and teardown.

---

## Phase 9: Move tests and verification (module_test_verification)

1. **Move** into `module_test_verification/`:
   - `test/` (python/, common_sh/, test_query_*.sh) → `module_test_verification/` (same structure).
   - Verification scripts from `run_scripts/.../verification/` and `run_scripts/.../aws/verification/` → `module_test_verification/verification/` (and provider-specific subdirs if needed).
2. **Path updates:** Tests and verification reference `REPO_ROOT/module_app_core`, etc.
3. **Smoke:** Run test suite and verification after a deploy.

---

## Phase 10: Remove obsolete files and dirs

Remove or archive paths that are now empty or fully replaced by the new layout. **Only delete after Phases 1–9 are verified.**

1. **Remove empty or fully moved dirs:**
   - `run_scripts/main_application_scripts/` (contents moved to orchestration/, module_infra_*, module_test_verification). Remove entire `run_scripts/main_application_scripts/` if every script has been moved or delegated.
   - `run_scripts/spark_delta-lake_scripts/` (moved to module_infra_spark).
   - `run_scripts/shared/` (moved to orchestration/shared/).
   - `infra/terraform/` (contents moved to module_infra_basic, module_infra_db, module_infra_kube, module_infra_nonkube).
   - `infra/docker/` (moved to module_infra_nonkube/local).
   - `infra/k8s/` (moved to module_infra_kube).
   - `frontend/`, `backend/`, `data/`, `sql/`, `spark_jobs/`, `test/` at repo root (moved to module_app_core and module_test_verification).
2. **Remove obsolete files:**
   - Any top-level `.md` that was moved to `docs/` (already moved in Phase 1; no duplicate left at root).
   - `env.example.show`, `env.example.bk1`-style backups if present and no longer needed.
   - `backend/agents/prompts.py.bak1` if no longer needed.
3. **Keep:**
   - `run_scripts/` only if it still contains something (e.g. a single redirect script). Otherwise remove the entire `run_scripts/` tree if everything is under orchestration/ and module_*.
   - `infra/` only if something remains (e.g. a README pointing to module_*). Otherwise remove `infra/`.
4. **.gitignore:** Remove entries that no longer apply (e.g. paths under old run_scripts). Add `module_*/` or specific ignores if needed.
5. **Final smoke:** Full matrix: `./run.sh local nonkube`, `./run.sh local kube`, `./run.sh aws nonkube <env>`, `./run.sh aws kube <env>`, and teardown for each. Fix any remaining references to old paths.

---

## Phase 11: Docs and README

1. **README.md:** One-command run/teardown examples; list sub-projects (orchestration, module_app_core, module_infra_basic, module_infra_db, module_infra_spark, module_infra_kube, module_infra_nonkube, module_test_verification); link to `docs/README_RUN.md`, `docs/README_INFRA.md`, etc.
2. **docs/:** Update moved docs when you touch that area (e.g. when run scripts change, update docs/README_RUN.md). No need to do all at once; do it as you change each area.
3. **Sub-project READMEs:** Each `module_*/` and `orchestration/` can have a short README describing its role and how it’s invoked.

---

## Summary: What gets removed after refactor

| Removed / replaced by |
|------------------------|
| `run_scripts/main_application_scripts/` (local, aws, common) → orchestration + module_* |
| `run_scripts/shared/` → `orchestration/shared/` |
| `run_scripts/spark_delta-lake_scripts/` → `module_infra_spark/` |
| `infra/terraform/providers/aws/` (infra, ecs, eks, modules) → module_infra_basic, module_infra_db, module_infra_kube, module_infra_nonkube |
| `infra/docker/` → `module_infra_nonkube/local/` |
| `infra/k8s/` → `module_infra_kube/` |
| Root `frontend/`, `backend/`, `data/`, `sql/`, `spark_jobs/` → `module_app_core/` |
| Root `test/` → `module_test_verification/` |
| Top-level README_*.md (except README.md, README_WAR_STORIES.md) → `docs/` (already moved in Phase 1) |

---

## Env workflow reminder

1. Update **.env** first (same section structure as `.env.example`: COMMON, AWS, GCP, ORACLE, AZURE).
2. Run **`./scripts/refresh-env-example.sh`** to copy `.env` → `.env.example` with sensitive values redacted.
3. Commit `.env.example` only; never commit `.env`.

---

**You’re ready for the major refactor.** Execute phases 0–11 in order; run smoke checks between phases; do Phase 10 (removal) only after 1–9 are stable.
