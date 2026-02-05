# Refactor: ECR Tag Strategy and Teardown-by-Container-Type

## 1. Goals

- **Teardown scope:** When tearing down with `--container-type eks` only EKS-related images are deleted; with `ecs` only ECS-related; with `all` both.
- **Tag clarity:** Use multiple tags so we can identify which images belong to which deployment target, without breaking existing use of `latest` and the version tag.
- **Preserve existing behavior:** Current tag creation (version tag from `generate_image_tag`, plus `latest`) stays the source of truth; we add container-type tags alongside.

---

## 2. Current Tag Creation and Usage

### 2.1 Where tags are created

| Location | What it does |
|----------|----------------|
| **`orchestration/common/git_helpers.sh`** | `generate_image_tag()` produces a single **version tag**: `fru_<env>_<date>_<sha>_<slug>` or `fru_<env>_<date>_<sha>_dirty_<timestamp>`. No container-type. |
| **`module_infra_basic/aws/build-push-ecr.sh`** | After build: tags and pushes **two** tags per image: (1) `$ECR_REPO_URI:$IMAGE_TAG` (version), (2) `$ECR_REPO_URI:latest`. So every push updates `latest` to the just-pushed image. |

### 2.2 Where tags are consumed

| Consumer | Tag used | Notes |
|----------|----------|--------|
| **run.sh** (deploy) | `CONTAINER_IMAGE` = `ECR_URI:IMAGE_TAG` (version from Phase 1) or `ECR_URI:latest` when `--skip-build`. | Phase 1 sets CONTAINER_IMAGE; Terraform/k8s get it via env. |
| **run.sh --skip-build** | Always `ECR_URI:latest`. | Fails if `latest` does not exist in ECR. |
| **EKS/ECS Terraform** | `get_env("CONTAINER_IMAGE", "")` → full URI:tag. | Same image ref for both if same deploy. |
| **build-push-ecr.sh** | Existence check by `imageTag=$IMAGE_TAG`; push with `IMAGE_TAG` and `latest`. | No container-type today. |

### 2.3 Important invariants to preserve

- **Version tag** remains the primary unique identifier (git-based, traceable). Do not change `generate_image_tag()` format.
- **`latest`** continues to be assigned to every push so that:
  - `--skip-build` keeps working (it expects `latest` to exist).
  - Any script that assumes “latest = most recent push” still holds.
- **Single source of truth for tag:** `IMAGE_TAG` is still produced once (git_helpers + ensure_image_tag); build-push only adds *additional* tags to the same digest.

---

## 3. Tag Strategy: Simple 4-Tag Set

### 3.1 Tag set per push (max 4 tags)

Keep the existing two tags and add exactly two **literal** container-type tags: `eks` and `ecs`. No prefixes or suffixes.

| Tag | When applied | Purpose |
|-----|--------------|---------|
| **`$IMAGE_TAG`** | Always | Version tag (unchanged). Primary identifier for this build. |
| **`latest`** | Always | Most recent push; required for `--skip-build` and backward compatibility. |
| **`eks`** | When `CONTAINER_TYPE` is `eks` or `all` | Marks this image as used for EKS; teardown eks deletes images that have this tag. |
| **`ecs`** | When `CONTAINER_TYPE` is `ecs` or `all` | Marks this image as used for ECS; teardown ecs deletes images that have this tag. |

**Example (deploy to both, `--container-type all`):**

```
Tags (4):
  fru_dev_20260205_abc1234_deploy-all
  latest
  eks
  ecs
```

- Deploy to **eks only** → tags: version, `latest`, `eks` (3 tags).
- Deploy to **ecs only** → tags: version, `latest`, `ecs` (3 tags).
- Deploy to **all** → tags: version, `latest`, `eks`, `ecs` (4 tags).

So: **one build, one digest;** we only add the literal tags `eks` and/or `ecs`. No `eks-latest`, `ecs-<version>`, etc.

### 3.2 When we have CONTAINER_TYPE

- **run.sh** sets `CONTAINER_TYPE` from `--container-type` (e.g. kube → eks, ecs, or all) before Phase 1. build-push-ecr.sh reads it and pushes the extra tag(s) `eks` and/or `ecs` after the main push.
- If `CONTAINER_TYPE` is unset (e.g. standalone run of build-push-ecr.sh), default to “all” and push both `eks` and `ecs` so the image is visible to both teardown paths.

---

## 4. Teardown ECR Logic (By Container-Type)

- **eks:** Delete only “EKS-related” images: those that have the tag **`eks`**. List all images; for each, if its tags include `eks`, include it for deletion. Delete in manifest-list-safe order (newest first by push date). Images that have only `ecs` (and/or version/latest) are not deleted.

- **ecs:** Same idea: delete only images that have the tag **`ecs`**. Do not delete images that only have `eks` (and/or version/latest).

