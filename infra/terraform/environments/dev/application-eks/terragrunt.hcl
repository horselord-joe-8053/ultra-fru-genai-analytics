# Application layer for EKS - dev environment
# This includes: EKS cluster, Frontend (for EKS deployments)
# Note: EKS uses Kubernetes Ingress → ALB (created by AWS Load Balancer Controller)
#       No need for ALB module or ECS module here

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path = "${get_terragrunt_dir()}/../env.hcl"
  expose = true
}

terraform {
  source = "${get_terragrunt_dir()}/../../../modules//application-eks"
}

# Set custom cache directory location for this configuration
download_dir = "${get_path_to_repo_root()}/temp_terra_gen/.terragrunt-cache/dev/application-eks"

# Dependencies on infrastructure layer
dependencies {
  paths = ["../infrastructure"]
}

dependency "infrastructure" {
  config_path = "../infrastructure"
  
  mock_outputs = {
    vpc_id             = "vpc-xxxxxxxx"
    public_subnet_ids  = ["subnet-xxxxxxxx", "subnet-yyyyyyyy"]
    private_subnet_ids = ["subnet-zzzzzzzz", "subnet-aaaaaaaa"]
  }
  
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Pass inputs from environment config and infrastructure outputs
inputs = {
  project_name      = include.env.inputs.project_name
  environment       = include.env.inputs.environment
  aws_region        = include.env.inputs.aws_region
  
  # Infrastructure dependencies
  vpc_id             = dependency.infrastructure.outputs.vpc_id
  public_subnet_ids  = dependency.infrastructure.outputs.public_subnet_ids
  private_subnet_ids = dependency.infrastructure.outputs.private_subnet_ids
  
  # EKS Cluster Configuration
  cluster_version = include.env.inputs.eks_cluster_version
  enable_fargate  = include.env.inputs.eks_enable_fargate
  
  node_group_instance_types = include.env.inputs.eks_node_group_instance_types
  node_group_desired_size   = include.env.inputs.eks_node_group_desired_size
  node_group_min_size       = include.env.inputs.eks_node_group_min_size
  node_group_max_size       = include.env.inputs.eks_node_group_max_size
  
  endpoint_private_access = include.env.inputs.eks_endpoint_private_access
  endpoint_public_access  = include.env.inputs.eks_endpoint_public_access
  endpoint_public_access_cidrs = include.env.inputs.eks_endpoint_public_access_cidrs
  
  enabled_cluster_log_types = include.env.inputs.eks_enabled_cluster_log_types
  
  # Frontend Configuration
  # Use default values (same as application-ecs) - these can be overridden in env.hcl if needed
  enable_frontend_versioning = false  # Default: disable S3 versioning for dev
  cloudfront_price_class     = "PriceClass_100"  # Default: cheapest price class (US/Canada/Europe)
  frontend_certificate_arn   = null  # Default: no custom certificate (uses CloudFront default)
  frontend_api_origin_id     = "ALB-${include.env.inputs.project_name}-${include.env.inputs.environment}-eks" # Unique origin ID for EKS ALB
  # Note: alb_dns_name is optional for EKS - ALB DNS comes from Kubernetes Ingress
  # Can be set later if needed (e.g., via data source or manual update)
  alb_dns_name               = null
  
  tags = include.env.inputs.tags
}

