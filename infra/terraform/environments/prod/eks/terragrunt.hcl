# EKS layer for prod environment
# This includes: EKS cluster, node groups (or Fargate profiles), OIDC provider

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path = "${get_terragrunt_dir()}/../env.hcl"
  expose = true
}

terraform {
  source = "${get_terragrunt_dir()}/../../../modules//eks"
}

# Set custom cache directory location for this configuration
download_dir = "${get_path_to_repo_root()}/temp_terra_gen/.terragrunt-cache/prod/eks"

# Dependencies on infrastructure layer
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

# Pass inputs from environment config and infrastructure outputs
inputs = {
  project_name      = include.env.inputs.project_name
  environment       = include.env.inputs.environment
  aws_region        = include.env.inputs.aws_region
  
  vpc_id             = dependency.infrastructure.outputs.vpc_id
  public_subnet_ids  = dependency.infrastructure.outputs.public_subnet_ids
  private_subnet_ids = dependency.infrastructure.outputs.private_subnet_ids
  
  cluster_version = include.env.inputs.eks_cluster_version
  enable_fargate = include.env.inputs.eks_enable_fargate
  
  node_group_instance_types = include.env.inputs.eks_node_group_instance_types
  node_group_desired_size   = include.env.inputs.eks_node_group_desired_size
  node_group_min_size       = include.env.inputs.eks_node_group_min_size
  node_group_max_size       = include.env.inputs.eks_node_group_max_size
  
  endpoint_private_access = include.env.inputs.eks_endpoint_private_access
  endpoint_public_access  = include.env.inputs.eks_endpoint_public_access
  
  enabled_cluster_log_types = include.env.inputs.eks_enabled_cluster_log_types
  
  tags = include.env.inputs.tags
}

