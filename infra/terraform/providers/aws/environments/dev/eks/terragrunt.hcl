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

# Dependencies on infrastructure layer (must be in child file, not base template)
dependencies {
  paths = ["../infrastructure"]
}

dependency "infrastructure" {
  config_path = "../infrastructure"
  
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
inputs = {
  project_name      = local.env_config.inputs.project_name
  environment       = local.env_config.inputs.environment
  aws_region        = local.env_config.inputs.aws_region
  
  vpc_id             = dependency.infrastructure.outputs.vpc_id
  public_subnet_ids  = dependency.infrastructure.outputs.public_subnet_ids
  private_subnet_ids = dependency.infrastructure.outputs.private_subnet_ids
  
  # Aurora access configuration (similar to ECS)
  aurora_security_group_id = dependency.infrastructure.outputs.aurora_security_group_id
  
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
  
  container_type = "eks"  # Separate frontend instance for EKS (container_type)
  
  enable_frontend_versioning = false
  cloudfront_price_class     = "PriceClass_100"
  frontend_certificate_arn   = null
  frontend_api_origin_id     = "ALB-${local.env_config.inputs.project_name}-${local.env_config.inputs.environment}-eks"
  # LoadBalancer DNS (from Kubernetes Ingress)
  # Get via: kubectl get ingress fru-api-ingress-dev -n fru-api-dev -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
  # Or: kubectl get ingress --all-namespaces -o jsonpath='{.items[?(@.metadata.name=~"fru-api-ingress*")].status.loadBalancer.ingress[0].hostname}'
  alb_dns_name               = "ad36c0036890a439eae339e83c735cdc-78ffc1fad6560c8f.elb.us-east-1.amazonaws.com"
  
  tags = local.env_config.inputs.tags
}
