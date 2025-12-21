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

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for VPC"
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  type        = list(string)
  description = "List of availability zones"
}

variable "enable_nat_gateway" {
  type        = bool
  description = "Enable NAT Gateway"
  default     = true
}

variable "enable_bedrock_vpc_endpoint" {
  type        = bool
  description = "Enable VPC endpoint for Bedrock"
  default     = true
}

variable "openai_api_key" {
  type        = string
  description = "OpenAI API key (must be provided via .env - empty string will fail validation)"
  sensitive   = true
  
  validation {
    condition     = length(var.openai_api_key) > 0
    error_message = "openai_api_key cannot be empty. Please set OPENAI_API_KEY in your .env file."
  }
}

variable "db_password" {
  type        = string
  description = "Database password (must be provided via .env - empty string will fail validation)"
  sensitive   = true
  
  validation {
    condition     = length(var.db_password) > 0
    error_message = "db_password cannot be empty. Please set PGPASSWORD in your .env file."
  }
}

variable "db_username" {
  type        = string
  description = "Database username (must be provided via .env - empty string will fail validation)"
  default     = ""
  
  validation {
    condition     = length(var.db_username) > 0
    error_message = "db_username cannot be empty. Please set PGUSER in your .env file."
  }
}

variable "create_db_username_secret" {
  type        = bool
  description = "Create secret for database username"
  default     = false
}

variable "aurora_database_name" {
  type        = string
  description = "Aurora database name (must be provided via .env - empty string will fail validation)"
  default     = ""
  
  validation {
    condition     = length(var.aurora_database_name) > 0
    error_message = "aurora_database_name cannot be empty. Please set PGDATABASE in your .env file."
  }
}

variable "aurora_engine_version" {
  type        = string
  description = "Aurora engine version"
  default     = "16.3"
}

variable "aurora_instance_class" {
  type        = string
  description = "Aurora instance class"
  default     = "db.serverless"
}

variable "aurora_instance_count" {
  type        = number
  description = "Number of Aurora instances"
  default     = 1
}

variable "aurora_min_capacity" {
  type        = number
  description = "Aurora Serverless v2 min capacity"
  default     = 0.5
}

variable "aurora_max_capacity" {
  type        = number
  description = "Aurora Serverless v2 max capacity"
  default     = 16
}

variable "enable_iam_auth" {
  type        = bool
  description = "Enable IAM database authentication"
  default     = false
}

variable "enable_enhanced_monitoring" {
  type        = bool
  description = "Enable enhanced monitoring"
  default     = false
}

variable "aurora_backup_retention_period" {
  type        = number
  description = "Backup retention period in days"
  default     = 7
}

variable "aurora_preferred_backup_window" {
  type        = string
  description = "Preferred backup window"
  default     = "03:00-04:00"
}

variable "aurora_kms_key_id" {
  type        = string
  description = "KMS key ID for encryption"
  default     = null
}

variable "deletion_protection" {
  type        = bool
  description = "Enable deletion protection"
  default     = false
}

variable "bedrock_inference_profile_id" {
  type        = string
  description = "Bedrock inference profile ID (optional, for IAM permissions)"
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Common tags"
  default     = {}
}

