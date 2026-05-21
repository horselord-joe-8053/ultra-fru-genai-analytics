# Evaluation: Placement of kube/local, nonkube/local, and Related Content

## Current state (after refactor)

| Location | Contents | Used by |
|----------|----------|---------|
| **module_infra_kubetypes/kube/local/** | `setup.sh`, `install-ingress.sh`, `README.md` | Local K8s dev: minikube/kind/docker-desktop setup, NGINX Ingress install |
| **module_infra_kubetypes/kube/common/** | `ingress-nginx-values-local.yaml`, `templates/` (configmap, deployment, ingress, etc.) | kube/local scripts, EKS deploy (kubectl apply from kube/common) |
| **module_infra_kubetypes/nonkube/local/** | `Dockerfile.api`, `docker-entrypoint.sh`, `docker-compose.yml` | **ECR build** (module_infra_basic/aws/build-push-ecr.sh), **local dev** (docker-compose, orchestration/local/deploy.sh) |
| **module_infra_kubetypes/nonkube/common/** | *(does not exist)* | — |
| **module_infra_basic/** | AWS Terraform, build-push-ecr.sh, deploy-frontend.sh, teardown | ECR build **references** module_app_core/pack_with_docker/Dockerfile.api |
| **module_app_core/** | backend, frontend, spark_jobs, data | **Copied into image** by Dockerfile.api (no Dockerfile here) |

## Before the refactor

- **infra/docker/** held: `Dockerfile.api`, `docker-entrypoint.sh`, `docker-compose.yml`.
- REFACTOR_PLAN_FINAL.md moved `infra/docker/` → `module_infra_kubetypes/nonkube/local/`.
- So the “single API container” definition (Dockerfile + entrypoint) was historically under **infra**, and is now under **nonkube/local**.

## Tension with current placement

- **nonkube/local** name suggests “local-only”, but:
  - **Dockerfile.api** and **docker-entrypoint.sh** are shared: used for **ECS/EKS image** (build-push-ecr.sh) and for **local** (docker-compose, orchestration/local).
- **kube/local** is consistent: scripts there are local-only (setup minikube, install ingress).
- **kube/common** is consistent: shared manifests and values (local + cloud).

So the only mismatch is: **API container definition** (Dockerfile + entrypoint) is under “local” even though it’s shared between local and cloud.

---

## Options for where things should live

### Option A: Keep as-is (nonkube/local for everything)

- **Dockerfile.api**, **docker-entrypoint.sh**, **docker-compose.yml** stay in `module_infra_kubetypes/nonkube/local/`.
- **Pros:** No moves; one place for “non-kube runtime” (ECS + local Docker).
- **Cons:** “local” is misleading for Dockerfile/entrypoint (used by ECS too). Path is long.

### Option B: nonkube/common for shared image, nonkube/local for local-only

- Create **module_infra_kubetypes/nonkube/common/** and put there:
  - **Dockerfile.api**
  - **docker-entrypoint.sh**
- Keep in **module_infra_kubetypes/nonkube/local/**:
  - **docker-compose.yml** (and optionally a short README).
- **Pros:** “common” = shared (local + ECS); “local” = local-only (compose). Aligns with kube/common vs kube/local.
- **Cons:** One more directory; all references to Dockerfile/entrypoint must be updated.

### Option C: module_infra_basic/docker/ (successor to infra/docker)

- Create **module_infra_basic/docker/** and put there:
  - **Dockerfile.api**
  - **docker-entrypoint.sh**
- **docker-compose.yml** can stay under nonkube/local (local dev) and reference `../../module_infra_basic/docker/Dockerfile.api`.
- **Pros:** Matches “before refactor” (infra/docker); build-push-ecr.sh lives in module_infra_basic/aws, so Dockerfile and ECR build are in the same “infra” area.
- **Cons:** module_infra_basic is AWS-heavy; the same image is used for local Docker (slight cross-module use).

### Option D: module_app_core/pack_with_docker/

- Put **Dockerfile.api** and **docker-entrypoint.sh** under **module_app_core/pack_with_docker/** (or `module_app_core/container/`).
- **Pros:** App owns “how I am containerized”; single place for app + its image definition.
- **Cons:** module_app_core is currently code-only; adding Docker blurs app vs infra; build-push-ecr.sh would reference module_app_core (orchestration crosses modules).

---

## Recommendation

**Recommendation: Option B — create nonkube/common for shared image, keep local for local-only.**

1. **Consistency with kube:** We already have **kube/common** (shared manifests/values) and **kube/local** (local-only scripts). Having **nonkube/common** (shared Dockerfile + entrypoint) and **nonkube/local** (docker-compose, local-only) mirrors that.
2. **Naming:** “common” = used by both local and ECS; “local” = local dev only (compose file).
3. **Minimal blast radius:** Only nonkube and build/orchestration references change; module_infra_basic and module_app_core stay unchanged in concept.
4. **kube/local and kube/common:** No change; they are already in the right place (local scripts vs shared manifests/values).

**Concrete steps for Option B**

1. Create **module_infra_kubetypes/nonkube/common/**.
2. Move **Dockerfile.api** and **docker-entrypoint.sh** from nonkube/local → nonkube/common.
3. Update **Dockerfile.api** COPY line:  
   `COPY module_infra_kubetypes/nonkube/common/docker-entrypoint.sh /app/docker-entrypoint.sh`
4. Update references to Dockerfile path:
   - **module_infra_basic/aws/build-push-ecr.sh**: use `module_infra_kubetypes/nonkube/common/Dockerfile.api`
   - **orchestration/local/deploy.sh**: same path
   - **docker-compose.yml** (nonkube/local): `dockerfile: ./module_infra_kubetypes/nonkube/common/Dockerfile.api`
5. Update comment in Dockerfile.api (line 48): “lives under …” → `module_infra_kubetypes/nonkube/common/`.
6. Update **module_infra_kubetypes/nonkube/README.md** to describe common/ (shared image) and local/ (compose, local dev).
7. Optionally add **nonkube/local/README.md** stating that common/ holds the shared image definition; local/ holds docker-compose for local runs.

**If you prefer Option C (module_infra_basic/docker/)**  
Same idea: one directory for Dockerfile + entrypoint, update build-push-ecr.sh, docker-compose, and orchestration/local/deploy.sh to that path; docker-compose can stay in nonkube/local.

---

## Summary table

| Content | Current | Option A (keep) | Option B | Option C | **Implemented (Option D)** |
|--------|---------|-----------------|----------|----------|----------------------------|
| Dockerfile.api | — | nonkube/local | nonkube/common | module_infra_basic/docker | **module_app_core/pack_with_docker** |
| docker-entrypoint.sh | — | nonkube/local | nonkube/common | module_infra_basic/docker | **module_app_core/pack_with_docker** |
| docker-compose.yml | nonkube/local | nonkube/local | nonkube/local | nonkube/local | nonkube/local (unchanged) |
| kube/local (setup, install-ingress) | kube/local | no change | no change | no change | no change |
| kube/common (templates, values) | kube/common | no change | no change | no change | no change |

**Option D (module_app_core/pack_with_docker/) was implemented:** The image definition is considered part of app core—deployment-agnostic and shared by local, ECS, and EKS. See `module_app_core/pack_with_docker/README.md`.
