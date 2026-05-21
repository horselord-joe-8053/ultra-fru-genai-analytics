# Orchestration folder: DRY, layout, and test plan

## 1. DRY within orchestration/ and vs module_*

### 1.1 DRY within orchestration/
- **shared/ vs common/** – Both held “shared” utilities; naming was redundant. **Resolution:** Merge into a single **orchestration/common/** with clear subdirs (see §2).
- **Single source for logging, env, image IDs** – `logger.sh`, `load-env.sh`, `load-image-identifiers.sh` live once in orchestration; all scripts `source` them. No duplication.
- **container-deploy-common.sh** – Phase logic is centralized; `orchestration/aws/run.sh` sources it once. No duplicate phase logic.
- **run-with-heartbeat.sh** – Single file; teardown and long steps source it. DRY.

### 1.2 orchestration/ vs module_*
- **module_*** do **not** duplicate orchestration utilities. They **source** orchestration for:
  - **logger, load-env:** `module_infra_basic/aws/build-push-ecr.sh`, `deploy-frontend.sh`; `module_infra_kubetypes/kube/aws/deploy.sh`, teardown Python scripts; `module_infra_kubetypes/nonkube/aws/deploy.sh`, teardown; `module_infra_db/*`, `module_infra_spark/*`, `module_test_verification/*`.
- **Separation of roles:** orchestration = flow + shared helpers; module_* = infra/app logic that **uses** those helpers. No overlap; DRY is respected.

### 1.3 orchestration/terraform and orchestration/common
- **terraform/** – Scripts for Terragrunt (deploy, teardown, setup-s3-bucket, migrate-eks-state, etc.). They only source orchestration logger/load-env; no duplicate Terraform logic.
- **common/** (before merge) – Had `check-dependencies.sh`, `docker_run.sh`, `verify-endpoints.sh`, `wait-for-service.sh`. After merge, **shared/** contents live under **common/** with subdirs; no duplication.

---

## 2. Layout after merge: shared → common, with subdirs

**Goal:** One place for shared orchestration utilities: **orchestration/common/**.

**2.1** Everything under **orchestration/shared/** is moved into **orchestration/common/**.

**2.2** **orchestration/common/** is organized into a few subdirs (no over-complication):

| Subdir / file       | Contents |
|---------------------|----------|
| **common/env/**     | `load-env.sh`, `load-image-identifiers.sh`, `load-python-env.sh` |
| **common/deploy/**  | `container-deploy-common.sh`, `prepare-frontend.sh`, `save-deployment-state.sh`, `cleanup-local-docker-images.sh` |
| **common/feedback/**| `run-with-heartbeat.sh`, `long_running_feedback.py`, `progress-indicator.sh`, `performance-tracker.sh` |
| **common/** (root)  | `logger.sh`, `git_helpers.sh`, `check-dependencies.sh`, `docker_run.sh`, `verify-endpoints.sh`, `wait-for-service.sh` |

- **Path updates:** All `orchestration/shared/...` references become `orchestration/common/...` or `orchestration/common/env/...`, `orchestration/common/deploy/...`, `orchestration/common/feedback/...` as appropriate.
- **Scripts that compute REPO_ROOT from their own path** (e.g. `load-env.sh`, `container-deploy-common.sh`, `progress-indicator.sh`) are adjusted for the new depth (e.g. one extra `..` where needed).

---

## 3. Simple concise test plan

Run from **repo root**. Assumes `.env` exists (e.g. `cp .env.example .env` and fill if needed).

### 3.1 Entrypoints and help
```bash
./orchestration/run.sh help
./orchestration/teardown.sh help
```

### 3.2 Local path (no AWS, quick check)
```bash
./orchestration/run.sh local nonkube
```
(Optional: run with `--skip-frontend`, `--skip-data-load`, etc. Run `./orchestration/run.sh help` for top-level usage. For setup steps, invoke scripts under `orchestration/local/` as needed, e.g. `./orchestration/local/setup-env.sh`.)

### 3.3 AWS path (dry-run only; no real changes)
```bash
./orchestration/run.sh aws eks dev --dry-run
./orchestration/run.sh aws ecs dev --dry-run
./orchestration/aws/teardown-resources-all.sh dev --container-type all --dry-run
```

### 3.4 Common helpers (sourced by scripts above)
- No direct tests required if 3.1–3.3 pass: logger, load-env, deploy phases, heartbeat, and common deps are all used along those flows.
- Optional: run a script that only sources the shared logger and env loader (e.g. `source lib/logger.sh` and `source orchestration/common/env/load-env.sh`, then call `log_info "ok"`) to confirm path resolution.

### 3.5 One-liner smoke
```bash
./orchestration/run.sh help && ./orchestration/teardown.sh help
```

Pass = entrypoints work and common helpers (logger, load-env) load without path/source errors.
