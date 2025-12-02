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
  description = "OpenAI API key"
  sensitive   = true
}

variable "db_password" {
  type        = string
  description = "Database password"
  sensitive   = true
}

variable "db_username" {
  type        = string
  description = "Database username"
  default     = "fru_user"
}

variable "create_db_username_secret" {
  type        = bool
  description = "Create secret for database username"
  default     = false
}

variable "aurora_database_name" {
  type        = string
  description = "Aurora database name"
  default     = "fru_db"
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

variable "tags" {
  type        = map(string)
  description = "Common tags"
  default     = {}
}

