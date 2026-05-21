# module_infra_basic

Shared AWS infrastructure (VPC, IAM, Secrets Manager, S3 state, Aurora, S3 data bucket). Used by both ECS and EKS deployment paths.

## Layout

- **aws/terra/environments/** – Terragrunt configs: `root.hcl`, `dev/`, `prod/`, `_component/infrastructure-base.hcl`
- **aws/terra/modules/** – Terraform modules: `vpc`, `iam`, `secrets-manager`, `s3-data`, `infrastructure`, `aurora`

## Usage

Deploy and teardown are invoked by orchestration:

- **Deploy:** `./run.sh aws nonkube dev` or `./run.sh aws kube dev` (infrastructure is deployed first by `run_scripts/.../aws/terraform/deploy.sh`)
- **Infrastructure only:** `./run_scripts/main_application_scripts/aws/run.sh infrastructure dev`
- **Teardown:** `./teardown.sh aws all dev` (destroys app layers then infrastructure)

Scripts resolve the infrastructure layer from `REPO_ROOT/module_infra_basic/aws/terra/environments/<env>/infrastructure`.
