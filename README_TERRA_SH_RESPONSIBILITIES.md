# Terraform vs Shell Script Responsibilities

This document describes which components are created/managed by **Terraform** (by layer) and which by **shell scripts** for the EKS and ECS deployment routes. Shared infrastructure (VPC, Aurora, IAM) is in the **infrastructure** layer; container-specific app resources are in **ecs** or **eks** layers.

---

## EKS Route

| Component | Terraform (layer) | Shell scripts |
|-----------|-------------------|---------------|
| VPC | infrastructure (shared) | — |
| Aurora | infrastructure (shared) | — |
| IAM (shared, Secrets, etc.) | infrastructure (shared) | — |
| EKS cluster | eks | — |
| EKS node group | eks | — |
| EKS Fargate profile | eks | — |
| EKS-related IAM roles (cluster, node, Fargate) | eks | — |
| EKS security groups (cluster, nodes) | eks | — |
| Frontend S3 + CloudFront (EKS) | eks (frontend module) | Empty S3 before destroy |
| Load balancer (API) | — | Created by k8s (NLB/ALB via Ingress); scripts apply manifests |
| Kubernetes resources (deployments, services, ingress) | — | deploy.sh / run.sh apply manifests |
| Pre-destroy (scale down, empty S3) | — | stop_eks_services, empty_s3_buckets |

---

## ECS Route

| Component | Terraform (layer) | Shell scripts |
|-----------|-------------------|---------------|
| VPC | infrastructure (shared) | — |
| Aurora | infrastructure (shared) | — |
| IAM (shared, task roles, etc.) | infrastructure (shared) | — |
| ECS cluster | ecs | — |
| ECS service + task definition | ecs | Stop services (scale to 0) before destroy |
| ECS security groups (tasks) | ecs | — |
| ALB | ecs (alb module) | — |
| Frontend S3 + CloudFront (ECS) | ecs (frontend module) | Empty S3 before destroy |
| Pre-destroy (scale down, empty S3) | — | stop_ecs_services, empty_s3_buckets |

---

## Overlap Analysis (Terraform vs Scripts)

Rows where **both** Terraform and Shell scripts have values represent overlap. The goal is to use Terraform in an IaC fashion where possible; below is an analysis of whether we can remove overlap and simplify—**no code changes recommended yet**, analysis only.

### 1. Empty S3 before destroy (EKS and ECS)

- **Current:** Terraform owns the frontend (and analytics) S3 buckets; scripts run `empty_s3_buckets` before calling `teardown.sh` so Terraform destroy does not fail on non-empty buckets.
- **Overlap:** Scripts do the “empty” step; Terraform does the “delete bucket” step.
- **Could Terraform take over?**
  - **Option A:** Set `force_destroy = true` on the S3 bucket resources. Terraform will empty the bucket as part of destroy. No script step needed.
  - **Option B:** Keep script-based empty. Terraform stays “dumb” about contents; scripts guarantee empty before destroy (clear separation, works well with versioned/large buckets).
- **Trade-offs:** Option A simplifies scripts but can make destroy slower and more fragile (timeouts, versioning). Option B keeps destroy predictable and is a common pattern. **Recommendation:** Optional to move to Terraform `force_destroy` for frontend/analytics buckets if we accept destroy-time emptying and timeouts; otherwise keep script-based empty for simplicity and control.

### 2. Stop ECS services before destroy (ECS only)

- **Current:** Terraform owns the ECS service; scripts run `stop_ecs_services` (scale desired count to 0) before `teardown.sh` so security groups and cluster can be deleted.
- **Overlap:** Scripts scale to 0; Terraform then destroys the service and cluster.
- **Could Terraform take over?**
  - **Option A:** Two-phase destroy: run `terragrunt apply` with `desired_count = 0` (or a variable “teardown mode”), then run `terragrunt destroy`. No separate script step; all in Terraform.
  - **Option B:** A `null_resource` with `local-exec` that runs `aws ecs update-service --desired-count 0` and waits, triggered before destroy (e.g. `depends_on` or destroy-time provisioner). Terraform owns the lifecycle.
  - **Option C:** Keep script-based scale-to-zero. Scripts remain the single place that “stops” before destroy.
- **Trade-offs:** Option A requires a second apply (or a “teardown” mode in the same config). Option B keeps one destroy flow but mixes TF with imperative AWS CLI. Option C is explicit and already works. **Recommendation:** Feasible to move into Terraform (A or B) for a pure IaC story; low urgency since the script step is simple and reliable.

### 3. Stop EKS workloads before destroy (EKS only)

- **Current:** Terraform owns the EKS cluster and node group; scripts run `stop_eks_services` (scale Kubernetes deployments to 0) before `teardown.sh` so the cluster can be deleted cleanly.
- **Overlap:** Scripts scale k8s workloads; Terraform destroys the cluster.
- **Could Terraform take over?**
  - **Option A:** Manage Kubernetes resources (deployments, etc.) with the Terraform `kubernetes` provider in the same or a dependent module. Scale replicas to 0 in Terraform, then destroy cluster. Full IaC for k8s.
  - **Option B:** Keep script-based scale-down. K8s resources are applied by deploy/run scripts; Terraform does not manage them today.
- **Trade-offs:** Option A adds Terraform-managed k8s resources and more complexity (provider, state, ordering). Option B keeps a clear split: Terraform = cluster/infra, scripts = app workloads. **Recommendation:** Keep script-based scale-down unless we commit to managing k8s manifests in Terraform; overlap is small and well-understood.

### 4. Pre-destroy (both routes)

- **Current:** “Pre-destroy” is the combination of stop_*_services and empty_s3_buckets, both done by scripts before `teardown.sh` runs Terraform destroy.
- **Overlap:** Scripts prepare state (no running tasks, empty buckets); Terraform performs destroy.
- **Summary:** Removing overlap for (1)–(3) would reduce or remove this row’s script side. If we move “empty S3” and “scale ECS to 0” into Terraform, pre-destroy for ECS could be minimal (e.g. only EKS scale-down remains in scripts).

---

## Summary

- **EKS:** Overlap is “empty S3” and “scale k8s to 0”. Empty S3 could move to Terraform (`force_destroy`); scale-down is better left to scripts unless we adopt Terraform-managed k8s.
- **ECS:** Overlap is “empty S3” and “stop ECS services”. Both could move into Terraform (force_destroy + apply-with-desired-count-0 or null_resource); would simplify scripts and align with IaC.
- **No code changes** are suggested in this document; the above is analysis to inform future simplification.
