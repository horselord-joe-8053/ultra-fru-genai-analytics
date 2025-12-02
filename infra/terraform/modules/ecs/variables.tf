variable "project_name" {
  type        = string
  description = "Project name (e.g., fru)"
}

variable "environment" {
  type        = string
  description = "Environment (dev, staging, prod)"
}

variable "aws_region" {
  type        = string
  description = "AWS region"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "List of private subnet IDs"
}

variable "ecs_task_execution_role_arn" {
  type        = string
  description = "ARN of ECS task execution role"
}

variable "ecs_task_runtime_role_arn" {
  type        = string
  description = "ARN of ECS task runtime role"
}

variable "aurora_endpoint" {
  type        = string
  description = "Aurora cluster endpoint"
}

variable "aurora_port" {
  type        = number
  description = "Aurora cluster port"
  default     = 5432
}

variable "aurora_database_name" {
  type        = string
  description = "Aurora database name"
  default     = "fru_db"
}

variable "openai_secret_arn" {
  type        = string
  description = "ARN of OpenAI API key secret"
}

variable "db_password_secret_arn" {
  type        = string
  description = "ARN of database password secret"
}

variable "db_username_secret_arn" {
  type        = string
  description = "ARN of database username secret (optional, if not using IAM auth)"
  default     = null
}

variable "container_image" {
  type        = string
  description = "Container image URI (from ECR)"
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

variable "task_cpu" {
  type        = number
  description = "CPU units for task (256, 512, 1024, etc.)"
  default     = 512
}

variable "task_memory" {
  type        = number
  description = "Memory for task in MB (512, 1024, 2048, etc.)"
  default     = 1024
}

variable "desired_count" {
  type        = number
  description = "Desired number of tasks"
  default     = 1
}

variable "bedrock_model_id" {
  type        = string
  description = "Bedrock model ID"
  default     = "anthropic.claude-3-haiku-20240229-v1:0"
}

variable "alb_target_group_arn" {
  type        = string
  description = "ARN of ALB target group (optional)"
  default     = null
}

variable "alb_security_group_id" {
  type        = string
  description = "Security group ID of ALB (for ingress rule)"
  default     = null
}

variable "service_registry_arn" {
  type        = string
  description = "ARN of service registry (optional, for service discovery)"
  default     = null
}

variable "deployment_maximum_percent" {
  type        = number
  description = "Maximum percent of tasks during deployment"
  default     = 200
}

variable "deployment_minimum_percent" {
  type        = number
  description = "Minimum percent of tasks during deployment"
  default     = 100
}

variable "enable_container_insights" {
  type        = bool
  description = "Enable CloudWatch Container Insights"
  default     = true
}

variable "enable_execute_command" {
  type        = bool
  description = "Enable ECS Exec for debugging"
  default     = false
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log retention in days"
  default     = 7
}

variable "tags" {
  type        = map(string)
  description = "Common tags for all resources"
  default     = {}
}

