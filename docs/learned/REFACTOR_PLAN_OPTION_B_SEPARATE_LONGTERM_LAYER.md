# Refactor Plan: Option B — Separate Long-Term Layer (Secrets Manager)

**Status: Implemented.** The repo now uses Option B: infrastructure-longterm layer (Secrets Manager only), applied first and never destroyed by main teardown; infrastructure layer (VPC, Aurora, IAM, S3) reads secret ARNs via remote_state and destroys in one pass.

**Goal:** Run `./run.sh <local|aws> <kube|nonkube> dev --preempt` problem-free, without relying on `prevent_destroy` + state-rm workarounds in the infrastructure layer.

**Approach:** Move long-term components (Secrets Manager) into a **separate Terragrunt layer** (`infrastructure-longterm`). Main teardown destroys only the ephemeral infrastructure layer (VPC, Aurora, IAM, S3); the longterm layer is **never** destroyed in the normal flow. See [TERRA_LEARNED.md](TERRA_LEARNED.md) §3 (Option B).

**Related:** [VPC_LEARNED.md](VPC_LEARNED.md) §3.2 (VPC/subnet fix options), [DEPLOYMENT_ERRORS_AND_FIXES.md](../DEPLOYMENT_ERRORS_AND_FIXES.md) §1, [README_WAR_STORIES.md](../../README_WAR_STORIES.md) (16, 17, 18).

---

## 1. Current State (Option A / Fail-Back)

| Item | Current behavior |
|------|------------------|
| **Infrastructure layer** | Single layer: VPC, Aurora, IAM, **Secrets Manager**, S3. One state file, one apply/destroy. |
| **Secrets Manager** | In same layer; has `lifecycle { prevent_destroy = true }`. |
| **Teardown** | `terragrunt destroy` for infrastructure **aborts** when it hits prevent_destroy (Terraform aborts the *entire* destroy). VPC, Aurora, DB subnet group are **not** destroyed → next deploy re-imports subnet group and hits "The new Subnets are not in the same Vpc as the existing subnet group". |
| **Workaround** | When `PREEMPT=true`, `orchestration/terraform/teardown.sh` removes Secrets Manager resources from state (`terragrunt state rm`), then re-runs destroy so VPC, Aurora, subnet group are removed. Secrets stay in AWS; re-imported on next deploy. |

This works but couples teardown logic to a specific list of state addresses and requires maintaining that list when secrets change.

---

## 2. Target State (Option B)

| Item | Target behavior |
|------|-----------------|
| **infrastructure-longterm** | New Terragrunt layer: **Secrets Manager only**. Own state key, e.g. `dev/infrastructure-longterm/terraform.tfstate`. Deploy: apply this layer **first**. Teardown: **never** destroy this layer in the main flow. |
| **infrastructure** | Same layer but **without** Secrets Manager. Uses `terraform_remote_state` (or data source) to read secret ARNs from the longterm layer. Deploy: apply **after** longterm. Teardown: destroy this layer as today (no prevent_destroy, no state-rm). |
| **Main teardown** | Destroys EKS/ECS + **infrastructure** only. Never runs destroy on **infrastructure-longterm**. Optional: dedicated `teardown-longterm.sh` for rare explicit destruction. |

Result: `./run.sh aws kube dev --preempt` runs teardown (no prevent_destroy in the destroyed layer) then deploy (longterm apply → infrastructure apply); no VPC/subnet mismatch because infrastructure destroy actually removes the DB subnet group.

---

## 3. Refactor Steps (Detailed)

### 3.1 Create the Longterm Layer Directory and Terragrunt Config

**Location:** `module_infra_basic/aws/terra/environments/<env>/infrastructure-longterm/`

- **Files to add:**
  - `terragrunt.hcl` — include root, include a new component base (e.g. `longterm-base.hcl`), pass env inputs (project_name, environment, openai_api_key, db_password, db_username, etc.).
- **Component base:** `_component/longterm-base.hcl` (or extend a shared base) that sets:
  - `terraform { source = ".../modules//secrets-manager" }` (or a thin wrapper module that only calls the existing secrets-manager module).
  - `inputs` — same as current secrets_manager inputs (project_name, environment, openai_api_key, db_password, db_username, create_db_username_secret, tags).

**State key:** By Terragrunt `path_relative_to_include()`, the state key will be e.g. `dev/infrastructure-longterm/terraform.tfstate`. No change to root.hcl needed.

**Comments in code:** In `terragrunt.hcl` and `longterm-base.hcl`, add a short comment: "Long-term layer: Secrets Manager only. Not destroyed by main teardown (see docs/learned/TERRA_LEARNED.md Option B)."

### 3.2 Create a Wrapper Module (Optional but Clean)

**Option A:** Point longterm layer directly at `modules//secrets-manager`. Simpler.

**Option B:** Add `modules/longterm` that only contains a single module block calling `secrets-manager`, and re-export outputs. Makes it clear this layer is "longterm" and easier to add more long-term resources later (e.g. KMS keys).

