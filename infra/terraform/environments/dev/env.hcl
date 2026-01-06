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
  # Note: Memory increased to 4096 MB (4 GB) to support Spark jobs in local mode
  # Spark requires ~2-3 GB for driver + executor + Delta Lake processing
  # CPU increased to 1024 (1 vCPU) to match memory increase (Fargate requires specific CPU/memory combinations)
  ecs_desired_count = 1
  ecs_task_cpu = 1024
  ecs_task_memory = 4096
  
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
  # Use empty defaults for fail-fast behavior - ensures .env is the single source of truth
  openai_api_key = get_env("OPENAI_API_KEY", "")
  db_username    = get_env("PGUSER", "")
  db_password    = get_env("PGPASSWORD", "")
  
  # Application configuration (from .env)
  bedrock_inference_profile_id = get_env("AWS_BEDROCK_INFERENCE_PROFILE_ID", "")  # Primary for Claude 3.5
  aws_bedrock_model_id = get_env("AWS_BEDROCK_MODEL_ID", "")  # Fallback for ON_DEMAND models
  aurora_database_name = get_env("PGDATABASE", "")
  log_level = get_env("LOG_LEVEL", "")
  allowed_origins = get_env("ALLOWED_ORIGINS", "")
  openai_embed_model = get_env("OPENAI_EMBED_MODEL", "")
  use_agent_query = get_env("USE_AGENT_QUERY", "")
  
  # Analytics scheduler configuration (optional)
  enable_analytics_scheduler = get_env("ENABLE_ANALYTICS_SCHEDULER", "false")
  analytics_scheduler_interval_seconds = get_env("ANALYTICS_SCHEDULER_INTERVAL_SECONDS", "")
  spark_home = get_env("SPARK_HOME", "/opt/spark")
  # For AWS: S3 path will be set by infrastructure layer output (s3://bucket/delta/fru_sales)
  # For local: use local path (data/delta/fru_sales)
  # If DELTA_TABLE_PATH is set in .env, use it; otherwise use default
  delta_table_path = get_env("DELTA_TABLE_PATH", "data/delta/fru_sales")
  # Delta Lake package (Maven coordinates) - required for Spark jobs
  # Must be set in .env file (no default - fail-fast behavior)
  delta_lake_package = get_env("DELTA_LAKE_PACKAGE", "")
  
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

