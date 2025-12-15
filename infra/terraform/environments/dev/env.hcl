# Dev environment configuration
# NOTE: Do NOT include "root" here - it's included by infrastructure/terragrunt.hcl and application/terragrunt.hcl
# Including it here would create a nested include chain, which Terragrunt doesn't allow.
# include "root" {
#   path = find_in_parent_folders()
# }

# Environment-specific inputs
inputs = {
  environment = "dev"
  project_name = "fru"
  
  # Dev-specific overrides
  aws_region = "us-east-1"
  
  # Availability zones
  availability_zones = ["us-east-1a", "us-east-1b"]
  
  # VPC configuration
  vpc_cidr = "10.0.0.0/16"
  
  # Aurora configuration (smaller for dev)
  aurora_min_capacity = 0.5
  aurora_max_capacity = 2
  aurora_instance_count = 1
  
  # ECS configuration
  ecs_desired_count = 1
  ecs_task_cpu = 256
  ecs_task_memory = 512
  
  # EKS configuration
  eks_cluster_version = "1.28"
  eks_enable_fargate = true  # Use Fargate for dev (simpler, no node management)
  eks_node_group_instance_types = ["t3.medium"]  # Only used if enable_fargate = false
  eks_node_group_desired_size = 2
  eks_node_group_min_size = 1
  eks_node_group_max_size = 3
  eks_endpoint_private_access = true
  eks_endpoint_public_access = false  # Private only for security
  eks_enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  
  # Secrets (should be provided via terraform.tfvars or environment variables)
  openai_api_key = get_env("OPENAI_API_KEY", "")
  db_username    = get_env("PGUSER", "fru_user")
  db_password    = get_env("PGPASSWORD", "ChangeMe123!")
  
  # Feature flags
  enable_nat_gateway = true
  enable_bedrock_vpc_endpoint = true
  enable_iam_auth = false  # Can enable later
  deletion_protection = false
  
  # Tags
  tags = {
    Environment = "dev"
    Project     = "FRU-GenAI"
    ManagedBy   = "Terraform"
  }
}

