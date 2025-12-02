# Prod environment configuration
include "root" {
  path = find_in_parent_folders()
}

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
  
  # Secrets (MUST be provided via terraform.tfvars or environment variables)
  openai_api_key = get_env("OPENAI_API_KEY", "")
  db_password    = get_env("DB_PASSWORD", "")
  
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

