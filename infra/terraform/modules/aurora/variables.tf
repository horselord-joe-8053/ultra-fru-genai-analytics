variable "project_name" {
  type        = string
  description = "Project name (e.g., fru)"
}

variable "environment" {
  type        = string
  description = "Environment (dev, staging, prod)"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "List of private subnet IDs"
}

variable "ecs_security_group_id" {
  type        = string
  description = "Security group ID of ECS tasks"
}

variable "database_name" {
  type        = string
  description = "Name of the default database"
  default     = "fru_db"
}

variable "master_username" {
  type        = string
  description = "Master username for Aurora"
  default     = "fru_user"
}

variable "master_password" {
  type        = string
  description = "Master password for Aurora (should use Secrets Manager in production)"
  sensitive   = true
}

variable "engine_version" {
  type        = string
  description = "Aurora PostgreSQL engine version"
  default     = "16.4"
}

variable "instance_class" {
  type        = string
  description = "Instance class for Aurora Serverless v2"
  default     = "db.serverless"
}

variable "instance_count" {
  type        = number
  description = "Number of Aurora instances"
  default     = 1
}

variable "min_capacity" {
  type        = number
  description = "Minimum ACU for Aurora Serverless v2"
  default     = 0.5
}

variable "max_capacity" {
  type        = number
  description = "Maximum ACU for Aurora Serverless v2"
  default     = 16
}

variable "enable_iam_auth" {
  type        = bool
  description = "Enable IAM database authentication (recommended for security)"
  default     = true
}

variable "enable_enhanced_monitoring" {
  type        = bool
  description = "Enable enhanced monitoring"
  default     = false
}

variable "backup_retention_period" {
  type        = number
  description = "Backup retention period in days"
  default     = 7
}

variable "preferred_backup_window" {
  type        = string
  description = "Preferred backup window"
  default     = "03:00-04:00"
}

variable "kms_key_id" {
  type        = string
  description = "KMS key ID for encryption (optional, uses default if not specified)"
  default     = null
}

variable "deletion_protection" {
  type        = bool
  description = "Enable deletion protection"
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Common tags for all resources"
  default     = {}
}