- **all:** Delete every image in the repo (no tag filter). Same as current “nuclear” ECR cleanup.

- **Edge case:** An image has both `eks` and `ecs` (pushed with `CONTAINER_TYPE=all`). Teardown eks deletes that image (it has tag `eks`); the digest is gone so ECS “loses” it until the next push. That is acceptable; same image can be re-pushed for ecs later if needed.

---

## 5. Implementation Plan (Ordered)

### Phase A: Tag creation (build-push)

1. **`module_infra_basic/aws/build-push-ecr.sh`**
   - After successfully pushing `$ECR_REPO_URI:$IMAGE_TAG` and `$ECR_REPO_URI:latest` (keep this exactly as today):
   - Read `CONTAINER_TYPE` (eks | ecs | all). If unset, treat as `all`.
   - If CONTAINER_TYPE is `eks` or `all`: tag same local image as `eks`, push it.
   - If CONTAINER_TYPE is `ecs` or `all`: tag same local image as `ecs`, push it.
   - Log which extra tags were pushed. No change to how `IMAGE_TAG` or `latest` are computed or pushed first.

2. **`orchestration/aws/run.sh`**
   - Ensure `CONTAINER_TYPE` is exported before Phase 1 (so build-push sees it). Confirm current flow already does this; if not, export when parsing `--container-type`.

### Phase B: Teardown ECR step

3. **New script: `orchestration/aws/cli/ecr-delete-by-container-type.sh`** (or equivalent)
   - Args: `--container-type eks|ecs|all` (required), `--repo fru-api`, `--profile`, `--region`, `--dry-run`.
   - **all:** List all images (describe-images, sort by imagePushedAt desc), delete by digest (newest first), then `delete-repository --force` if desired.
   - **eks:** List all images; for each, get imageTags; keep only images that have the tag **`eks`**. Delete those by digest (newest first). Do not delete the repo (other images may remain).
   - **ecs:** Same: keep only images that have the tag **`ecs`**.
   - Handle manifest-list order: delete manifest-list digests before children (e.g. sort by push date desc); optionally a second pass for any leftover failures.
   - Call this from teardown-resources-all.sh when container-type is eks, ecs, or all (see below).

4. **`orchestration/aws/teardown-resources-all.sh`**
   - After Terraform destroy for the relevant layer(s), add an “ECR cleanup” step:
     - For `CONTAINER_TYPE=eks` or `ecs`: run ecr-delete-by-container-type.sh (delete only images that have tag `eks` or `ecs` respectively).
     - For `CONTAINER_TYPE=all`: run with `all` (delete all images, then optionally delete repo).
   - Use same `AWS_PROFILE`, `AWS_REGION`, `ECR_REPO_NAME` as rest of teardown; respect `DRY_RUN`.

### Phase C: Backward compatibility and docs

5. **`--skip-build`**  
   - Continues to use `latest` only. No change.

6. **Docs**
   - Update `docs/learned/REFACTOR_PLAN_ECR_TEARDOWN.md` to reference this plan and the new script.
   - In README or run.sh comments: state that we use multiple tags (version, latest, eks-*, ecs-*) and that teardown deletes by container-type using those tags.

---

## 6. Summary Table

| Item | Before | After |
|------|--------|--------|
| Version tag | `fru_<env>_<date>_<sha>_<slug>` | Unchanged. |
| `latest` | Set on every push | Unchanged; still “most recent push”. |
| New tags | — | Literal `eks` and/or `ecs` when CONTAINER_TYPE is set (max 4 tags total). |
| Teardown eks | (no ECR step) | Delete only images that have tag `eks`. |
| Teardown ecs | (no ECR step) | Delete only images that have tag `ecs`. |
| Teardown all | (no ECR step) | Delete all images (and optionally repo). |
| --skip-build | Uses `latest` | Unchanged; uses `latest`. |

---

## 7. Files to Touch (Checklist)

| File | Change |
|------|--------|
| `module_infra_basic/aws/build-push-ecr.sh` | After pushing IMAGE_TAG and latest, add container-type tags (eks-*, ecs-*) based on CONTAINER_TYPE. |
| `orchestration/aws/run.sh` | Confirm CONTAINER_TYPE exported before Phase 1. |
| `orchestration/aws/cli/ecr-delete-by-container-type.sh` (new) | Implement delete by container-type (tag filter + manifest-list-safe order). |
| `orchestration/aws/teardown-resources-all.sh` | Add ECR cleanup step calling new script with current CONTAINER_TYPE. |
| `docs/learned/REFACTOR_PLAN_ECR_TEARDOWN.md` | Point to this plan; note tag strategy and teardown behavior. |

No changes to `generate_image_tag()` or to the format of `IMAGE_TAG`; only additive tags and teardown behavior.
