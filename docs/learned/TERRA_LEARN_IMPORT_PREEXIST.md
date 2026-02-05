# Import pre-existing resources (post–brutal-removal state reconciliation)

## Why we need these scripts

### What happens when you run "Remove All" and then deploy

We have a **brutal-removal** flow (`orchestration/aws/cli/resource-removal/remove-all-aws-resources.sh`) that deletes AWS resources by calling the AWS API directly. It does **not** use Terraform/Terragrunt, so Terraform state is never updated. The script removes things like:

- CloudFront distributions, EKS clusters, ECS clusters, load balancers, NAT gateways, ENIs, subnets, security groups, VPCs, ECR repos, S3 buckets (except the state bucket), etc.

It **does not** delete (by design or AWS behavior):

- **IAM roles** (global; often left behind)
- **Secrets Manager** secrets (preserved on purpose)
- **KMS** keys and aliases (sometimes left behind)
- **CloudWatch** log groups
- **CloudFront Origin Access Control (OAC)** (distributions may be deleted; OAC can remain)

So after a "Remove All" run, some resources still exist in AWS, but Terraform state either (a) still thinks they were destroyed, or (b) was never told they exist. When you then run the normal deploy (`run.sh` → `orchestration/terraform/deploy.sh` → `terragrunt apply`), Terraform tries to **create** those resources again. AWS responds that they already exist, and the apply fails.

### Exceptions you see

Typical errors when state and reality are out of sync:

| Exception / message | Meaning |
|---------------------|--------|
| `EntityAlreadyExists: Role with name ... already exists` | IAM role exists in AWS but not in Terraform state (e.g. EKS cluster role, node group role). |
| `AlreadyExistsException: An alias with the name ... already exists` | KMS alias exists in AWS but not in state. |
| `ResourceAlreadyExistsException: The specified log group already exists` | CloudWatch log group exists but not in state. |
| `OriginAccessControlAlreadyExists: An origin access control with the same name already exists` | CloudFront OAC exists but not in state (common after brutal removal). |
| `ResourceExistsException` (Secrets Manager) | Secret exists in AWS but not in state. |

