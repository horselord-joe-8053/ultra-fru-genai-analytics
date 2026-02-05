# Refactor: ECR Image Deletion in Teardown

## 1. Why teardown didn’t delete ECR images

- **`./teardown.sh aws all dev`** runs **`orchestration/aws/teardown-resources-all.sh`** only. That script:
  - Runs pre-destroy (EKS, ECS, shared)
  - Runs **Terraform destroy** for: eks layer, ecs layer, then shared/infra_basic
  - Runs optional orphan cleanup and local Docker cleanup
- **ECR is never touched:** The ECR repository `fru-api` is **not** managed by Terraform in this repo (no `aws_ecr_repository` in any `.tf`). The only code that deletes ECR images/repo is **`orchestration/aws/cli/resource-removal/older/delete-recreatable-resources.sh`**, and **teardown-resources-all.sh does not call it**. So a normal teardown leaves the ECR repo and all its images in place.

## 2. Your intent (and why it’s correct)

- For **teardown** we should **delete all images** in `fru-api`, including `latest`; we do **not** need to reserve any.
- We don’t intend to keep multiple builds on this cluster; after teardown there is no cluster, so keeping images is unnecessary. So: **teardown = delete all ECR images + delete repo (or leave repo empty).**

## 3. Refactor plan

### 3.1 Goal

- **Teardown** (at least for `--container-type all`) should:
  1. Delete **all** images in the `fru-api` ECR repo (including `latest`), in an order that respects manifest lists (see below).
  2. Then delete the ECR repository (e.g. `aws ecr delete-repository --force`), or leave the repo empty if we prefer to recreate it on next deploy.

### 3.2 Manifest-list behavior

- If any image is a **manifest list** (multi-arch), its **child** images cannot be deleted until the **manifest list digest** is deleted first.
- So deletion order should: **delete by “newest first”** (e.g. `describe-images` + sort by `imagePushedAt` desc) so manifest lists (usually the “tag” / newest) are deleted first, then retry or run a second pass for any remaining images. This matches what we did manually (delete manifest list digest first, then prune).

### 3.3 Proposed implementation

| Step | Action |
|------|--------|
| **A** | **Add an ECR cleanup step** in `orchestration/aws/teardown-resources-all.sh` when `CONTAINER_TYPE=all` (and optionally when `ecs` or `eks` if we want ECR cleaned on layer-only teardown). Run this **before** Terraform destroy (so no running EKS/ECS is still using the repo), or **after** app-layer destroy. Prefer **after** EKS/ECS destroy so nothing is pulling the image during deletion. |
| **B** | **Reuse one shared implementation** for “delete all images + delete repo”: |
| | **Option B1 – New script:** Add `orchestration/aws/cli/ecr-delete-all-and-repo.sh`: (1) List images with `describe-images` sorted by `imagePushedAt` desc (newest first). (2) Delete in batches by **digest** (newest first) so manifest lists go first; on `ImageReferencedByManifestList` failures, optionally run a second pass. (3) Call `aws ecr delete-repository --repository-name fru-api --force`. (4) Honor `AWS_PROFILE`, `AWS_REGION`, `ECR_REPO_NAME`, `--dry-run`. Teardown calls this script. |
| | **Option B2 – Extend prune script:** Add to `ecr-prune-old-images.sh` a mode `--delete-all-and-repo`: same logic as above (newest-first by digest, then delete repo). Teardown calls `ecr-prune-old-images.sh --delete-all-and-repo`. |
| **C** | **Align delete-recreatable-resources.sh** with the same behavior: when it runs “Substep 2: ECR”, use **describe-images + sort by imagePushedAt desc** and delete by **imageDigest** in that order (instead of `list-images` arbitrary order), so manifest-list parents are removed first. Optionally parse `batch-delete-image` response for `ImageReferencedByManifestList` and run a second pass. That way both “nuclear” CLI and teardown behave the same and delete all images. |

### 3.4 Recommendation

- **Implement Option B1** (new `ecr-delete-all-and-repo.sh`) for clarity: one script dedicated to “teardown ECR” (all images + repo), called from teardown only when we want ECR cleaned.
- **Implement Step C** so `delete-recreatable-resources.sh` uses the same newest-first, digest-based deletion (and optionally call the new script from there to avoid duplication, or share a small “delete all images by digest newest-first” helper).
- **Teardown behavior:** For `container-type all`, after EKS + ECS Terraform destroy, run the ECR cleanup (all images + delete repo). No “keep N” or “reserve latest”; delete everything.

### 3.5 Files to touch

| File | Change |
|------|--------|
| `orchestration/aws/teardown-resources-all.sh` | Add step: when `CONTAINER_TYPE=all`, after app-layer destroy and before or after shared destroy, run ECR cleanup (call new script or `ecr-prune-old-images.sh --delete-all-and-repo`). Use same `AWS_PROFILE`, `AWS_REGION`, `ECR_REPO_NAME` as rest of teardown; respect `DRY_RUN`. |
| `orchestration/aws/cli/ecr-delete-all-and-repo.sh` (new) | Implement: list images by push date desc, delete by digest (batches of 100), handle manifest-list order; then `delete-repository --force`. |
| `orchestration/aws/cli/ecr-prune-old-images.sh` | Optional: add `--delete-all-and-repo` that delegates to the new script or inlines the same logic. |
| `orchestration/aws/cli/resource-removal/older/delete-recreatable-resources.sh` | Change `delete_ecr_resources()` to use `describe-images` + sort by `imagePushedAt` desc, delete by `imageDigest` in that order; optionally second pass on failures. Or call the new script instead of inlining. |

### 3.6 Summary

- **Root cause:** Teardown never runs any ECR deletion; ECR isn’t in Terraform and `delete-recreatable-resources.sh` isn’t invoked by teardown.
- **Desired behavior:** On full teardown, delete all ECR images (including `latest`) and the repo; no need to reserve any images.
- **Refactor:** Add an explicit ECR cleanup step to teardown (new script or extended prune), use newest-first digest deletion for manifest-list safety, and align delete-recreatable-resources with the same logic.
