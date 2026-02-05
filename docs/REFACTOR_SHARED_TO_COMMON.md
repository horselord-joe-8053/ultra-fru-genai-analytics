# Refactor plan: rename `shared/` → `common/` in subfolders

**Rule:** Any subdir that holds logic shared between local, aws, gcp, etc. is named **`common`**, not **`shared`**.

---

## 1. Directories to rename

| Current path | New path | Purpose |
|--------------|----------|---------|
| `orchestration/prerequisites/shared/` | `orchestration/prerequisites/common/` | Helpers shared by all prerequisite check-and-install scripts (detect-os.sh, prompt-helpers.sh). |
| `module_infra_kubetypes/kube/shared/` | `module_infra_kubetypes/kube/common/` | K8s templates, generated manifests, and ingress values used by both local kube and AWS EKS. |

---

## 2. Steps (per directory)

### 2.1 orchestration/prerequisites/shared → common

1. **Rename directory:** `mv orchestration/prerequisites/shared orchestration/prerequisites/common`
2. **Update sources** (replace `shared/` with `common/` in paths):
   - `orchestration/prerequisites/check-and-install.sh` — `source "$SCRIPT_DIR/shared/..."` → `source "$SCRIPT_DIR/common/..."`
   - `orchestration/prerequisites/aws-cli/check-and-install.sh` — `../shared/` → `../common/`
   - `orchestration/prerequisites/docker/check-and-install.sh` — ditto
   - `orchestration/prerequisites/nodejs/check-and-install.sh` — ditto
   - `orchestration/prerequisites/python/check-and-install.sh` — ditto
   - `orchestration/prerequisites/terraform/check-and-install.sh` — ditto
   - `orchestration/prerequisites/terragrunt/check-and-install.sh` — ditto

### 2.2 module_infra_kubetypes/kube/shared → common

1. **Rename directory:** `mv module_infra_kubetypes/kube/shared module_infra_kubetypes/kube/common`
2. **Update .gitignore:** `module_infra_kubetypes/kube/shared/generated/` → `module_infra_kubetypes/kube/common/generated/`
3. **Update references** (replace `module_infra_kubetypes/kube/shared` with `module_infra_kubetypes/kube/common`):
   - `orchestration/aws/run.sh` — log message / dry-run path
   - `orchestration/local/deploy-app.sh` — `generate_kubernetes_manifests` arg and all `kubectl apply -f` paths
   - `orchestration/local/kube/install-ingress.sh` — `VALUES_FILE=`
   - `module_infra_kubetypes/kube/aws/helpers/kubernetes-manifests.sh` — output/generated path
   - `module_infra_kubetypes/kube/aws/deploy.sh` — log messages
   - `module_infra_kubetypes/kube/local/install-ingress.sh` — `VALUES_FILE=`

---

## 3. One-off fix (unrelated to shared vs common)

- **orchestration/common/deploy/save-deployment-state.sh** — Historically this sourced `../../../../shared/logger.sh` (stale path) and then `orchestration/common/logger.sh`. We now use the unified project-wide logger at `lib/logger.sh` instead. The code has been updated to:
  - Resolve `REPO_ROOT_SAVE` from the script location, and
  - `source "$REPO_ROOT_SAVE/lib/logger.sh"` when available, falling back to basic echo-based logging otherwise.

---

## 4. Optional: docs

- In **REFACTOR_PLAN_FINAL.md**, **docs/RUN_SCRIPTS_MIGRATION_ANALYSIS.md**, and similar, any mention of `module_infra_kubetypes/kube/shared/` or `orchestration/prerequisites/shared/` can be updated to `common/` for consistency. Not required for behavior.

---

## 5. Verification

After the renames and path updates:

```bash
./orchestration/run.sh help
./orchestration/teardown.sh help
./orchestration/run.sh local nonkube
```

If prerequisites or kube paths are used, run a quick local kube or AWS dry-run to confirm no broken paths.
