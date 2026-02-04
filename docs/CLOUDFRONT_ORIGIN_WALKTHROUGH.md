# CloudFront origin and cloudfront_distribution_id — concise walkthrough

This doc answers: where the CloudFront distribution ID comes from, why EKS needs a post-deploy update, why ECS doesn’t, and how the 502 fix fits in.

---

## 0. Why does `terragrunt output` work in a dir that only has .hcl files?

The frontend-eks directory only contains Terragrunt config (`.hcl`). It **includes** `_component/frontend-base.hcl`, which sets `terraform { source = ".../modules//frontend" }`. So when you run `terragrunt output` in that directory, Terragrunt runs the **frontend module** there and uses the **state** for that layer. The output `cloudfront_distribution_id` is defined in the **module** (`modules/frontend/outputs.tf`); the .hcl files don’t reference it by name—they just point Terragrunt at the module. So: **you run the command in the layer directory; Terragrunt loads the module and reads outputs from that layer’s state.**

---

## 1. Where does the script “read the ID from the layer that matches the backend”?

**Physically:**

| Backend you’re deploying | Terragrunt layer that owns the CloudFront | Physical path (dev) |
|--------------------------|-------------------------------------------|----------------------|
| **EKS (kube)**           | frontend-eks                              | `module_infra_basic/aws/terra/environments/dev/frontend-eks` |
| **ECS (nonkube)**       | frontend-ecs                              | `module_infra_basic/aws/terra/environments/dev/frontend-ecs` |

The **output** `cloudfront_distribution_id` is defined once in the **module**:

- `module_infra_basic/aws/terra/modules/frontend/outputs.tf`

That module is **used by two Terragrunt layers** (frontend-eks and frontend-ecs). Each layer has its own state, so:

- `cd .../frontend-eks && terragrunt output -raw cloudfront_distribution_id` → ID of the CloudFront created by frontend-eks.
- `cd .../frontend-ecs && terragrunt output -raw cloudfront_distribution_id` → ID of the CloudFront created by frontend-ecs (if applied).

So “read from the layer that matches the backend” means: for an **EKS** deploy, run `terragrunt output` in **frontend-eks**; for **ECS**, in **frontend-ecs**.

---

## 2. Where is cloudfront_distribution_id used?

| Script / place | Purpose | EKS vs ECS |
|----------------|---------|------------|
| **deploy-frontend.sh** (323–324) | Get distribution ID to create **cache invalidation** (e.g. after uploading frontend assets). | **Both**: script chooses frontend-eks or frontend-ecs dir based on `CONTAINER_TYPE`. |
| **update-cloudfront-loadbalancer.sh** | Get distribution ID to **update CloudFront’s API origin** to the EKS NLB hostname (from Ingress). | **EKS only**: called from kube/aws/deploy.sh. |

There is **no separate “nonkube” update script** because:

- **ECS**: The API origin is set **at Terraform apply time**. frontend-ecs gets `alb_dns_name` from the ECS dependency, so when you apply frontend-ecs, CloudFront is already wired to the ECS ALB. No post-deploy script needed.
- **EKS**: The NLB hostname appears only **after** the Ingress (and NGINX) exist; it’s not an EKS Terraform output. So something must **after deploy** read the NLB from `kubectl get ingress` and update CloudFront. That’s what `update-cloudfront-loadbalancer.sh` does.

So: **cloudfront_distribution_id** is used in one module output and in those three script usages; “nonkube” doesn’t need an extra script because Terraform already sets the origin for ECS.

---

## 3. Why can’t we “just use” deploy-frontend (2.1) and skip the rest?

- **deploy-frontend.sh**:
  - Uploads frontend assets to S3.
  - Gets `cloudfront_distribution_id` (from the correct frontend-* layer) and **invalidates CloudFront caches** (e.g. `/*`).
  - It does **not** change CloudFront’s **origin** (the backend URL for `/query`, `/analytics`, etc.).

- **Origin** is set when the frontend Terraform is applied:
  - **ECS**: Terraform has `alb_dns_name` from the ECS stack → origin is correct at apply time.
  - **EKS**: Terraform only has a placeholder (e.g. `k8s-placeholder.elb...`) because the real NLB hostname doesn’t exist until after Kubernetes/Ingress are up. So we need a **post-deploy** step that:
  1. Reads the real NLB hostname from the Ingress.
  2. Updates the **same** CloudFront distribution (the one from frontend-eks) to use that hostname as the API origin.

So we need both:

- **2.1 deploy-frontend**: upload assets + invalidate caches (and it already uses the right frontend-* layer for the distribution ID).
- **update-cloudfront-loadbalancer**: after EKS deploy, set CloudFront’s API origin to the EKS NLB. That script must also get the **right** distribution ID — which is the one from **frontend-eks**, not from the EKS Terraform layer.

---

## 4. How it all fits together (and the 502 fix)

### Terraform (novice-friendly)

- **Module** = reusable template (here: S3 + CloudFront). Defined once under `module_infra_basic/aws/terra/modules/frontend/`; `outputs.tf` there defines `cloudfront_distribution_id`.
- **Terragrunt layer** = one “instance” of that module with its own state and inputs (e.g. dev/frontend-eks, dev/frontend-ecs). Each layer can create its **own** S3 bucket and CloudFront distribution.
- So there can be **two** distributions (two IDs, two URLs) if both frontend-eks and frontend-ecs are applied; or **one** if only one is applied.

### Flow that caused the 502

1. EKS deploy runs and applies Kubernetes manifests; Ingress gets an NLB hostname.
2. **Substep 5b** runs `update-cloudfront-loadbalancer.sh` to point CloudFront’s API origin at that NLB.
3. That script tried to get `cloudfront_distribution_id` only from the **EKS** Terraform layer (`.../kube/aws/terra/environments/dev/eks`). The EKS module does **not** define that output (it’s in the frontend module).
4. So the script got no ID, **skipped** the CloudFront update, and CloudFront kept pointing at a placeholder or old origin → **502 Bad Gateway** for `/analytics` (and other API paths).

### The fix

- **update-cloudfront-loadbalancer.sh** now reads `cloudfront_distribution_id` from the **frontend-eks** layer:  
  `module_infra_basic/aws/terra/environments/<env>/frontend-eks`  
  (and optionally `cloudfront_domain_name`).

So when you run EKS deploy:

- The script finds the distribution ID from **frontend-eks**.
- It then waits for the Ingress NLB hostname and updates **that** CloudFront distribution’s API origin to the NLB.
- CloudFront can reach the EKS API → 502 goes away (assuming the rest of the path is healthy).

### One-line summary

**CloudFront was never updated because the script looked for the distribution ID in the wrong Terraform layer (EKS). The fix is to also look in the frontend-eks layer, where that ID is actually defined.**
