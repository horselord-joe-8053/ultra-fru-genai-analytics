# Refactor Plan: Move Frontend into module_infra_basic

## Goal

Move the frontend Terraform component (S3 + CloudFront) from `module_infra_kubetypes` into `module_infra_basic` so that:

- **Single source of truth**: One frontend Terraform module in `module_infra_basic/aws/terra/modules/frontend`.
- **Clear ownership**: Frontend is shared “infra” (serving layer), not part of kube/nonkube app plumbing.
- **No duplication**: Remove the copy under `module_infra_kubetypes/kube/aws/terra/modules/frontend` and the embedded frontend in ECS/EKS root modules.

## Current State

| Location | Role |
|----------|------|
| `module_infra_kubetypes/nonkube/aws/terra/modules/ecs/main.tf` | Embeds `module "frontend" { source = "../frontend" }`; ECS outputs re-export `module.frontend.cloudfront_domain_name`, `s3_bucket_id`. |
| `module_infra_kubetypes/nonkube/aws/terra/modules/frontend/` | Frontend Terraform module (S3, CloudFront) used by ECS. |
| `module_infra_kubetypes/kube/aws/terra/modules/eks/main.tf` | Embeds `module "frontend" { source = "../frontend" }`; EKS outputs re-export frontend outputs. |
| `module_infra_kubetypes/kube/aws/terra/modules/frontend/` | Copy of same frontend module for EKS (so Terragrunt cache has `../frontend`). |

So today: two copies of the frontend module (nonkube + kube), and both ECS and EKS root modules embed it.

## Target State

- **One frontend module**: `module_infra_basic/aws/terra/modules/frontend/` (S3 + CloudFront; same interface: `project_name`, `environment`, `container_type`, `alb_dns_name`, etc.).
- **Two Terragrunt “frontend” layers** in module_infra_basic (one per app type):
  - `module_infra_basic/aws/terra/environments/<env>/frontend-ecs/` → uses the shared module with `container_type = "ecs"`, gets `alb_dns_name` from ECS layer.
  - `module_infra_basic/aws/terra/environments/<env>/frontend-eks/` → uses the shared module with `container_type = "eks"`, gets `alb_dns_name` from EKS layer (or var/manual).
- **ECS/EKS Terraform**: No frontend module; no frontend-related variables/outputs. ECS/EKS only do cluster + ALB (and EKS-specific resources). Outputs like `cloudfront_domain_name` and `s3_bucket_id` come from the new frontend-ecs / frontend-eks layers.

## Why Not “Embedded Module with Cross-Repo Path”?

We could keep frontend embedded in ECS/EKS and only move the module to `module_infra_basic/aws/terra/modules/frontend`, and in ECS/EKS use something like:

```hcl
module "frontend" {
  source = "../../../../../../module_infra_basic/aws/terra/modules/frontend"
  ...
}
```

- Terraform resolves `source` relative to the **calling module’s directory**. With Terragrunt, that directory is inside the **cache** (e.g. `.terragrunt-cache/.../ecs`). The cache layout is not guaranteed to sit under the repo root, so a relative path to `module_infra_basic` is fragile and can break depending on `download_dir` / cache location.
- Terraform does **not** allow variables in `module` `source`, so we cannot pass a “path to frontend” from Terragrunt.

So the robust approach is: **frontend as its own Terragrunt layer(s)** in module_infra_basic, not as a cross-path reference from ECS/EKS.

## Refactor Steps (High Level)

### Phase 1: Add frontend under module_infra_basic (no callers yet)

1. **Create** `module_infra_basic/aws/terra/modules/frontend/`.
   - Copy contents from `module_infra_kubetypes/nonkube/aws/terra/modules/frontend/` (or kube copy; they should be identical).
   - Ensure it remains a pure Terraform module (variables, resources, outputs; no Terragrunt).
2. **Add** base Terragrunt component for frontend (optional but useful):
   - e.g. `module_infra_basic/aws/terra/environments/_component/frontend-base.hcl` that sets `terraform { source = "${get_terragrunt_dir()}/../../../modules//frontend" }` and common `inputs` (or leave all in env-specific terragrunt.hcl).

