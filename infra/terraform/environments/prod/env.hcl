# Prod environment configuration
# NOTE: Do NOT include "root" here - it's included by infrastructure/terragrunt.hcl and application/terragrunt.hcl
# Including it here would create a nested include chain, which Terragrunt doesn't allow.
# include "root" {
#   path = find_in_parent_folders()
# }

# Environment-specific inputs
inputs = {
  environment = "prod"
  project_name = "fru"
  
  # Prod-specific overrides
  aws_region = "us-east-1"
  
  # Availability zones (multi-AZ for HA)
  availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
  
  # VPC configuration
  vpc_cidr = "10.0.0.0/16"
  
  # Aurora configuration (larger for prod)
  aurora_min_capacity = 2
  aurora_max_capacity = 16
  aurora_instance_count = 2  # Multi-AZ
  
  # ECS configuration
  ecs_desired_count = 2  # Minimum 2 for HA
  ecs_task_cpu = 512
  ecs_task_memory = 1024
  
  # EKS configuration
  eks_cluster_version = "1.28"
  eks_enable_fargate = true  # Use Fargate for prod (serverless, easier management)
  eks_node_group_instance_types = ["t3.large"]  # Only used if enable_fargate = false
  eks_node_group_desired_size = 3  # Multi-AZ for HA
  eks_node_group_min_size = 2
  eks_node_group_max_size = 5
  eks_endpoint_private_access = true
  eks_endpoint_public_access = false  # Private only for security
  eks_enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  
  # Secrets (MUST be provided via terraform.tfvars or environment variables)
  openai_api_key = get_env("OPENAI_API_KEY", "")
  db_username    = get_env("PGUSER", "fru_user")
  db_password    = get_env("PGPASSWORD", "")
  
  # Feature flags
  enable_nat_gateway = true
  enable_bedrock_vpc_endpoint = true
  enable_iam_auth = true  # Enable IAM database authentication
  deletion_protection = true  # Protect against accidental deletion
  
  # Tags
  tags = {
    Environment = "prod"
    Project     = "FRU-GenAI"
    ManagedBy   = "Terraform"
  }
}

