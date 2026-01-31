# EKS layer for dev environment
# This file includes root and component base (non-nested includes)

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "component" {
  path = "${get_terragrunt_dir()}/../../_component/eks-base.hcl"
}

locals {
  env_config = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

# Dependencies on infrastructure layer (in module_infra_basic)
dependencies {
  paths = ["../../../../../../../module_infra_basic/aws/terra/environments/dev/infrastructure"]
}

dependency "infrastructure" {
  config_path = "../../../../../../../module_infra_basic/aws/terra/environments/dev/infrastructure"
  
  mock_outputs = {
    vpc_id                     = "vpc-xxxxxxxx"
    public_subnet_ids          = ["subnet-xxxxxxxx", "subnet-yyyyyyyy"]
    private_subnet_ids         = ["subnet-zzzzzzzz", "subnet-aaaaaaaa"]
    aurora_security_group_id   = "sg-xxxxxxxx"
  }
  
  # Allow mock outputs when dependency has no outputs (e.g. infra destroyed first).
  # init + state allow EKS teardown to run without needing infrastructure layer.
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init", "state", "destroy"]
}

# All inputs (dependency-dependent and non-dependent)
# Use try() so partial dependency state (e.g. only aurora_database_name) still allows plan; mock values used when output missing.
inputs = {
  project_name      = local.env_config.inputs.project_name
  environment       = local.env_config.inputs.environment
  aws_region        = local.env_config.inputs.aws_region
  
  vpc_id             = try(dependency.infrastructure.outputs.vpc_id, "vpc-xxxxxxxx")
  public_subnet_ids  = try(dependency.infrastructure.outputs.public_subnet_ids, ["subnet-xxxxxxxx", "subnet-yyyyyyyy"])
  private_subnet_ids = try(dependency.infrastructure.outputs.private_subnet_ids, ["subnet-zzzzzzzz", "subnet-aaaaaaaa"])
  
  # Aurora access configuration (similar to ECS)
  aurora_security_group_id = try(dependency.infrastructure.outputs.aurora_security_group_id, "sg-xxxxxxxx")
  
  cluster_version = local.env_config.inputs.eks_cluster_version
  enable_fargate  = local.env_config.inputs.eks_enable_fargate
  
  # Enable ingress node group (works alongside Fargate for app pods)
  enable_ingress_node_group = true
  
  # Fargate profiles: application + system (removed ingress-nginx - now uses node group)
  fargate_profiles = [
    {
      name = "default"
      selectors = [
        {
          namespace = "default"
          labels    = {}
        },
        {
          namespace = "kube-system"
          labels    = {}
        }
      ]
    }
  ]
  
  # Ingress node group configuration (small instance for NGINX only)
  node_group_instance_types = ["t3.small"]
  node_group_desired_size   = 1
  node_group_min_size       = 1
  node_group_max_size       = 1
  
  endpoint_private_access = local.env_config.inputs.eks_endpoint_private_access
  endpoint_public_access  = local.env_config.inputs.eks_endpoint_public_access
  endpoint_public_access_cidrs = local.env_config.inputs.eks_endpoint_public_access_cidrs
  
  enabled_cluster_log_types = local.env_config.inputs.eks_enabled_cluster_log_types
  
  container_type = "eks"
  
  tags = local.env_config.inputs.tags
}
