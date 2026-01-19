# Application layer for dev environment
# This includes: ECS, ALB, Frontend

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path = "${get_terragrunt_dir()}/../env.hcl"
  expose = true
}

terraform {
  source = "${get_terragrunt_dir()}/../../../modules//application-ecs"
}

# Set custom cache directory location for this configuration
download_dir = "${get_path_to_repo_root()}/temp_terra_gen/.terragrunt-cache/dev/application"

# Dependencies on infrastructure layer
dependencies {
  paths = ["../infrastructure"]
}

dependency "infrastructure" {
  config_path = "../infrastructure"
  
  mock_outputs = {
    vpc_id                    = "vpc-xxxxxxxx"
    public_subnet_ids         = ["subnet-xxxxxxxx", "subnet-yyyyyyyy"]
    private_subnet_ids        = ["subnet-zzzzzzzz", "subnet-aaaaaaaa"]
    aurora_endpoint           = "fru-dev-aurora-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com"
    aurora_port               = 5432
    aurora_database_name      = "fru_db"
    aurora_security_group_id  = "sg-xxxxxxxx"
    ecs_task_execution_role_arn = "arn:aws:iam::123456789012:role/fru-dev-ecs-task-execution-role"
    ecs_task_runtime_role_arn   = "arn:aws:iam::123456789012:role/fru-dev-ecs-task-runtime-role"
    openai_secret_arn            = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fru/dev/openai-api-key"
    openai_secret_plain_arn      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fru/dev/openai-api-key-plain"
    db_password_secret_arn       = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fru/dev/aurora-db-password"
    db_password_plain_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fru/dev/aurora-db-password-plain"
    db_username_secret_arn       = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fru/dev/aurora-db-username"
    s3_data_bucket_id            = "fru-dev-analytics-data-123456789012"
    s3_data_bucket_arn           = "arn:aws:s3:::fru-dev-analytics-data-123456789012"
    s3_delta_table_path          = "s3://fru-dev-analytics-data-123456789012/delta"
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
  
  ecs_task_execution_role_arn = dependency.infrastructure.outputs.ecs_task_execution_role_arn
  ecs_task_runtime_role_arn  = dependency.infrastructure.outputs.ecs_task_runtime_role_arn
  
  aurora_endpoint        = dependency.infrastructure.outputs.aurora_endpoint
  aurora_port            = dependency.infrastructure.outputs.aurora_port
  aurora_database_name   = dependency.infrastructure.outputs.aurora_database_name
  aurora_security_group_id = dependency.infrastructure.outputs.aurora_security_group_id
  
  openai_secret_arn            = dependency.infrastructure.outputs.openai_secret_arn            # JSON format (for backward compatibility)
  openai_secret_plain_arn      = dependency.infrastructure.outputs.openai_secret_plain_arn     # Plain string (for ECS)
  db_password_secret_arn       = dependency.infrastructure.outputs.db_password_secret_arn        # JSON format (for RDS Data API)
  db_password_plain_secret_arn = dependency.infrastructure.outputs.db_password_plain_secret_arn # Plain string (for ECS)
  # Username secret: ensures PGUSER in ECS matches Aurora master_username (both from .env)
  db_username_secret_arn       = dependency.infrastructure.outputs.db_username_secret_arn
  
  container_image = get_env("CONTAINER_IMAGE", "") # Should be set after ECR push
  ecs_desired_count = include.env.inputs.ecs_desired_count
  ecs_task_cpu     = include.env.inputs.ecs_task_cpu
  ecs_task_memory  = include.env.inputs.ecs_task_memory
  
  # Application configuration (from .env via env.hcl)
  bedrock_inference_profile_id = include.env.inputs.bedrock_inference_profile_id  # Primary for Claude 3.5
  aws_bedrock_model_id = include.env.inputs.aws_bedrock_model_id  # Fallback for ON_DEMAND models
  log_level = include.env.inputs.log_level
  allowed_origins = include.env.inputs.allowed_origins
  openai_embed_model = include.env.inputs.openai_embed_model
  use_agent_query = include.env.inputs.use_agent_query
  
  # S3 configuration (from infrastructure layer)
  # S3 data bucket information (fail-fast if infrastructure outputs not available)
  # These must come from infrastructure outputs - fail-fast if infrastructure layer wasn't deployed
  s3_data_bucket_id = dependency.infrastructure.outputs.s3_data_bucket_id
  s3_delta_table_path = dependency.infrastructure.outputs.s3_delta_table_path
  
  # Analytics scheduler configuration (from .env via env.hcl)
  enable_analytics_scheduler = include.env.inputs.enable_analytics_scheduler
  analytics_scheduler_interval_seconds = include.env.inputs.analytics_scheduler_interval_seconds
  spark_home = include.env.inputs.spark_home
  # Delta table path: Use S3 path from infrastructure layer (fail-fast if not available)
  # Infrastructure outputs s3_delta_table_path as "s3://bucket/delta", append /fru_sales for the table name
  # This must come from infrastructure output - fail-fast if infrastructure layer wasn't deployed
  delta_table_path = "${dependency.infrastructure.outputs.s3_delta_table_path}/fru_sales"
  delta_lake_package = include.env.inputs.delta_lake_package
  deployment_type = "ecs"  # Set to "ecs" for ECS deployments, "eks" for EKS deployments
  
  deletion_protection = include.env.inputs.deletion_protection
  
  tags = include.env.inputs.tags
}

