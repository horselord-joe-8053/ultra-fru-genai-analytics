# ECS layer for prod environment
# This file includes root and component base (non-nested includes)

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "component" {
  path = "${get_terragrunt_dir()}/../../_component/ecs-base.hcl"
}

# Dependencies on infrastructure layer (in module_infra_basic)
dependencies {
  paths = ["../../../../../../../module_infra_basic/aws/terra/environments/prod/infrastructure"]
}

dependency "infrastructure" {
  config_path = "../../../../../../../module_infra_basic/aws/terra/environments/prod/infrastructure"
  
  mock_outputs = {
    vpc_id                    = "vpc-xxxxxxxx"
    public_subnet_ids         = ["subnet-xxxxxxxx", "subnet-yyyyyyyy", "subnet-zzzzzzzz"]
    private_subnet_ids        = ["subnet-aaaaaaaa", "subnet-bbbbbbbb", "subnet-cccccccc"]
    aurora_endpoint           = "fru-prod-aurora-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com"
    aurora_port               = 5432
    aurora_database_name      = "fru_db"
    aurora_security_group_id  = "sg-xxxxxxxx"
    ecs_task_execution_role_arn = "arn:aws:iam::999999999999:role/fru-prod-ecs-task-execution-role"
    ecs_task_runtime_role_arn   = "arn:aws:iam::999999999999:role/fru-prod-ecs-task-runtime-role"
    openai_secret_arn         = "arn:aws:secretsmanager:us-east-1:999999999999:secret:fru/prod/openai-api-key"
    db_password_secret_arn    = "arn:aws:secretsmanager:us-east-1:999999999999:secret:fru/prod/aurora-db-password"
    db_username_secret_arn    = "arn:aws:secretsmanager:us-east-1:999999999999:secret:fru/prod/aurora-db-username"
    s3_data_bucket_id         = "fru-prod-analytics-data-999999999999"
    s3_data_bucket_arn        = "arn:aws:s3:::fru-prod-analytics-data-999999999999"
    s3_delta_table_path       = "s3://fru-prod-analytics-data-999999999999/delta"
  }
  
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Merge base template inputs with dependency-dependent inputs
inputs = merge(
  include.component.inputs,
  {
    vpc_id             = dependency.infrastructure.outputs.vpc_id
    public_subnet_ids  = dependency.infrastructure.outputs.public_subnet_ids
    private_subnet_ids = dependency.infrastructure.outputs.private_subnet_ids
    
    ecs_task_execution_role_arn = dependency.infrastructure.outputs.ecs_task_execution_role_arn
    ecs_task_runtime_role_arn  = dependency.infrastructure.outputs.ecs_task_runtime_role_arn
    
    aurora_endpoint        = dependency.infrastructure.outputs.aurora_endpoint
    aurora_port            = dependency.infrastructure.outputs.aurora_port
    aurora_database_name   = dependency.infrastructure.outputs.aurora_database_name
    aurora_security_group_id = dependency.infrastructure.outputs.aurora_security_group_id
    
    openai_secret_arn      = dependency.infrastructure.outputs.openai_secret_arn
    db_password_secret_arn = dependency.infrastructure.outputs.db_password_secret_arn
    db_username_secret_arn = dependency.infrastructure.outputs.db_username_secret_arn
    
    s3_data_bucket_id = dependency.infrastructure.outputs.s3_data_bucket_id
    s3_delta_table_path = dependency.infrastructure.outputs.s3_delta_table_path
    delta_table_path = "${dependency.infrastructure.outputs.s3_delta_table_path}/fru_sales"
  }
)
