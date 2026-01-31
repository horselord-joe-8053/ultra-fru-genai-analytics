# module_infra_kube

Kubernetes route: EKS (AWS) and local (minikube/kind). Manifests and Terraform for EKS live here.

## Layout

- **aws/** – EKS: deploy.sh, helpers/, verification/, environments/dev|prod/eks, modules/eks
- **shared/** – K8s manifests (templates/, generated/), ingress-nginx-values-local.yaml
- **local/** – Local kube: setup.sh, install-ingress.sh

## Usage

- **AWS EKS:** `./run.sh aws kube dev` → orchestration runs `module_infra_kube/aws/deploy.sh`; Terraform deploy/teardown use `module_infra_kube/aws/environments/<env>/eks`
- **Local kube:** `./run.sh local kube` → local/run.sh calls `module_infra_kube/local/setup.sh` and `install-ingress.sh`; manifests from `module_infra_kube/shared`
