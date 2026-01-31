# Files/dirs not gitignored that can be removed after refactor

## Safe to remove now (no live references)

| Path | Reason |
|------|--------|
| **env.example.show** | One-off backup of .env.example; not in .gitignore — **removed** |
| **module_app_core/backend/agents/prompts.py.bak1** | Backup file; not in .gitignore — **removed** |

## Done

| Path | Action |
|------|--------|
| **misc_scripts/** | Moved `misc_scripts/refresh-env-example.sh` → `util_sh/refresh-env-example.sh`, removed `misc_scripts/`. |

## Removed

| Path | Action |
|------|--------|
| **infra/** | All references updated to module_* paths; directory removed. Docker → `module_infra_kubetypes/nonkube/local`, Terraform/k8s → `module_infra_basic`, `module_infra_kubetypes/kube`, `module_infra_kubetypes/nonkube`. |

## Removed (test/)

| Path | Action |
|------|--------|
| **test/** | All callers use `module_test_verification/`. Guides and `module_test_verification/common_sh/test_results.sh` updated; directory removed. |

## Do not remove yet (still referenced)

- **run_scripts/spark_delta-lake_scripts/** – Old scripts inside it still reference it; callers use `module_infra_spark` but the tree is still used if old paths are invoked.
- **run_scripts/main_application_scripts/aws/eks/** – aws/run.sh now calls `module_infra_kubetypes/kube/aws/deploy.sh`, but `run_scripts/.../aws/verification/*.sh` still source `run_scripts/.../aws/eks/verification/*.sh`. Update those to `module_infra_kubetypes/kube/aws/verification/` before removing.

## Why we cannot remove run_scripts/ (entire directory)

**run_scripts/** is the **active entry point** for all automation; it was not “moved” into a module like test/ or infra/.

- **Root `./run.sh`** → `orchestration/run.sh` → **exec’s** `run_scripts/main_application_scripts/local/run.sh` or `run_scripts/main_application_scripts/aws/run.sh`. Those scripts contain the flow (local vs AWS, kube vs nonkube, terraform, start-services, etc.) and **call into** module_* (e.g. `module_infra_kubetypes/kube/aws/deploy.sh`, `module_infra_db/...`, `module_infra_kubetypes/nonkube/local/...`). The module_* dirs are **invoked by** run_scripts; they do not replace them.
- **Root `./teardown.sh`** → `orchestration/teardown.sh` → **exec’s** `run_scripts/main_application_scripts/local/shared/resources_cleanup/teardown-resources-all.sh` or `run_scripts/main_application_scripts/aws/shared/resources_cleanup/teardown-resources-all.sh`.
- Removing **run_scripts/** would break `./run.sh` and `./teardown.sh` and every flow that depends on them. Only **sub-trees** of run_scripts (e.g. spark_delta-lake_scripts, aws/eks) can be removed after callers are updated to use module_*.

---

## Optional: remove old database script copies

**run_scripts/main_application_scripts/aws/database/** and **run_scripts/main_application_scripts/common/database/** – All active callers use `module_infra_db`. These dirs only reference each other. You can remove both if you no longer need the old script copies; nothing in the current flow (orchestration → container-deploy-common → module_infra_db) uses them.
