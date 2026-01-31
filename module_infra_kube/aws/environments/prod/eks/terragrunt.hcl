# EKS layer for prod environment
# This file includes root and component base (non-nested includes)

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "component" {
  path = "${get_terragrunt_dir()}/../../_component/eks-base.hcl"
}

# Dependencies on infrastructure layer (must be in child file, not base template)
dependencies {
  paths = ["../infrastructure"]
}

dependency "infrastructure" {
  config_path = "../infrastructure"
  
  mock_outputs = {
    vpc_id             = "vpc-xxxxxxxx"
    public_subnet_ids  = ["subnet-xxxxxxxx", "subnet-yyyyyyyy", "subnet-zzzzzzzz"]
    private_subnet_ids = ["subnet-aaaaaaaa", "subnet-bbbbbbbb", "subnet-cccccccc"]
  }
  
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Merge base template inputs with dependency-dependent inputs
inputs = merge(
  include.component.inputs,
  {
    vpc_id             = dependency.infrastructure.outputs.vpc_id
    public_subnet_ids  = dependency.infrastructure.outputs.public_subnet_ids
    private_subnet_ids = dependency.infrastructure.outputs.private_subnet_ids
  }
)