### Phase 2: Add frontend Terragrunt layers in module_infra_basic

3. **Create** `module_infra_basic/aws/terra/environments/dev/frontend-ecs/terragrunt.hcl`.
   - Include root + (if present) frontend-base.
   - `dependency "app" { config_path = "<path to nonkube/.../dev/ecs>" }` to read ECS outputs (e.g. `alb_dns_name`).
   - `inputs`: `project_name`, `environment`, `container_type = "ecs"`, `alb_dns_name = dependency.app.outputs.alb_dns_name`, plus frontend vars from env.hcl (or locals).
4. **Create** `module_infra_basic/aws/terra/environments/dev/frontend-eks/terragrunt.hcl`.
   - Same idea; `dependency "app" { config_path = "<path to kube/.../dev/eks>" }`; `container_type = "eks"`; `alb_dns_name` from dependency or variable (EKS often uses Ingress ALB; may stay as var/manual).
5. **Repeat** for `prod`: `frontend-ecs`, `frontend-eks` (and env.hcl / root if prod-specific).
6. **Dependencies**: In each frontend-ecs / frontend-eks, set `dependencies { paths = [ "<path to ecs or eks>" ] }` so Terragrunt applies order is correct.

### Phase 3: Remove frontend from ECS and EKS Terraform

7. **ECS** (`module_infra_kubetypes/nonkube/aws/terra/modules/ecs/`):
   - Remove `module "frontend" { ... }` from `main.tf`.
   - Remove frontend-related variables from `variables.tf` (e.g. `enable_frontend_versioning`, `cloudfront_price_class`, `frontend_certificate_arn`, `frontend_api_origin_id`; keep only what ECS cluster/ALB need).
   - Remove or replace frontend outputs in `outputs.tf`: drop `cloudfront_domain_name`, `s3_bucket_id`, etc., that came from `module.frontend` (or re-export from a data source / var if something still needs them during transition; long term they come from frontend-ecs layer).
8. **EKS** (`module_infra_kubetypes/kube/aws/terra/modules/eks/`):
   - Same: remove `module "frontend"`, frontend-related variables, and frontend-derived outputs.
9. **Delete** `module_infra_kubetypes/kube/aws/terra/modules/frontend/` (no longer needed).
10. **Delete** `module_infra_kubetypes/nonkube/aws/terra/modules/frontend/` (optional; can keep for one release as reference, then remove).

### Phase 4: Orchestration and scripts

11. **Deploy order** (e.g. `orchestration/terraform/deploy.sh` or equivalent):
    - For **ECS**: `infrastructure` → `ecs` → **`frontend-ecs`** (new step; run Terragrunt in `module_infra_basic/aws/terra/environments/<env>/frontend-ecs`).
    - For **EKS**: `infrastructure` → `eks` → **`frontend-eks`** (new step; run Terragrunt in `module_infra_basic/aws/terra/environments/<env>/frontend-eks`).
12. **Teardown order**: Reverse: destroy **frontend-ecs** or **frontend-eks** first, then ecs or eks, then infrastructure (to satisfy dependency order).
13. **deploy-frontend.sh** (S3 sync / frontend deploy):
    - Today it reads `s3_bucket_id` (and possibly CloudFront id) from the **app** layer (ecs or eks) Terragrunt output.
    - After refactor: read the same outputs from the **frontend-ecs** or **frontend-eks** layer (e.g. `cd module_infra_basic/aws/terra/environments/<env>/frontend-ecs && terragrunt output -raw s3_bucket_id`). Update `APP_DIR` or equivalent to point at the chosen frontend layer.
14. **Any other consumers** of ECS/EKS Terragrunt outputs that expect `cloudfront_domain_name`, `s3_bucket_id`, or `cloudfront_distribution_id`: point them at the corresponding frontend-ecs / frontend-eks Terragrunt outputs (and ensure those layers are applied first).

### Phase 5: Docs and cleanup

