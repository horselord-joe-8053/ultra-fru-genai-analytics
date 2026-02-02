# Deployment Errors and Fixes

This doc summarizes errors seen during `./run.sh aws kube dev` (and related EKS/ECS flows), their root causes, and how to fix them.

---

## 1. Phase 2: Terraform infrastructure — subnet group / VPC mismatch

**Symptom:** Terraform plan or apply for the **infrastructure** layer fails with an error about the RDS DB subnet group and VPC (e.g. "subnet group must contain only subnets in the same VPC", or update of `aws_db_subnet_group.aurora` failing because subnets belong to a different VPC).

**Root cause:** State vs reality mismatch:

- The **infrastructure** layer creates: VPC → subnets → RDS subnet group → Aurora. All are tied to one VPC in a single apply.
- If you end up with **two VPCs** in the account (e.g. state was lost and Terraform created a new VPC, or a previous run left an old VPC), the **existing** RDS subnet group in AWS may still reference subnets from the **old** VPC.
- Terraform (with current state) then tries to:
  - **Update** the existing subnet group to use subnets from the **new** VPC, or
  - **Create** a new subnet group with the same name (fails: name already exists).
- AWS does not allow a DB subnet group to mix subnets from different VPCs or to "move" to another VPC by replacing subnets.

**Relevant code:**  
- Infrastructure: `module_infra_basic/aws/terra/modules/infrastructure/main.tf` (VPC + Aurora); Aurora subnet group: `module_infra_basic/aws/terra/modules/aurora/main.tf` (`aws_db_subnet_group.aurora` uses `module.vpc.private_subnet_ids` and same VPC in code; mismatch only appears when AWS already has a subnet group from a different VPC).

**Fixes (pick one):**

1. **Clean slate (recommended if you can destroy dev):**  
   `./run.sh aws kube dev --preempt`  
   This tears down **all** layers (EKS + ECS + shared infrastructure: VPC, Aurora, DB subnet group) then redeploys only the requested type (e.g. kube). Ensures one VPC and one subnet group in sync.  
   - Preempt uses `--container-type all` so shared infra is torn down (not just EKS).  
   - Teardown runs **import existing infrastructure into state before destroy** when tearing down shared infra, so orphaned resources (e.g. DB subnet group) are removed instead of no-op.  
   - **Option B (implemented):** Secrets Manager is in a separate **infrastructure-longterm** layer that is **never** destroyed by main teardown. The infrastructure layer (VPC, Aurora, IAM, S3) has no `prevent_destroy`; one `terragrunt destroy` removes the subnet group and the rest. No state-rm workaround.

2. **Import existing infrastructure into state:**  
   Before running deploy again, run:  
   `./orchestration/terraform/import_preexist/import-existing-infrastructure.sh dev fru`  
   Then run `./run.sh aws kube dev` again. Only helps if the **current** Terraform config (VPC + subnets) matches what you want to keep; if you have two VPCs and want to keep one, you must align state and config to that VPC (or destroy the other and re-import).

3. **Manual cleanup (advanced):**  
   - In AWS: delete the RDS cluster (and instances) that use the subnet group, then delete the DB subnet group `fru-dev-aurora-subnet-group`.  
   - Optionally remove the old VPC and its subnets if unused.  
   - Re-run deploy so Terraform creates a fresh subnet group and Aurora in the remaining (or new) VPC.

**Prevention:** Use a single Terraform state for the infrastructure layer; avoid recreating state or running with a different state bucket that leaves orphan VPCs and subnet groups in the account.

**Migration from pre–Option B:** If you had Secrets Manager in the **infrastructure** layer and are now on Option B (separate **infrastructure-longterm**), one-time: run `import-existing-longterm.sh` to adopt existing secrets into longterm state, apply the longterm layer, then in the **infrastructure** directory run `terragrunt state rm 'module.secrets_manager.aws_secretsmanager_secret_version.openai_key'` (and the other secret resources listed in the old teardown.sh state-rm list) so infrastructure no longer tries to destroy them, then run infrastructure apply. See `docs/learned/REFACTOR_PLAN_OPTION_B_SEPARATE_LONGTERM_LAYER.md`.

---

## 2. Data lake: "Invalid bucket name ''" (S3_BUCKET_ID empty)

**Symptom:** Data lake setup (e.g. Delta Lake / S3 upload) fails with `Invalid bucket name ''` — the script is calling `s3:///raw/...` because `S3_BUCKET_ID` is empty.

**Root cause:**  
- The data lake step reads the S3 bucket ID from Terraform outputs (e.g. from the layer that creates the analytics/S3 bucket).  
- If that layer hasn’t been applied for the current environment (e.g. EKS path didn’t apply the bucket layer, or outputs aren’t available), the script gets an empty value and still runs `aws s3 cp ... s3:///...`.

