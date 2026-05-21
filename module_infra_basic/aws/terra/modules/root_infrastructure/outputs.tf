# VPC Outputs
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

# Aurora Outputs
output "aurora_endpoint" {
  description = "Aurora cluster endpoint"
  value       = module.aurora.cluster_endpoint
}

output "aurora_port" {
  description = "Aurora cluster port"
  value       = module.aurora.cluster_port
}

output "aurora_database_name" {
  description = "Aurora database name"
  value       = module.aurora.database_name
}

output "aurora_security_group_id" {
  description = "Aurora security group ID"
  value       = module.aurora.security_group_id
}

output "db_cluster_arn" {
  description = "Aurora DB cluster ARN (for RDS Data API)"
  value       = module.aurora.cluster_arn
}

# IAM Outputs
output "ecs_task_execution_role_arn" {
  description = "ECS task execution role ARN"
  value       = module.iam.ecs_task_execution_role_arn
}

output "ecs_task_runtime_role_arn" {
  description = "ECS task runtime role ARN"
  value       = module.iam.ecs_task_runtime_role_arn
}

# Secrets Manager Outputs (from longterm layer remote_state)
output "openai_secret_arn" {
  description = "OpenAI secret ARN (JSON format - for backward compatibility)"
  value       = data.terraform_remote_state.longterm.outputs.openai_secret_arn
}

output "openai_secret_plain_arn" {
  description = "OpenAI secret ARN (plain string for ECS)"
  value       = data.terraform_remote_state.longterm.outputs.openai_secret_plain_arn
}

output "db_password_secret_arn" {
  description = "Database password secret ARN"
  value       = data.terraform_remote_state.longterm.outputs.db_password_secret_arn
}

output "db_username_secret_arn" {
  description = "Database username secret ARN"
  value       = data.terraform_remote_state.longterm.outputs.db_username_secret_arn
}

output "db_password_plain_secret_arn" {
  description = "Database password secret ARN (plain string for ECS)"
  value       = data.terraform_remote_state.longterm.outputs.db_password_plain_secret_arn
}

# S3 Data Bucket Outputs
output "s3_data_bucket_id" {
  description = "S3 bucket ID for analytics data"
  value       = module.s3_data.bucket_id
}

output "s3_data_bucket_arn" {
  description = "S3 bucket ARN for analytics data"
  value       = module.s3_data.bucket_arn
}

output "s3_delta_table_path" {
  description = "S3 path for Delta tables (use this for DELTA_TABLE_PATH env var)"
  value       = module.s3_data.delta_table_path
}

output "s3_raw_data_path" {
  description = "S3 path for raw data files"
  value       = module.s3_data.raw_data_path
}

