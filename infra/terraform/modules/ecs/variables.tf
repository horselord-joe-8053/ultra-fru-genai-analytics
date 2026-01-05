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
  description = "ARN of OpenAI API key secret (JSON format - for backward compatibility, not used by ECS)"
}

variable "openai_secret_plain_arn" {
  type        = string
  description = "ARN of OpenAI API key secret (plain string for ECS task definition)"
}

variable "db_password_secret_arn" {
  type        = string
  description = "ARN of database password secret (JSON format for RDS Data API - not used by ECS)"
}

variable "db_password_plain_secret_arn" {
  type        = string
  description = "ARN of database password secret (plain string for ECS task definition)"
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

variable "use_agent_query" {
  type        = string
  description = "Enable agent-based query processing (must be provided via .env - single source of truth)"
  default     = ""
  
  validation {
    condition     = length(var.use_agent_query) > 0
    error_message = "use_agent_query cannot be empty. Please set USE_AGENT_QUERY in your .env file."
  }
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

variable "enable_analytics_scheduler" {
  type        = string
  description = "Enable analytics scheduler (from .env - true/false)"
  default     = "false"
}

variable "analytics_scheduler_interval_seconds" {
  type        = string
  description = "Analytics scheduler interval in seconds (from .env)"
  default     = ""
}

variable "spark_home" {
  type        = string
  description = "Spark home directory (default: /opt/spark)"
  default     = "/opt/spark"
}

variable "delta_table_path" {
  type        = string
  description = "Delta table path (from .env - local path or S3 path). For AWS, should be S3 path (s3://bucket/delta/fru_sales). For local, use local path (data/delta/fru_sales)"
  default     = "data/delta/fru_sales"
}

variable "delta_lake_package" {
  type        = string
  description = "Delta Lake package (Maven coordinates) - required for Spark jobs. Format: io.delta:delta-spark_{SCALA_VERSION}:{DELTA_VERSION}. Standard: io.delta:delta-spark_2.13:4.0.0 (compatible with Spark 4.0.1). Must be set in .env file."
  default     = ""
  
  validation {
    condition     = length(var.delta_lake_package) > 0
    error_message = "delta_lake_package cannot be empty. Please set DELTA_LAKE_PACKAGE in your .env file."
  }
}

variable "s3_data_bucket_id" {
  type        = string
  description = "S3 bucket ID for analytics data (optional, for future use)"
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Common tags for all resources"
  default     = {}
}