Recommendation: Start with **Option A** (source = `.../modules//secrets-manager`). Add a README in `infrastructure-longterm` describing that this layer holds Secrets Manager and is not destroyed by `teardown.sh aws all`.

### 3.3 Remove Secrets Manager from the Infrastructure Module

**File:** `module_infra_basic/aws/terra/modules/infrastructure/main.tf`

- Remove the `module "secrets_manager" { ... }` block.
- Add a `terraform_remote_state` data source (or `data "aws_secretsmanager_secret"` by name) to read secret ARNs from the longterm layer. Prefer **remote_state** so apply order is enforced (longterm must be applied first).

**Example (remote_state):**

```hcl
# Secret ARNs come from the long-term layer (infrastructure-longterm). That layer is applied first and never destroyed by main teardown.
data "terraform_remote_state" "longterm" {
  backend = "s3"
  config = {
    bucket = var.tf_state_bucket
    key    = "${var.environment}/infrastructure-longterm/terraform.tfstate"
    region = var.aws_region
  }
}
```

Then in `module "iam"` and anywhere else that used `module.secrets_manager.*`, replace with `data.terraform_remote_state.longterm.outputs.*` (openai_secret_arn, db_password_secret_arn, etc.). Infrastructure module will need new variables: `tf_state_bucket` (or pass state bucket from root), `environment`.

**Files to touch:**
- `modules/infrastructure/main.tf` — remove secrets_manager module; add remote_state; wire IAM (and any other consumers) to remote_state outputs.
- `modules/infrastructure/variables.tf` — add `tf_state_bucket`, ensure `environment` exists; remove any secrets_manager-only variables that are now only in longterm.
- `modules/infrastructure/outputs.tf` — replace `module.secrets_manager.*` outputs with `data.terraform_remote_state.longterm.outputs.*` (re-export so existing callers of infrastructure outputs still work).

**Comments:** In `main.tf`, add a short comment above the remote_state block: "Long-term layer state; do not destroy that layer in main teardown (Option B)."

### 3.4 Update infrastructure-base.hcl Inputs

- Remove inputs that were only for Secrets Manager (openai_api_key, db_password, db_username, create_db_username_secret) from the **infrastructure** component base — they are not needed in the ephemeral infrastructure layer anymore (they live in longterm).
- Add inputs required for remote_state (e.g. tf_state_bucket from root or env).

### 3.5 Deploy Order: Apply Longterm Before Infrastructure

**File:** `orchestration/terraform/deploy.sh`

- When `LAYER` is `infrastructure` or `all`, deploy **two** sub-steps:
  1. **infrastructure-longterm** — if directory exists, run import script (see 3.8), then `cd .../infrastructure-longterm` and terragrunt init, plan, apply.
  2. **infrastructure** — as today (import-existing-infrastructure.sh, then init, plan, apply for infrastructure).

**Layer validation:** Extend the allowed LAYER regex to include `infrastructure-longterm` if you want to deploy only longterm (e.g. for testing). For `all`, always deploy longterm before infrastructure.

**Comments in deploy.sh:** Before the infrastructure block, add: "Deploy longterm layer first (Secrets Manager); then ephemeral infrastructure (VPC, Aurora, IAM). Longterm is never destroyed by teardown."

### 3.6 Teardown: Never Destroy Longterm

**Files:** `orchestration/terraform/teardown.sh`, `orchestration/aws/teardown-resources-all.sh`

- **Do not** add any step that runs `terragrunt destroy` for `infrastructure-longterm` when `--container-type all` or during preempt.
- Remove the **prevent_destroy workaround** from `orchestration/terraform/teardown.sh`: delete the block that does `state rm` on Secrets Manager resources and the second `terragrunt destroy`. Infrastructure layer no longer contains Secrets Manager, so destroy will succeed in one pass.
- **Optional:** Add a separate script `teardown-longterm.sh` (or a flag) that explicitly destroys the longterm layer when the user really wants to (e.g. account decommission). Document in README.

**Comments in teardown.sh:** Where infrastructure destroy runs, add: "Infrastructure layer no longer includes Secrets Manager (moved to infrastructure-longterm). Destroy runs once; no state-rm workaround."

### 3.7 Import Script for Longterm

**New file:** `orchestration/terraform/import_preexist/import-existing-longterm.sh`

- Same pattern as `import-existing-infrastructure.sh`: cd to `.../environments/$ENV/infrastructure-longterm`, run `terragrunt init`, then `terragrunt import` for each Secrets Manager secret and secret version (same resource addresses as in the current import script for secrets, but for the longterm layer directory).
- Call this script **before** applying the longterm layer (in deploy.sh), and optionally before any manual destroy of longterm (if you add teardown-longterm.sh).

### 3.8 Update Import-Existing-Infrastructure Script

**File:** `orchestration/terraform/import_preexist/import-existing-infrastructure.sh`

