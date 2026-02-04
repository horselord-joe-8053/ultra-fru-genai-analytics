# root_infrastructure

**Root/composition module** for the **infrastructure** Terragrunt layer. One `terragrunt apply` or `terragrunt destroy` for this layer runs Terraform with this directory as the root.

## Why "root_"?

Unlike leaf modules (e.g. `vpc/`, `iam/`, `aurora/`), which map to a single AWS concern, this module is the **entry point** for the whole infrastructure layer. It composes multiple resources and calls sibling modules (`../vpc`, `../aurora`, `../iam`, `../s3-data`) and reads `infrastructure-longterm` state. The `root_` prefix makes it clear this is the layer root, not a single-service module.

## What it creates

- VPC (via `module.vpc`)
- Aurora cluster (via `module.aurora`)
- IAM roles for ECS/App (via `module.iam`; uses secret ARNs from longterm state)
- S3 data bucket (via `module.s3_data`)
- Placeholder security group for Aurora

Secrets Manager is in the **infrastructure-longterm** layer; this layer only references them via `data.terraform_remote_state.longterm`. Main teardown destroys this layer only; longterm is never destroyed (Option B).

## Usage

Used by Terragrunt: `module_infra_basic/aws/terra/environments/<env>/infrastructure/` includes `_component/infrastructure-base.hcl`, which sets `source = ".../modules//root_infrastructure"`. You do not call this module from another Terraform module; Terragrunt runs it as the root for the layer.
