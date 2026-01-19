# Application Layer - EKS
# Combines: EKS cluster, Frontend (for EKS deployments)
# Note: EKS uses Kubernetes Ingress → ALB (created by AWS Load Balancer Controller)
#       No need for ALB module here (ALB is created by Kubernetes controller)

# EKS Module
module "eks" {
  source = "../eks"

  project_name      = var.project_name
  environment       = var.environment
  aws_region        = var.aws_region
  vpc_id            = var.vpc_id
  public_subnet_ids = var.public_subnet_ids
  private_subnet_ids = var.private_subnet_ids

  cluster_version = var.cluster_version
  enable_fargate  = var.enable_fargate

  node_group_instance_types = var.node_group_instance_types
  node_group_desired_size   = var.node_group_desired_size
  node_group_min_size       = var.node_group_min_size
  node_group_max_size       = var.node_group_max_size
  node_group_disk_size      = var.node_group_disk_size

  fargate_profiles = var.fargate_profiles

  endpoint_private_access = var.endpoint_private_access
  endpoint_public_access  = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  enabled_cluster_log_types = var.enabled_cluster_log_types

  enable_secrets_encryption = var.enable_secrets_encryption
  kms_key_id = var.kms_key_id

  tags = var.tags
}

# Frontend Module
module "frontend" {
  source = "../frontend"

  project_name = var.project_name
  environment  = var.environment

  enable_versioning = var.enable_frontend_versioning
  cloudfront_price_class = var.cloudfront_price_class
  certificate_arn   = var.frontend_certificate_arn
  api_origin_id     = var.frontend_api_origin_id
  # Note: alb_dns_name is optional - for EKS, ALB DNS comes from Kubernetes Ingress
  # Can be set later if needed (e.g., via data source or manual update)
  alb_dns_name      = var.alb_dns_name

  tags = var.tags
}

