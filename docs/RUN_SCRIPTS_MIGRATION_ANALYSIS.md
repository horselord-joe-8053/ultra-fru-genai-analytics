# Migration analysis: Eliminating run_scripts/ by moving code into module_* and orchestration/

**Goal:** Divide all code under `run_scripts/` into parts that can live in the existing sub-dirs (`module_*`, `orchestration/`), using Python where it simplifies things, so the entire `run_scripts/` tree can be removed.

**Scope:** No code changes in this doc—analysis and plan only.

**Principles:**
- **module_infra_basic/** = Work that is **not specific to kube or nonkube**, but **shared by both** or **prerequisite for both** (e.g. ECR, Terraform state bucket, shared frontend deploy, project-level AWS resource CLI).
- **orchestration/shared/** = **Orchestration-level** shared utilities: flow control, phase helpers that call modules, logging, progress/heartbeat, env loading, and generic helpers used by both local and AWS flows.
- **Breaking up code** is encouraged: split large scripts into multiple files under the appropriate `module_*` or `orchestration/` folders (e.g. one phase per file, or shared helpers in a dedicated file).

---

## 1. Current layout and who calls what

### 1.1 Entry points (today)

| Entry point | What it exec’s |
|-------------|----------------|
| Root `./run.sh` | `orchestration/run.sh` |
| Root `./teardown.sh` | `orchestration/teardown.sh` |
| `orchestration/run.sh` | `run_scripts/main_application_scripts/local/run.sh` or `aws/run.sh` |
| `orchestration/teardown.sh` | `run_scripts/.../local/.../teardown-resources-all.sh` or `aws/.../teardown-resources-all.sh` |

So **orchestration/** is already the top-level dispatcher; it only needs to call into new locations once run_scripts content is moved.

### 1.2 What run_scripts/ contains (high level)

- **run_scripts/spark_delta-lake_scripts/**  
  Duplicate of **module_infra_spark/**; callers already use module_infra_spark. Safe to remove after any stray references are updated.

- **run_scripts/main_application_scripts/common/**  
  Prerequisites (check-and-install: aws-cli, docker, node, python, terraform, terragrunt), database scripts (init_schema*, load_data*), check-dependencies, docker_run, wait-for-service, verify-endpoints. Used by both local and AWS flows.

- **run_scripts/main_application_scripts/local/**  
  Local orchestrator (run.sh), start/stop services, deploy, setup-*, kube/setup and install-ingress, verification, teardown-resources-all. Already calls module_infra_kubetypes/kube, module_infra_db, module_infra_kubetypes/nonkube, module_infra_spark.

- **run_scripts/main_application_scripts/aws/**  
  AWS orchestrator (run.sh), terraform (deploy, teardown, setup-s3-bucket, terra_validation, etc.), shared (build-push-ecr, container-deploy-common, deploy-frontend, resources_cleanup, cli, helpers), verification, bedrock, check-aws-credentials, setup-aws-profiles, database/, eks/, ecs/.

### 1.3 What’s already in module_* (canonical)

| Module | Contents | run_scripts duplicate |
|--------|----------|------------------------|
| **module_infra_basic** | Terraform only (VPC, Aurora, IAM, etc.) | — |
| **module_infra_kubetypes/kube** | EKS Terraform + deploy.sh + helpers + verification | run_scripts/aws/eks/* (aws/run.sh already calls module_infra_kubetypes/kube/aws/deploy.sh) |
| **module_infra_kubetypes/nonkube** | ECS Terraform + deploy.sh + helpers + verification + local Docker | run_scripts/aws/ecs/* + local Docker |
| **module_infra_db** | init_schema, load_data, etc. | run_scripts/.../common/database/, aws/database/ |
| **module_infra_spark** | Delta Lake scripts | run_scripts/spark_delta-lake_scripts/ |
| **module_test_verification** | Tests, test_cache | — |

So: **run_scripts/aws/eks/**, **run_scripts/aws/ecs/**, **run_scripts/.../common/database/**, **run_scripts/.../aws/database/**, and **run_scripts/spark_delta-lake_scripts/** are redundant** once callers are switched to module_* paths.

### 1.4 run_scripts/.../aws/shared/ — classification (module_infra_basic vs orchestration/shared)

Everything under `run_scripts/main_application_scripts/aws/shared/` should go to either **module_infra_basic/** (shared by kube and nonkube, or prerequisite for both) or **orchestration/shared/** (orchestration flow and generic utilities).

| File or dir | Belongs to | Reason |
|-------------|------------|--------|
| **build-push-ecr.sh** | **module_infra_basic/aws/** | ECR is used by **both** ECS and EKS; building and pushing the image is a **prerequisite for both** container paths. Not kube-specific or nonkube-specific. |
| **deploy-frontend.sh** | **module_infra_basic/aws/** | Frontend S3/CloudFront deploy is **shared**: same script can target EKS or ECS by reading Terraform outputs from `module_infra_kubetypes/kube` or `module_infra_kubetypes/nonkube` (CONTAINER_TYPE). Logic is “deploy static assets to the app layer’s bucket,” shared by both. |
| **container-deploy-common.sh** | **orchestration/shared/** | Phase functions (check image, setup state bucket, deploy infra, setup DB, setup data lake, deploy frontend) are **orchestration flow**: they define the sequence and call into module_* and terraform. Not infra-specific; they belong with the orchestrator. Can be split into e.g. `orchestration/shared/phases/` (one file per phase) if desired. |
| **resources_cleanup/teardown-resources-all.sh** | **orchestration/aws/** | **Orchestrator** that runs pre-destroy, Terraform teardown, and cleanup. It invokes sub_proc scripts; the script itself is flow, so orchestration. |
| **resources_cleanup/sub_proc/** | **Split by layer** | See table below. |
| **helpers/run-with-heartbeat.sh** | **orchestration/shared/** | Generic long-running step feedback; used by teardown and deploy. Orchestration utility. |
| **helpers/long_running_feedback.py** | **orchestration/shared/** | Same: feedback/heartbeat for orchestration. |
| **helpers/prepare-frontend.sh** | **orchestration/shared/** or **module_app_core** | Builds frontend (npm build). Could live under module_app_core (frontend is app) or orchestration as “prepare step for deploy”; recommend **orchestration/shared/** so deploy flow has one place for “prepare frontend” before calling module_infra_basic deploy-frontend. |
| **helpers/cleanup-local-docker-images.sh** | **orchestration/shared/** | Local Docker cleanup; generic orchestration/cleanup helper. |
| **helpers/cloudfront-invalidation.sh** | **module_infra_basic/aws/** | CloudFront invalidation is **shared** by both EKS and ECS frontend deployments. CDN is not kube/nonkube-specific. |
| **helpers/save-deployment-state.sh** | **orchestration/shared/** | Tracks deployment state for orchestration; not infra-specific. |
| **cli/check-cloudfront-invalidation.sh** | **orchestration/aws/cli/** | Shared CDN/invalidation; project-level. |
| **cli/resource-check/** | **orchestration/aws/cli/** | Project-level AWS resource inventory; not kube/nonkube-specific. |
| **cli/resource-removal/** | **orchestration/aws/cli/** | Project-level AWS resource removal; not kube/nonkube-specific. |

**resources_cleanup/sub_proc/ — split by layer**

| Sub_proc file | Destination | Reason |
|---------------|-------------|--------|
| **shared_pre_destroy.py**, **shared_terraform_teardown.sh** | **module_infra_basic/aws/teardown/** | Shared (VPC, Aurora, IAM, etc.) layer teardown; prerequisite/infra shared by both. |
| **ecs_pre_destroy.py**, **ecs_terraform_teardown.sh** | **module_infra_kubetypes/nonkube/aws/teardown/** | ECS-specific pre-destroy and Terraform teardown. |
| **eks_pre_destroy.py**, **eks_terraform_teardown.sh** | **module_infra_kubetypes/kube/aws/teardown/** | EKS-specific pre-destroy and Terraform teardown. |
| **cleanup_orphaned.py** | **module_infra_basic/aws/teardown/** or **orchestration/aws/** | Orphan cleanup is project-level AWS; fits module_infra_basic. If it only coordinates other modules, orchestration is fine. |

After the split, **orchestration/aws/teardown-resources-all.sh** only invokes:
- `module_infra_basic/aws/teardown/shared_pre_destroy.py` (and shared_terraform_teardown.sh)
- `module_infra_kubetypes/nonkube/aws/teardown/ecs_pre_destroy.py` (and ecs_terraform_teardown.sh)
- `module_infra_kubetypes/kube/aws/teardown/eks_pre_destroy.py` (and eks_terraform_teardown.sh)
- `module_infra_basic/aws/teardown/cleanup_orphaned.py` (or equivalent)

No run_scripts paths.

---

## 2. Where each run_scripts piece should go

### 2.1 orchestration/ (run/teardown dispatch + shared utilities)

**Already there:** run.sh, teardown.sh, shared/ (logger, load-env, load-image-identifiers, performance-tracker, progress-indicator, git_helpers, load-python-env).

**Move here (from run_scripts):**

- **AWS flow orchestrator** – The logic in `run_scripts/.../aws/run.sh` (~1.2k lines): parse args, Phase 0 (preempt), deploy_ecs_full / deploy_eks_full / deploy_infrastructure, verification. Either:
  - **Option A:** Keep as a single script under `orchestration/aws/run.sh` that sources orchestration/shared and calls module_* and terraform scripts by path, or  
  - **Option B:** Rewrite as Python (e.g. `orchestration/aws/run.py`) that runs subprocesses for each phase; phases stay the same, flow is easier to test and extend.

- **Local flow orchestrator** – The logic in `run_scripts/.../local/run.sh`: parse args, preempt, then setup (kube or nonkube), schema, load data, data-lake, start services. Move to `orchestration/local/run.sh` (or `orchestration/local/run.py` if rewritten).

- **Shared phase logic** – `run_scripts/.../aws/shared/container-deploy-common.sh` → **orchestration/shared/** (e.g. `orchestration/shared/container-deploy-common.sh` or split into `orchestration/shared/phases/check_image.sh`, `setup_state_bucket.sh`, `deploy_infrastructure.sh`, etc.). Phase functions are orchestration flow; they call module_* and terraform. Breaking up into one file per phase is allowed and can improve clarity.

- **AWS teardown orchestrator** – `run_scripts/.../aws/shared/resources_cleanup/teardown-resources-all.sh`. Move to `orchestration/aws/teardown-resources-all.sh` (or `.py`). It invokes module_infra_basic, module_infra_kubetypes/kube, and module_infra_kubetypes/nonkube teardown scripts (see 1.4 sub_proc split); no run_scripts paths.

- **Local teardown** – `run_scripts/.../local/shared/resources_cleanup/teardown-resources-all.sh`. Move to `orchestration/local/teardown-resources-all.sh` (or `.py`).

- **Prerequisites** – `run_scripts/.../common/prerequisites/*` (check-and-install for aws-cli, docker, node, python, terraform, terragrunt). Move to `orchestration/prerequisites/`. Good candidate for Python: one script that checks PATH/tools and runs brew/apt/pip as needed.

- **Common helpers** – `check-dependencies.sh`, `wait-for-service.sh`, `docker_run.sh`, `verify-endpoints.sh`. Move to `orchestration/common/` (or under orchestration/shared). Small and can stay shell or become Python.

- **From run_scripts/.../aws/shared/helpers/** → **orchestration/shared/**: `run-with-heartbeat.sh`, `long_running_feedback.py`, `prepare-frontend.sh`, `cleanup-local-docker-images.sh`, `save-deployment-state.sh`. These are orchestration-level utilities, not kube/nonkube-specific infra.

Then update **orchestration/run.sh** and **orchestration/teardown.sh** to exec `orchestration/local/run.sh` (or .py), `orchestration/aws/run.sh` (or .py), and `orchestration/aws/teardown-resources-all.sh` / `orchestration/local/teardown-resources-all.sh` instead of run_scripts paths.

### 2.2 module_infra_basic (shared AWS infra + prerequisites for both kube and nonkube)

**Already there:** Terraform only (VPC, Aurora, IAM, Secrets, etc.). No scripts.

**Move here (from run_scripts/.../aws/shared/ and aws/terraform):**

- **build-push-ecr.sh** → **module_infra_basic/aws/build-push-ecr.sh** (or `aws/container/`). ECR is used by **both** ECS and EKS; building and pushing the image is a prerequisite for both. Script can keep using `module_infra_kubetypes/nonkube/local/Dockerfile.api` for the build context (or a path under module_app_core if build context moves).

- **deploy-frontend.sh** → **module_infra_basic/aws/deploy-frontend.sh**. Frontend S3/CloudFront deploy is shared; script reads Terraform outputs from `module_infra_kubetypes/kube/aws/terra/environments/$ENV/eks` or `module_infra_kubetypes/nonkube/aws/terra/environments/$ENV/ecs` depending on CONTAINER_TYPE. Optionally split: e.g. `get_frontend_bucket_from_terraform.sh` + `upload_frontend_to_s3.sh` + `invalidate_cloudfront.sh` under `module_infra_basic/aws/frontend/` if the file is large.

- **helpers/cloudfront-invalidation.sh** → **module_infra_basic/aws/helpers/cloudfront-invalidation.sh**. CloudFront is shared by both EKS and ECS frontend.

- **cli/** (check-cloudfront-invalidation.sh, resource-check/, resource-removal/) → **orchestration/aws/cli/**. Project-level AWS resource inventory and removal; not kube/nonkube-specific. Can stay as mixed shell + Python (e.g. remove-all-aws-resources.py, find-all-current-aws-resources.py).

- **resources_cleanup/sub_proc/shared_pre_destroy.py**, **shared_terraform_teardown.sh** → **module_infra_basic/aws/teardown/**. Shared (VPC, Aurora, IAM, etc.) layer pre-destroy and Terraform teardown.

- **resources_cleanup/sub_proc/cleanup_orphaned.py** → **module_infra_basic/aws/teardown/** (or **orchestration/aws/** if it only coordinates other modules). Orphan cleanup is project-level AWS.

- **Terraform layer runner** (optional) – `run_scripts/.../aws/terraform/deploy.sh`, `teardown.sh`, `setup-s3-bucket.sh`, `terra_validation.sh`, `migrate-eks-state.sh`. These run Terragrunt for infra + EKS + ECS by delegating to module_infra_basic, module_infra_kubetypes/kube, module_infra_kubetypes/nonkube. Can live under **module_infra_basic/aws/terraform/** (single “terraform runner” that knows all three module paths) or **orchestration/terraform/** if you prefer Terraform to be an orchestration concern. Recommendation: **orchestration/terraform/** so the runner stays with orchestration; it only needs to know paths to the three modules.

### 2.3 module_infra_kubetypes/kube (EKS)

**Already there:** deploy.sh, helpers, verification. aws/run.sh already calls `module_infra_kubetypes/kube/aws/deploy.sh`.

**Move here (from run_scripts/.../aws/shared/resources_cleanup/sub_proc/):**

- **eks_pre_destroy.py**, **eks_terraform_teardown.sh** → **module_infra_kubetypes/kube/aws/teardown/**. EKS-specific pre-destroy and Terraform teardown. Orchestration’s teardown-resources-all.sh will call these by path.

**Remove:** run_scripts/aws/eks/* (duplicate). Before that, update every reference that still sources or calls run_scripts/aws/eks/* to use module_infra_kubetypes/kube:

- `run_scripts/.../aws/verification/fetch-deployment-info.sh` – already uses module_infra_kubetypes/kube for EKS; no change.
- `run_scripts/.../aws/verification/print-manual-hints.sh`, `check-service-status.sh`, `diagnose-failures.sh` – currently source run_scripts/.../aws/eks/verification/* and run_scripts/.../aws/ecs/verification/*; change to source only module_infra_kubetypes/kube/aws/verification/* and module_infra_kubetypes/nonkube/aws/verification/*.
- `run_scripts/.../aws/eks/deploy.sh` – still sources run_scripts/.../aws/eks/helpers/*; delete this script and ensure no caller uses it (aws/run.sh already calls module_infra_kubetypes/kube/aws/deploy.sh). So: update any remaining callers of run_scripts/aws/eks/deploy.sh to use module_infra_kubetypes/kube/aws/deploy.sh; then remove run_scripts/aws/eks.

### 2.4 module_infra_kubetypes/nonkube (ECS + local Docker)

**Already there:** ECS Terraform, deploy.sh, helpers, verification, local Docker.

**Move here (from run_scripts/.../aws/shared/resources_cleanup/sub_proc/):**

- **ecs_pre_destroy.py**, **ecs_terraform_teardown.sh** → **module_infra_kubetypes/nonkube/aws/teardown/**. ECS-specific pre-destroy and Terraform teardown. Orchestration’s teardown-resources-all.sh will call these by path.

**Remove:** run_scripts/aws/ecs/* (duplicate). Update run_scripts/.../aws/verification/* to source module_infra_kubetypes/nonkube/aws/verification/* for ECS (see 2.3).

**Note:** build-push-ecr.sh and deploy-frontend.sh are **not** in module_infra_kubetypes/nonkube; they are shared by both ECS and EKS and live in **module_infra_basic/aws/** (see 2.2).

**Local:** start-services, stop-services, deploy (Docker build/up) already reference module_infra_kubetypes/nonkube/local. Move the scripts that contain that logic to orchestration/local/ (they only need to set DOCKER_DIR to module_infra_kubetypes/nonkube/local and run docker compose), or keep thin wrappers under orchestration that call module_infra_kubetypes/nonkube/local if you add entrypoints there.

### 2.5 module_infra_db

**Already there:** Canonical init_schema, load_data, etc. Callers already use module_infra_db.

**Remove:** run_scripts/.../common/database/, run_scripts/.../aws/database/. Ensure no remaining references (container-deploy-common and others already use module_infra_db).

### 2.6 module_infra_spark

**Already there:** Canonical Delta Lake scripts. Callers use module_infra_spark.

**Remove:** run_scripts/spark_delta-lake_scripts/. Update any script that still references run_scripts/spark_delta-lake_scripts to use module_infra_spark.

### 2.7 Verification (AWS)

**Currently in run_scripts/.../aws/verification/:** fetch-deployment-info.sh, auto_verify_and_manual_hint.sh, print-manual-hints.sh, check-service-status.sh, diagnose-failures.sh, validate-endpoints.sh. They dispatch by container type (ecs/eks) by sourcing run_scripts/.../aws/ecs/verification/* or run_scripts/.../aws/eks/verification/* (and one already uses module_infra_kubetypes/kube for EKS).

**After migration:** These should live in **orchestration/aws/verification/** and only source:

- `module_infra_kubetypes/nonkube/aws/verification/*` for ECS
- `module_infra_kubetypes/kube/aws/verification/*` for EKS  

No run_scripts paths. So: move run_scripts/.../aws/verification/* to orchestration/aws/verification/, and change every source of ecs/verification and eks/verification to module_infra_kubetypes/nonkube and module_infra_kubetypes/kube.

### 2.8 AWS-only scripts (not under aws/shared)

- **run_scripts/.../aws/bedrock/enable-model-access.sh** → **orchestration/aws/** or a small **module_app_core**-related script if it’s app config.
- **run_scripts/.../aws/check-aws-credentials.sh**, **setup-aws-profiles.sh** → **orchestration/aws/** (prerequisite/setup).

(Everything under **run_scripts/.../aws/shared/** is classified in section 1.4 and assigned to **module_infra_basic/aws/** or **orchestration/shared/** or **orchestration/aws/** or module_infra_kubetypes/kube/aws/teardown/ or module_infra_kubetypes/nonkube/aws/teardown/** as above.)

### 2.9 Local-only scripts

- **setup-env.sh**, **setup-python.sh**, **setup-frontend.sh**, **start-frontend.sh**, **deploy.sh**, **deploy-app.sh**, **reset-db.sh**, **cleanup-docker.sh**, **local/kube/setup.sh**, **local/kube/install-ingress.sh**, **local/verification/** → Move to **orchestration/local/** (or under module_infra_kubetypes/nonkube/local and module_infra_kubetypes/kube/local for kube-specific bits). deploy-app.sh and kube scripts already call module_infra_kubetypes/kube; they just need to live under orchestration/local/ and reference REPO_ROOT/module_*.

---

## 3. Breaking up code within files

You are encouraged to **split large or multi-responsibility files** into smaller files under the appropriate `module_*` or `orchestration/` folders. Examples:

- **container-deploy-common.sh** (many phase functions) → e.g. `orchestration/shared/phases/check_image.sh`, `setup_state_bucket.sh`, `deploy_infrastructure.sh`, `setup_database.sh`, `setup_data_lake.sh`, `deploy_frontend.sh`, plus a small `container-deploy-common.sh` that sources them, or a single Python module with one function per phase.
- **deploy-frontend.sh** (build, upload, invalidate) → e.g. `module_infra_basic/aws/frontend/get_bucket_from_terraform.sh`, `upload_to_s3.sh`, `invalidate_cloudfront.sh`, and a thin `deploy-frontend.sh` that calls them; or keep one file if it stays readable.
- **teardown-resources-all.sh** – already delegates to sub_proc; after moving sub_proc into module_infra_basic, module_infra_kubetypes/kube, module_infra_kubetypes/nonkube teardown dirs, the orchestrator script can stay as one file that invokes those paths.
- **aws/run.sh** – if kept as shell, consider extracting phase blocks into `orchestration/aws/phases/` (e.g. `phase0_preempt.sh`, `deploy_ecs_full.sh`, `deploy_eks_full.sh`) and sourcing them from a thin `run.sh`; or rewrite as Python and use one function per phase.

Prefer **one clear responsibility per file** and **existing or new files under the correct module_** so that ownership (module_infra_basic vs orchestration vs module_infra_kubetypes/kube vs module_infra_kubetypes/nonkube) is obvious.

---

## 4. Python vs shell

- **Orchestrators (aws/run.sh, local/run.sh, teardown-resources-all.sh):** Rewriting in Python is reasonable: one place for flow, easier unit tests, no bash step-number parsing, subprocess calls to terraform/docker/kubectl/scripts. Shell one-liners can stay as subprocess calls.
- **container-deploy-common.sh:** Phase functions can become Python functions that run subprocesses for each step; called from the Python AWS orchestrator.
- **Prerequisites (check-and-install):** Python can detect OS, check PATH, run brew/apt/pip; simpler than multiple shell scripts per tool.
- **Terraform runner (deploy.sh, teardown.sh):** Can stay shell (thin wrappers around terragrunt) or become Python that runs terragrunt in the right dirs; either is fine.
- **Module scripts (build-push-ecr, deploy-frontend, kubernetes-manifests, etc.):** Keep as shell unless you have a strong reason (e.g. complex logic, need to share code with app). They are invoked by the orchestrator.

---

## 5. Dependency order and removal sequence

1. **Update callers to module_* only**  
   - fetch-deployment-info.sh, print-manual-hints.sh, check-service-status.sh, diagnose-failures.sh: source module_infra_kubetypes/nonkube and module_infra_kubetypes/kube for ECS/EKS; remove any source of run_scripts/aws/ecs or run_scripts/aws/eks.  
   - run_scripts/aws/eks/deploy.sh: ensure nothing calls it (only module_infra_kubetypes/kube/aws/deploy.sh is used).

2. **Move orchestration glue into orchestration/**  
   - AWS: run.sh, container-deploy-common.sh, teardown-resources-all.sh, verification/*, terraform/* (or put terraform under module_infra_basic or orchestration/terraform), build-push-ecr and deploy-frontend (move to module_infra_basic/aws/), helpers, bedrock, check-aws-credentials, setup-aws-profiles, cli/*.  
   - Local: run.sh, teardown-resources-all.sh, start-services, stop-services, deploy, setup-*, kube/*, verification/*.

3. **Move shared/common into orchestration/**  
   - common/prerequisites → orchestration/prerequisites.  
   - common/check-dependencies, wait-for-service, docker_run, verify-endpoints → orchestration/common or shared.

4. **Point orchestration/run.sh and teardown.sh** at the new paths under orchestration/ (e.g. orchestration/aws/run.sh, orchestration/local/run.sh, orchestration/aws/teardown-resources-all.sh, orchestration/local/teardown-resources-all.sh).

5. **Remove redundant trees**  
   - run_scripts/aws/eks, run_scripts/aws/ecs, run_scripts/.../common/database, run_scripts/.../aws/database, run_scripts/spark_delta-lake_scripts.

6. **Remove the rest of run_scripts/**  
   - After everything is moved and both run and teardown work from orchestration + module_*, delete the entire run_scripts/ directory.

---

## 6. Concise summary

(See section 1.4 for the full run_scripts/.../aws/shared/ classification: module_infra_basic vs orchestration/shared vs module_infra_kubetypes/kube/aws/teardown vs module_infra_kubetypes/nonkube/aws/teardown.)

| Current location (run_scripts) | Destination | Notes |
|-------------------------------|------------|--------|
| **orchestration/run.sh, teardown.sh** | Already in orchestration | Only change: exec paths from run_scripts/... to orchestration/aws/..., orchestration/local/... |
| **main_application_scripts/aws/run.sh** | **orchestration/aws/run.sh** (or run.py) | AWS flow; consider Python for flow + phases |
| **main_application_scripts/aws/shared/container-deploy-common.sh** | **orchestration/shared/** | Phase helpers; can split into orchestration/shared/phases/ |
| **main_application_scripts/aws/shared/resources_cleanup/teardown-resources-all.sh** | **orchestration/aws/teardown-resources-all.sh** (.py) | AWS teardown orchestrator |
| **main_application_scripts/local/run.sh** | **orchestration/local/run.sh** (.py) | Local flow |
| **main_application_scripts/local/.../teardown-resources-all.sh** | **orchestration/local/teardown-resources-all.sh** (.py) | Local teardown |
| **main_application_scripts/aws/terraform/** | **orchestration/terraform/** (or module_infra_basic/aws/terraform/) | Single Terraform runner for all layers |
| **main_application_scripts/aws/shared/build-push-ecr.sh** | **module_infra_basic/aws/** | ECR shared by both ECS and EKS; prerequisite for both |
| **main_application_scripts/aws/shared/deploy-frontend.sh** | **module_infra_basic/aws/** | Frontend S3/CloudFront deploy shared by both EKS and ECS |
| **main_application_scripts/aws/shared/helpers/cloudfront-invalidation.sh** | **module_infra_basic/aws/helpers/** | CDN shared by both |
| **main_application_scripts/aws/shared/cli/** (check-cloudfront-invalidation, resource-check, resource-removal) | **orchestration/aws/cli/** | Project-level AWS resources; not kube/nonkube-specific |
| **main_application_scripts/aws/shared/resources_cleanup/sub_proc/shared_*, cleanup_orphaned.py** | **module_infra_basic/aws/teardown/** | Shared layer teardown; orphan cleanup project-level |
| **main_application_scripts/aws/shared/resources_cleanup/sub_proc/eks_*** | **module_infra_kubetypes/kube/aws/teardown/** | EKS-specific pre-destroy and Terraform teardown |
| **main_application_scripts/aws/shared/resources_cleanup/sub_proc/ecs_*** | **module_infra_kubetypes/nonkube/aws/teardown/** | ECS-specific pre-destroy and Terraform teardown |
| **main_application_scripts/aws/shared/helpers/** (run-with-heartbeat, long_running_feedback, prepare-frontend, cleanup-local-docker-images, save-deployment-state) | **orchestration/shared/** | Orchestration-level utilities |
| **main_application_scripts/aws/verification/** | **orchestration/aws/verification/** | Dispatch to module_infra_kubetypes/kube and module_infra_kubetypes/nonkube only |
| **main_application_scripts/aws/bedrock, check-aws-credentials, setup-aws-profiles** | **orchestration/aws/** | Prerequisite/setup; shared/helpers → orchestration/shared; shared/cli → orchestration/aws/cli |
| **main_application_scripts/common/prerequisites/** | **orchestration/prerequisites/** | Good candidate for Python |
| **main_application_scripts/common/** (check-dependencies, wait-for-service, docker_run, verify-endpoints) | **orchestration/common/** | Shared helpers |
| **main_application_scripts/local/** (setup-*, start/stop, deploy, kube, verification) | **orchestration/local/** | Thin wrappers; keep calling module_* |
| **main_application_scripts/aws/eks/** | **Remove** | Use module_infra_kubetypes/kube only; update verification to source module paths |
| **main_application_scripts/aws/ecs/** | **Remove** | Use module_infra_kubetypes/nonkube only |
| **main_application_scripts/.../common/database/, aws/database/** | **Remove** | Use module_infra_db only |
| **spark_delta-lake_scripts/** | **Remove** | Use module_infra_spark only |

**Result:** All “run” and “teardown” logic lives under **orchestration/** (with optional Python for orchestrators and prerequisites). All infra-specific actions live in **module_infra_***. No remaining references to run_scripts/. Then **run_scripts/** can be deleted.

**Risks:** Many cross-references (paths, source statements); move in small steps and run a full deploy/teardown after each step. Converting orchestrators to Python is a larger change but improves long-term maintainability.