- **Remove** imports for Secrets Manager resources (they now live in the longterm layer and are imported by import-existing-longterm.sh).
- Keep imports for: RDS subnet group, IAM roles, and any other resources that remain in the infrastructure layer (VPC, Aurora, etc. — only import what the script currently imports that still exists in the infrastructure module).

### 3.9 Shared Pre-Destroy and Other Scripts

**File:** `module_infra_basic/aws/teardown/shared_pre_destroy.py`

- If it touches Secrets Manager (e.g. scaling or stopping something that uses secrets), no change. If it was preparing for Secrets Manager destruction, remove that; longterm is not destroyed here.

**File:** `module_infra_basic/aws/teardown/shared_terraform_teardown.sh`

- Still calls `orchestration/terraform/teardown.sh ... infrastructure`. No change to the script; teardown.sh no longer runs destroy for longterm, and infrastructure destroy no longer hits prevent_destroy.

### 3.10 Documentation Updates

- **docs/learned/TERRA_LEARNED.md** — Already describes Option B; add one sentence: "Implemented: infrastructure-longterm layer holds Secrets Manager; main teardown does not destroy it."
- **docs/DEPLOYMENT_ERRORS_AND_FIXES.md** §1 — Update to state that after Option B refactor, clean slate (e.g. `--preempt`) does not rely on prevent_destroy or state-rm; infrastructure destroy removes VPC/Aurora/subnet group in one pass. Option B (import) for VPC/subnet still applies if someone has two VPCs and wants to keep one.
- **README_WAR_STORIES.md** — Add (or extend) war story: "Subnet group / VPC mismatch — what we did (import before destroy, prevent_destroy workaround) and Option A vs Option B (separate longterm layer)." See task 4 below.
- **orchestration/run.sh, orchestration/teardown.sh, run.sh, teardown.sh** — Enrich usage headers (see task 3 below).

---

## 4. After the Refactor: Can We Achieve Goal Immediately?

**Goal:** `./run.sh <local|aws> <kube|nonkube> dev --preempt` problem-free.

- **Yes**, once the refactor is complete and tested:
  1. **Preempt** runs teardown with `--container-type all` (EKS + ECS + shared).
  2. Shared teardown runs **only** infrastructure layer destroy (no longterm). Infrastructure no longer contains Secrets Manager, so **one** `terragrunt destroy` removes VPC, Aurora, DB subnet group, IAM, S3.
  3. Deploy runs: longterm apply (Secrets Manager) → infrastructure apply (VPC, Aurora, IAM, S3). One VPC, one subnet group; no mismatch.
- **No extra steps** required for the user beyond running the refactored code. Optional: document that the first time after refactor, if longterm state doesn’t exist yet, deploy will create the longterm layer first (and may require initial secret values from env).

**Edge case:** If the longterm layer has never been applied (e.g. new account), infrastructure’s `terraform_remote_state` will fail until longterm is applied. Deploy order (longterm → infrastructure) handles that. If someone runs only "infrastructure" deploy without longterm, they must run longterm first; deploy.sh should enforce order when LAYER=all or LAYER=infrastructure (apply longterm then infrastructure).

---

## 5. Summary Checklist

| # | Task | Notes |
|---|------|--------|
| 1 | Create `environments/<env>/infrastructure-longterm/terragrunt.hcl` and `_component/longterm-base.hcl` | State key auto: `dev/infrastructure-longterm/terraform.tfstate` |
| 2 | Point longterm at `modules//secrets-manager` (or wrapper) | Same inputs as current secrets_manager in infrastructure-base |
| 3 | Remove `module "secrets_manager"` from infrastructure; add `terraform_remote_state` for longterm; wire IAM (and outputs) to remote_state outputs | Add tf_state_bucket (or equivalent) to infrastructure inputs |
| 4 | Update infrastructure-base.hcl: remove secrets-only inputs; add state bucket for remote_state | |
| 5 | deploy.sh: apply infrastructure-longterm before infrastructure when deploying infra | Run import-existing-longterm.sh before longterm apply |
| 6 | teardown.sh: remove prevent_destroy state-rm and second destroy; do not add destroy for longterm | |
| 7 | Add import-existing-longterm.sh; call it before longterm apply | |
| 8 | import-existing-infrastructure.sh: remove Secrets Manager imports | |
| 9 | Docs: TERRA_LEARNED, DEPLOYMENT_ERRORS_AND_FIXES, README_WAR_STORIES, script headers | |
| 10 | Optional: teardown-longterm.sh for explicit longterm destroy | |

---

*This doc: `docs/learned/REFACTOR_PLAN_OPTION_B_SEPARATE_LONGTERM_LAYER.md`. Related: [TERRA_LEARNED.md](TERRA_LEARNED.md), [VPC_LEARNED.md](VPC_LEARNED.md), [DEPLOYMENT_ERRORS_AND_FIXES.md](../DEPLOYMENT_ERRORS_AND_FIXES.md), [README_WAR_STORIES.md](../../README_WAR_STORIES.md).*
