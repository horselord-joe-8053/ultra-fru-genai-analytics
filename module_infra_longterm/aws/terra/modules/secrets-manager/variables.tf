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
  description = "AWS region (used by generated provider)"
  default     = "us-east-1"
}

variable "openai_api_key" {
  type        = string
  description = "OpenAI API key (will be stored in Secrets Manager)"
  sensitive   = true
}

variable "db_password" {
  type        = string
  description = "Aurora PostgreSQL master password (will be stored in Secrets Manager)"
  sensitive   = true
}

variable "db_username" {
  type        = string
  description = "Aurora PostgreSQL master username"
  default     = "fru_user"
}

variable "create_db_username_secret" {
  type        = bool
  description = "Create a secret for database username (useful if not using IAM auth)"
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Common tags for all resources"
  default     = {}
}

