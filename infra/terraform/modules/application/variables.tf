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
  description = "OpenAI secret ARN (JSON format - for backward compatibility)"
}

variable "openai_secret_plain_arn" {
  type        = string
  description = "OpenAI secret ARN (plain string for ECS)"
}

variable "db_password_secret_arn" {
  type        = string
  description = "Database password secret ARN (JSON format for RDS Data API)"
}

variable "db_password_plain_secret_arn" {
  type        = string
  description = "Database password secret ARN (plain string for ECS)"
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

variable "bedrock_inference_profile_id" {
  type        = string
  description = "Bedrock inference profile ID (primary for Claude 3.5 and newer models). Can be empty if using model ID."
  default     = ""
}

variable "aws_bedrock_model_id" {
  type        = string
  description = "AWS Bedrock model ID (fallback for ON_DEMAND models). Can be empty if using inference profile."
  default     = ""
}

variable "log_level" {
  type        = string
  description = "Logging level (must be provided via .env - empty string will fail validation)"
  default     = ""
  
  validation {
    condition     = length(var.log_level) > 0
    error_message = "log_level cannot be empty. Please set LOG_LEVEL in your .env file."
  }
}

variable "allowed_origins" {
  type        = string
  description = "Comma-separated list of allowed CORS origins (must be provided via .env - empty string will fail validation)"
  default     = ""
  
  validation {
    condition     = length(var.allowed_origins) > 0
    error_message = "allowed_origins cannot be empty. Please set ALLOWED_ORIGINS in your .env file."
  }
}

variable "openai_embed_model" {
  type        = string
  description = "OpenAI embedding model (must be provided via .env - empty string will fail validation)"
  default     = ""
  
  validation {
    condition     = length(var.openai_embed_model) > 0
    error_message = "openai_embed_model cannot be empty. Please set OPENAI_EMBED_MODEL in your .env file."
  }
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

