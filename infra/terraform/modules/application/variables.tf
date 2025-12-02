variable "project_name" {
  type        = string
  description = "Project name"
}

variable "environment" {
  type        = string
  description = "Environment"
}

variable "aws_region" {
  type        = string
  description = "AWS region"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID"
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnet IDs"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs"
}

variable "ecs_task_execution_role_arn" {
  type        = string
  description = "ECS task execution role ARN"
}

variable "ecs_task_runtime_role_arn" {
  type        = string
  description = "ECS task runtime role ARN"
}

variable "aurora_endpoint" {
  type        = string
  description = "Aurora endpoint"
}

variable "aurora_port" {
  type        = number
  description = "Aurora port"
  default     = 5432
}

variable "aurora_database_name" {
  type        = string
  description = "Aurora database name"
}

variable "aurora_security_group_id" {
  type        = string
  description = "Aurora security group ID"
}

variable "openai_secret_arn" {
  type        = string
  description = "OpenAI secret ARN"
}

variable "db_password_secret_arn" {
  type        = string
  description = "Database password secret ARN"
}

variable "db_username_secret_arn" {
  type        = string
  description = "Database username secret ARN"
  default     = null
}

variable "container_image" {
  type        = string
  description = "Container image URI"
}

variable "container_name" {
  type        = string
  description = "Container name"
  default     = "fru-api"
}

variable "container_port" {
  type        = number
  description = "Container port"
  default     = 5000
}

variable "ecs_task_cpu" {
  type        = number
  description = "ECS task CPU"
  default     = 512
}

variable "ecs_task_memory" {
  type        = number
  description = "ECS task memory"
  default     = 1024
}

variable "ecs_desired_count" {
  type        = number
  description = "ECS desired count"
  default     = 1
}

variable "bedrock_model_id" {
  type        = string
  description = "Bedrock model ID"
  default     = "anthropic.claude-3-haiku-20240229-v1:0"
}

variable "health_check_path" {
  type        = string
  description = "Health check path"
  default     = "/health"
}

variable "certificate_arn" {
  type        = string
  description = "ALB certificate ARN"
  default     = null
}

variable "deletion_protection" {
  type        = bool
  description = "Enable deletion protection"
  default     = false
}

variable "enable_container_insights" {
  type        = bool
  description = "Enable container insights"
  default     = true
}

variable "enable_execute_command" {
  type        = bool
  description = "Enable ECS Exec"
  default     = false
}

variable "log_retention_days" {
  type        = number
  description = "Log retention days"
  default     = 7
}

variable "enable_frontend_versioning" {
  type        = bool
  description = "Enable S3 versioning for frontend"
  default     = false
}

variable "cloudfront_price_class" {
  type        = string
  description = "CloudFront price class"
  default     = "PriceClass_100"
}

variable "frontend_certificate_arn" {
  type        = string
  description = "CloudFront certificate ARN (must be in us-east-1)"
  default     = null
}

variable "frontend_api_origin_id" {
  type        = string
  description = "API origin ID for CloudFront"
  default     = null
}

variable "tags" {
  type        = map(string)
  description = "Common tags"
  default     = {}
}

