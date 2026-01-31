# ECS layer for dev environment
# This file includes root and component base (non-nested includes)

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "component" {
  path = "${get_terragrunt_dir()}/../../_component/ecs-base.hcl"
}

locals {
  env_config = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

# Dependencies on infrastructure layer (in module_infra_basic)
dependencies {
  paths = ["../../../../../../../module_infra_basic/aws/terra/environments/dev/infrastructure"]
}

dependency "infrastructure" {
  config_path = "../../../../../../../module_infra_basic/aws/terra/environments/dev/infrastructure"
  
  mock_outputs = {
    vpc_id                    = "vpc-xxxxxxxx"
    public_subnet_ids         = ["subnet-xxxxxxxx", "subnet-yyyyyyyy"]
    private_subnet_ids        = ["subnet-zzzzzzzz", "subnet-aaaaaaaa"]
    aurora_endpoint           = "fru-dev-aurora-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com"
    aurora_port               = 5432
    aurora_database_name      = "fru_db"
    aurora_security_group_id  = "sg-xxxxxxxx"
    ecs_task_execution_role_arn = "arn:aws:iam::999999999999:role/fru-dev-ecs-task-execution-role"
    ecs_task_runtime_role_arn   = "arn:aws:iam::999999999999:role/fru-dev-ecs-task-runtime-role"
    openai_secret_arn            = "arn:aws:secretsmanager:us-east-1:999999999999:secret:fru/dev/openai-api-key"
    openai_secret_plain_arn      = "arn:aws:secretsmanager:us-east-1:999999999999:secret:fru/dev/openai-api-key-plain"
    db_password_secret_arn       = "arn:aws:secretsmanager:us-east-1:999999999999:secret:fru/dev/aurora-db-password"
    db_password_plain_secret_arn = "arn:aws:secretsmanager:us-east-1:999999999999:secret:fru/dev/aurora-db-password-plain"
    db_username_secret_arn       = "arn:aws:secretsmanager:us-east-1:999999999999:secret:fru/dev/aurora-db-username"
    s3_data_bucket_id            = "fru-dev-analytics-data-999999999999"
    s3_data_bucket_arn           = "arn:aws:s3:::fru-dev-analytics-data-999999999999"
    s3_delta_table_path          = "s3://fru-dev-analytics-data-999999999999/delta"
  }
  
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init", "refresh", "state"]
}

# All inputs (dependency-dependent and non-dependent)
# Use try() so partial dependency state (e.g. only aurora_database_name) still allows plan/refresh
inputs = {
  project_name      = local.env_config.inputs.project_name
  environment       = local.env_config.inputs.environment
  aws_region        = local.env_config.inputs.aws_region
  
  vpc_id             = try(dependency.infrastructure.outputs.vpc_id, "vpc-xxxxxxxx")
  public_subnet_ids  = try(dependency.infrastructure.outputs.public_subnet_ids, ["subnet-xxxxxxxx", "subnet-yyyyyyyy"])
  private_subnet_ids = try(dependency.infrastructure.outputs.private_subnet_ids, ["subnet-zzzzzzzz", "subnet-aaaaaaaa"])
  
  ecs_task_execution_role_arn = try(dependency.infrastructure.outputs.ecs_task_execution_role_arn, "arn:aws:iam::999999999999:role/fru-dev-ecs-task-execution-role")
  ecs_task_runtime_role_arn  = try(dependency.infrastructure.outputs.ecs_task_runtime_role_arn, "arn:aws:iam::999999999999:role/fru-dev-ecs-task-runtime-role")
  
  aurora_endpoint        = try(dependency.infrastructure.outputs.aurora_endpoint, "fru-dev-aurora.cluster-xxxxx.us-east-1.rds.amazonaws.com")
  aurora_port            = try(dependency.infrastructure.outputs.aurora_port, 5432)
  aurora_database_name   = try(dependency.infrastructure.outputs.aurora_database_name, "fru_db")
  aurora_security_group_id = try(dependency.infrastructure.outputs.aurora_security_group_id, "sg-xxxxxxxx")
  
  openai_secret_arn            = try(dependency.infrastructure.outputs.openai_secret_arn, "arn:aws:secretsmanager:us-east-1:999999999999:secret:fru/dev/openai-api-key")
  openai_secret_plain_arn      = try(dependency.infrastructure.outputs.openai_secret_plain_arn, "arn:aws:secretsmanager:us-east-1:999999999999:secret:fru/dev/openai-api-key-plain")
  db_password_secret_arn       = try(dependency.infrastructure.outputs.db_password_secret_arn, "arn:aws:secretsmanager:us-east-1:999999999999:secret:fru/dev/aurora-db-password")
  db_password_plain_secret_arn = try(dependency.infrastructure.outputs.db_password_plain_secret_arn, "arn:aws:secretsmanager:us-east-1:999999999999:secret:fru/dev/aurora-db-password-plain")
  db_username_secret_arn       = try(dependency.infrastructure.outputs.db_username_secret_arn, "arn:aws:secretsmanager:us-east-1:999999999999:secret:fru/dev/aurora-db-username")
  
  container_image = get_env("CONTAINER_IMAGE", "")
  ecs_desired_count = local.env_config.inputs.ecs_desired_count
  ecs_task_cpu     = local.env_config.inputs.ecs_task_cpu
  ecs_task_memory  = local.env_config.inputs.ecs_task_memory
  
  bedrock_inference_profile_id = local.env_config.inputs.bedrock_inference_profile_id
  aws_bedrock_model_id = local.env_config.inputs.aws_bedrock_model_id
  log_level = local.env_config.inputs.log_level
  allowed_origins = local.env_config.inputs.allowed_origins
  openai_embed_model = local.env_config.inputs.openai_embed_model
  use_agent_query = local.env_config.inputs.use_agent_query
  
  s3_data_bucket_id = try(dependency.infrastructure.outputs.s3_data_bucket_id, "fru-dev-analytics-data-999999999999")
  s3_delta_table_path = try(dependency.infrastructure.outputs.s3_delta_table_path, "s3://fru-dev-analytics-data-999999999999/delta")
  
  enable_analytics_scheduler = local.env_config.inputs.enable_analytics_scheduler
  analytics_scheduler_interval_seconds = local.env_config.inputs.analytics_scheduler_interval_seconds
  spark_home = local.env_config.inputs.spark_home
  delta_table_path = "${try(dependency.infrastructure.outputs.s3_delta_table_path, "s3://fru-dev-analytics-data-999999999999/delta")}/fru_sales"
  delta_lake_package = local.env_config.inputs.delta_lake_package
  container_type = "ecs"
  
  deletion_protection = local.env_config.inputs.deletion_protection
  
  health_check_path = "/health"
  certificate_arn = null
  
  tags = local.env_config.inputs.tags
}
