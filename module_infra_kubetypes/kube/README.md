# module_infra_kubetypes/kube

Kubernetes route: EKS (AWS) and local (minikube/kind). Manifests and Terraform for EKS live here.

## Layout

- **aws/** – EKS: deploy.sh, helpers/, verification/, **terra/** (Terraform: environments/dev|prod/eks, modules/eks, modules/frontend)
- **shared/** – K8s manifests (templates/, generated/), ingress-nginx-values-local.yaml
- **local/** – Local kube: setup.sh, install-ingress.sh

## Why `terra/modules/frontend` exists (copy of nonkube frontend)

Before the refactor that split infra into `module_infra_kubetypes/kube` and `module_infra_nonkube`, EKS and ECS Terraform likely lived under a single tree (e.g. one `modules/` with both `eks` and `frontend`). After the split:

- **nonkube** has `modules/ecs` and `modules/frontend` as siblings, so ECS `main.tf` can use `source = "../frontend"` and Terragrunt’s copy of `modules/` includes both.
- **kube** had only `modules/eks`; there was no `frontend` sibling. Terragrunt runs Terraform from a cache copy of `modules/` (with `//eks` so only the `eks` subdir is the working dir). The EKS module references `../frontend`, so that path must exist inside the copied tree. Terraform does not allow variables for `module` `source`, so we cannot pass a path to the nonkube frontend from Terragrunt. The fix was to add a **copy** of the shared frontend module under `kube/aws/terra/modules/frontend` so that when Terragrunt copies `terra/modules/`, both `eks` and `frontend` are present and `../frontend` resolves. Keep this copy in sync with `nonkube/aws/terra/modules/frontend` when changing frontend resources.

## Usage

- **AWS EKS:** `./run.sh aws kube dev` → orchestration runs `module_infra_kubetypes/kube/aws/deploy.sh`; Terraform deploy/teardown use `module_infra_kubetypes/kube/aws/terra/environments/<env>/eks`
- **Local kube:** `./run.sh local kube` → local/run.sh calls `module_infra_kubetypes/kube/local/setup.sh` and `install-ingress.sh`; manifests from `module_infra_kubetypes/kube/common`
