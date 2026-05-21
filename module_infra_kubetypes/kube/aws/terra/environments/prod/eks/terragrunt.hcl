# EKS layer for prod environment
# This file includes root and component base (non-nested includes)

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "component" {
  path = "${get_terragrunt_dir()}/../../_component/eks-base.hcl"
}

# Dependencies on infrastructure layer (in module_infra_basic)
dependencies {
  paths = ["../../../../../../../module_infra_basic/aws/terra/environments/prod/infrastructure"]
}

dependency "infrastructure" {
  config_path = "../../../../../../../module_infra_basic/aws/terra/environments/prod/infrastructure"
  
  mock_outputs = {
    vpc_id             = "vpc-xxxxxxxx"
    public_subnet_ids  = ["subnet-xxxxxxxx", "subnet-yyyyyyyy", "subnet-zzzzzzzz"]
    private_subnet_ids = ["subnet-aaaaaaaa", "subnet-bbbbbbbb", "subnet-cccccccc"]
  }
  
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init", "refresh", "state", "destroy", "import"]
}

# Merge base template inputs with dependency-dependent inputs
# Use try() so partial dependency state still allows plan; mock values used when output missing.
inputs = merge(
  include.component.inputs,
  {
    vpc_id             = try(dependency.infrastructure.outputs.vpc_id, "vpc-xxxxxxxx")
    public_subnet_ids  = try(dependency.infrastructure.outputs.public_subnet_ids, ["subnet-xxxxxxxx", "subnet-yyyyyyyy", "subnet-zzzzzzzz"])
    private_subnet_ids = try(dependency.infrastructure.outputs.private_subnet_ids, ["subnet-aaaaaaaa", "subnet-bbbbbbbb", "subnet-cccccccc"])
  }
)