15. Update **module_infra_basic/README.md** (and any runbooks): document `aws/terra/modules/frontend` and `aws/terra/environments/<env>/frontend-ecs|frontend-eks`.
16. Update **module_infra_kubetypes/kube/README.md**: remove “frontend copy under kube” and point to module_infra_basic for frontend.
17. **.gitignore / cache**: If anything ignored or cached under the old frontend paths, align with new layout.

## Dependency Graph (After Refactor)

```
infrastructure (module_infra_basic)
       │
       ├── ecs (module_infra_kubetypes/nonkube)  ──►  frontend-ecs (module_infra_basic)
       │
       └── eks (module_infra_kubetypes/kube)    ──►  frontend-eks (module_infra_basic)
```

Apply order: `infrastructure` → `ecs` or `eks` → `frontend-ecs` or `frontend-eks`.  
Destroy order: `frontend-*` → `ecs` or `eks` → `infrastructure`.

## File / Dir Summary

| Action | Path |
|--------|------|
| **Create** | `module_infra_basic/aws/terra/modules/frontend/` (from nonkube or kube copy) |
| **Create** | `module_infra_basic/aws/terra/environments/dev/frontend-ecs/terragrunt.hcl` |
| **Create** | `module_infra_basic/aws/terra/environments/dev/frontend-eks/terragrunt.hcl` |
| **Create** | `module_infra_basic/aws/terra/environments/prod/frontend-ecs/terragrunt.hcl` |
| **Create** | `module_infra_basic/aws/terra/environments/prod/frontend-eks/terragrunt.hcl` |
| **Edit** | `module_infra_kubetypes/nonkube/aws/terra/modules/ecs/main.tf` (remove frontend module) |
| **Edit** | `module_infra_kubetypes/nonkube/aws/terra/modules/ecs/variables.tf`, `outputs.tf` |
| **Edit** | `module_infra_kubetypes/kube/aws/terra/modules/eks/main.tf` (remove frontend module) |
| **Edit** | `module_infra_kubetypes/kube/aws/terra/modules/eks/variables.tf`, `outputs.tf` |
| **Delete** | `module_infra_kubetypes/kube/aws/terra/modules/frontend/` |
| **Delete** | `module_infra_kubetypes/nonkube/aws/terra/modules/frontend/` |
| **Edit** | `orchestration/terraform/deploy.sh` (add frontend-ecs / frontend-eks step) |
| **Edit** | `orchestration/terraform/teardown.sh` (destroy frontend layer before app layer) |
| **Edit** | `module_infra_basic/aws/deploy-frontend.sh` (read outputs from frontend-ecs | frontend-eks) |
| **Edit** | Any script that runs `terragrunt output` on ecs/eks for cloudfront or s3_bucket_id |

## Risks / Notes

- **State migration**: Existing ECS/EKS state has frontend resources under the ECS/EKS module. Moving frontend to a new layer implies either: (1) **resource move**: `terraform state mv` from ecs/eks state into the new frontend-ecs/frontend-eks state (complex, same resources); or (2) **recreate**: destroy frontend from ECS/EKS (or leave in place), then create in frontend-* (new resources; brief outage or duplicate until cutover). Prefer (2) for simplicity unless you have strict no-recreate requirements.
- **EKS alb_dns_name**: EKS frontend often uses a placeholder or manual ALB DNS (from Ingress). frontend-eks can take `alb_dns_name` as input from env.hcl or a variable and keep the same behavior.
- **root.hcl / env.hcl**: frontend-ecs and frontend-eks under module_infra_basic need to use the same root (and ideally env) as the rest of module_infra_basic (e.g. `find_in_parent_folders("root.hcl")` from `module_infra_basic/aws/terra/environments/`); ensure root.hcl and env.hcl exist at the right level so frontend layers see the same backend and env config.

---

**Summary**: Put the frontend **module** in `module_infra_basic/aws/terra/modules/frontend`, and add two Terragrunt **layers** `frontend-ecs` and `frontend-eks` under `module_infra_basic/aws/terra/environments/<env>/`, with dependencies on the ECS/EKS layers for `alb_dns_name`. Remove the frontend module from ECS and EKS Terraform, delete the kube (and optionally nonkube) copy of the frontend module, and update orchestration and deploy-frontend.sh to use the new frontend layers.
