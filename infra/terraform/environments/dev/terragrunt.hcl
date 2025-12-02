# Dev environment configuration
include "root" {
  path = find_in_parent_folders()
}

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
  
  # Secrets (should be provided via terraform.tfvars or environment variables)
  openai_api_key = get_env("OPENAI_API_KEY", "")
  db_password    = get_env("DB_PASSWORD", "ChangeMe123!")
  
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