**Fix (already in code):**  
- Scripts now **fail fast** if `S3_BUCKET_ID` is empty (e.g. `module_infra_spark/common/delta-lake/helpers/aws/setup-delta-lake-aws.sh` and `module_infra_spark/aws/delta-lake/setup-and-verify.sh` exit with an error and a clear message).  
- Ensure the Terraform layer that creates the S3 bucket for the data lake is applied before running data lake setup, and that the script is run in an environment where `terragrunt output` (or equivalent) returns the bucket ID.

**Prevention:** Orchestration runs the data lake phase only after the relevant infra is deployed and captures the phase exit code so a failure here stops the pipeline (see orchestration/aws/run.sh).

---

## 3. Frontend deploy: "Invalid bucket name" (e.g. "Warning: No outputs found...")

**Symptom:** Frontend deploy (S3 sync / CloudFront) fails with AWS error that the bucket name is invalid; the "bucket name" might be the literal Terraform warning text (e.g. "Warning: No outputs found...").

**Root cause:**  
- The script gets `s3_bucket_id` from `terragrunt output -raw s3_bucket_id` for the **frontend-eks** (or frontend-ecs) layer.  
- If that layer has never been applied, there are no outputs, and Terragrunt prints a warning; that warning was captured as the bucket name and passed to `aws s3 sync ... s3://<that text>/...`.

**Fix (already in code):**  
- For EKS, **Phase 5.1b** deploys the **frontend-eks** Terraform layer before frontend deploy, so `s3_bucket_id` exists.  
- Scripts should validate that the output is a non-empty, plausible bucket name before calling `aws s3` (see README_WAR_STORIES for the original war story).

**Reference:** README_WAR_STORIES.md — "Invalid bucket name" / frontend deploy.

---

## 4. Phase 0: Docker daemon not running

**Symptom:** Phase 0 (prerequisites) fails with "Docker daemon must be running" or "Docker daemon did not start within 60 seconds".

**Root cause:** Environment: Docker Desktop (or the Docker service) is not running on the machine.

**Fix:** Start Docker Desktop (macOS) or the Docker service (e.g. `sudo systemctl start docker` on Linux), then re-run `./run.sh aws kube dev`.

**Note:** If you only need to run Phase 2 (infrastructure) and later without building images, you can use `--skip-build` after a first successful image build; Phase 1 will then skip the Docker build step but Docker may still be required for other checks depending on script logic.

---

## 5. Terraform: "Required plugins are not installed" / checksum mismatch

**Symptom:** Terragrunt/Terraform fails with required plugins not installed or provider checksum mismatch (e.g. AWS provider version in cache doesn’t match `.terraform.lock.hcl`).

**Root cause:**  
- Different layers or environments were initialized at different times, or the lock file was updated and the cache wasn’t refreshed.

**Fix:**  
- Run:  
  `./orchestration/terraform/init-all-layers.sh`  
  (or the equivalent that runs `terragrunt init -reconfigure` for the infrastructure, eks, and ecs layers for your environment).  
- Then re-run deploy.

---

## 2b. Teardown / Preempt: Terraform state lock

**Symptom:** During `./run.sh aws kube dev --preempt` (or teardown), Terraform/Terragrunt fails with **"Error acquiring the state lock"** (e.g. `PreconditionFailed: At least one of the pre-conditions you specified did not hold`). Lock Info shows an ID, Path (e.g. `fru-terraform-state-744139897900/dev/eks/terraform.tfstate`), Operation (e.g. `OperationTypeApply`), Who, Created.

**Root cause:** A previous Terraform/Terragrunt run (apply or destroy) was interrupted or crashed, leaving a lock in the S3 state backend. New runs cannot acquire the lock.

**Fix:**

1. **Force-unlock** using the Lock ID from the error message:
   - EKS: `cd module_infra_kubetypes/kube/aws/terra/environments/dev/eks && terragrunt force-unlock <LOCK_ID>`
   - ECS: `cd module_infra_kubetypes/nonkube/aws/terra/environments/dev/ecs && terragrunt force-unlock <LOCK_ID>`
   - Infrastructure: `cd module_infra_basic/aws/terra/environments/dev/infrastructure && terragrunt force-unlock <LOCK_ID>`
2. Re-run preempt or teardown.

**Note:** Teardown now fails fast on destroy errors (no longer reports success when destroy failed). Resolve the lock and retry.

---

## Quick reference

| Error / Phase              | Cause                              | Fix |
|---------------------------|------------------------------------|-----|
| Phase 2 subnet/VPC mismatch | Two VPCs; subnet group tied to one | `--preempt` or import or manual cleanup |
| Teardown: state lock      | Stale lock from interrupted run    | `terragrunt force-unlock <LOCK_ID>` in that layer dir, then retry |
| Data lake invalid bucket '' | S3_BUCKET_ID empty                | Fail-fast in place; ensure bucket layer applied |
| Frontend invalid bucket   | frontend-eks not applied; output warning used as name | Phase 5.1b + validate output |
| Docker daemon not running | Docker not started                | Start Docker |
| Terraform plugin/checksum | Stale cache vs lock file          | `init-all-layers.sh` (or `terragrunt init -reconfigure`) |