To fix this, we **import** those existing resources into Terraform state so Terraform treats them as managed instead of trying to create them again. The scripts in this directory do that import per layer. They are safe to run even when nothing is left behind (resources that don't exist are skipped).

**Preferred approach:** Use Terraform-based teardown (`teardown.sh` / `teardown-resources-all.sh`) instead of brutal removal when possible, so state and AWS stay in sync and you rarely need these imports.

---

## What counts as one "layer"

**One layer = one Terragrunt apply/destroy unit:** a directory that has a `terragrunt.hcl` and that we run `terragrunt apply` or `terragrunt destroy` on during deploy/teardown.

- **We do NOT count** each `main.tf` under `module_infra_basic/aws/terra/modules/`. Those are **modules** (reusable Terraform code). One layer can use several modules (e.g. infrastructure uses vpc, aurora, iam, secrets-manager, s3-data).
- **We DO count** each distinct **layer name** under `*/terra/environments/{dev,prod}/` — i.e. each directory with a `terragrunt.hcl` that we apply/destroy as a single step.

So: **layer** = one entry in the deploy/teardown flow (e.g. "infrastructure", "ecs", "eks", "frontend-ecs", "frontend-eks"). Dev and prod share the same layer names; we have one import script per layer name, parameterized by environment.

## How many such layers exist

There are **5** Terragrunt layers that create AWS resources and can be affected by the brutal removal script:

| # | Layer name      | Terragrunt path (per env)                                      | Typical leftovers after brutal removal |
|---|-----------------|----------------------------------------------------------------|----------------------------------------|
| 1 | infrastructure  | `module_infra_basic/aws/terra/environments/{dev,prod}/infrastructure` | IAM roles, RDS subnet group, Secrets Manager (script preserves), KMS |
| 2 | ecs             | `module_infra_kubetypes/nonkube/aws/terra/environments/{dev,prod}/ecs` | CloudWatch log group, ALB, target group |
| 3 | eks             | `module_infra_kubetypes/kube/aws/terra/environments/{dev,prod}/eks`   | IAM roles, KMS alias/key, CloudWatch log group |
| 4 | frontend-ecs    | `module_infra_basic/aws/terra/environments/{dev,prod}/frontend-ecs`   | CloudFront OAC, S3 bucket, CloudFront distribution |
| 5 | frontend-eks    | `module_infra_basic/aws/terra/environments/{dev,prod}/frontend-eks`   | CloudFront OAC, S3 bucket, CloudFront distribution |

## Import script coverage

All import scripts live in **`orchestration/terraform/import_preexist/`**. They share a common library:

- **`common/lib_import_common.sh`** — Bootstrap (REPO_ROOT, logger, env), argument parsing, env validation, directory check + `cd`, `terragrunt init` (strict/soft), state-lock parsing and force-unlock retry, `import_one_resource`, and `import_batch`. Scripts source this and call the helpers; no change to CLI or callers.

| Layer          | Script | Used in deploy? |
|----------------|--------|------------------|
| infrastructure | `import-existing-infrastructure.sh` | Yes (before infrastructure plan/apply) |
| ecs            | `import-existing-ecs.sh` | Yes (before ECS plan/apply) |
| eks            | `import-existing-eks.sh` | Yes (before EKS plan/apply) |
| frontend-ecs   | `import-existing-frontend-ecs.sh` | Yes (before frontend-ecs plan/apply) |
| frontend-eks   | `import-existing-frontend-eks.sh` | Yes (before frontend-eks plan/apply) |

All five layers have a dedicated import script. `orchestration/terraform/deploy.sh` runs each layer’s import script just before that layer’s plan/apply (per-layer, so only the layers you’re deploying get their import run).

**Import before destroy (teardown):** `teardown-resources-all.sh` runs the relevant import script(s) *before* each layer's `terragrunt destroy` (infrastructure before shared destroy; EKS + frontend-eks before EKS destroy; ECS + frontend-ecs before ECS destroy). If state was empty but AWS still has resources, destroy can then remove them. All import scripts accept `dev`, `staging`, or `prod`.

### Teardown-mode reconciliation details (recent learnings)

- **Purpose before destroy:** imports in teardown are **only for reconciliation**. They make sure Terraform state sees any leftover AWS resources so `terragrunt destroy` can actually delete them instead of no-op’ing. If a resource does not exist or is already in state, that is **not** a fatal error.
- **Benign errors we now classify as non-fatal:**
  - `Resource already managed by Terraform` → treated as **OK (already in state)**.
  - `Cannot import non-existent remote object` and similar (`NoSuchEntity`, `ResourceNotFoundException`, `does not exist`, `NoSuchKey`, etc.) → treated as **Skip (resource does not exist in AWS)**.
  - Terragrunt dependency warnings like *“... is a dependency of ./terragrunt.hcl but detected no outputs, but mock outputs provided ...”* are expected when using `mock_outputs` for unapplied dependencies; imports for teardown don’t require those outputs.
- **State lock handling during import:** when Terraform prints `Error acquiring the state lock`, the shared helper:
  - Parses the lock ID from the log.
  - Runs `terragrunt force-unlock -force <LOCK_ID>`.
  - Retries the import once and then re-classifies the result (success, already-managed, non-existent, or real failure).
  This prevents stale locks from breaking reconcile imports during teardown.

## Quick reference

- **Run all imports for one env (manual):**
  - `./orchestration/terraform/import_preexist/import-existing-infrastructure.sh dev fru`
  - `./orchestration/terraform/import_preexist/import-existing-ecs.sh dev fru`
  - `./orchestration/terraform/import_preexist/import-existing-eks.sh dev fru`
  - `./orchestration/terraform/import_preexist/import-existing-frontend-ecs.sh dev fru`
  - `./orchestration/terraform/import_preexist/import-existing-frontend-eks.sh dev fru`
- **Deploy** (runs EKS + frontend-eks imports automatically for EKS path; ECS + frontend-ecs for ECS path):  
  `./orchestration/terraform/deploy.sh dev eks` or `dev ecs` or `dev all`.

Run scripts from repo root or with correct `REPO_ROOT`.

## See also

- **docs/DEPLOYMENT_ERRORS_AND_FIXES.md** — Phase 2 Terraform "subnet group / VPC mismatch", S3 bucket empty, frontend invalid bucket, Docker not running, Terraform plugin checksum: causes and fixes.

