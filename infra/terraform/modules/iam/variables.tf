variable "project_name" {
  type        = string
  description = "Project name (e.g., fru)"
}

variable "environment" {
  type        = string
  description = "Environment (dev, staging, prod)"
}

variable "openai_secret_arn" {
  type        = string
  description = "ARN of OpenAI API key secret in Secrets Manager"
}

variable "db_password_secret_arn" {
  type        = string
  description = "ARN of database password secret in Secrets Manager"
}

variable "bedrock_model_arns" {
  type        = list(string)
  description = "List of Bedrock model ARNs that the task can invoke"
  default = [
    "arn:aws:bedrock:*::foundation-model/anthropic.claude-3-haiku-*",
    "arn:aws:bedrock:*::foundation-model/anthropic.claude-3-sonnet-*"
  ]
}

variable "enable_rds_iam_auth" {
  type        = bool
  description = "Enable IAM database authentication for Aurora"
  default     = false
}

variable "rds_db_resource_arn" {
  type        = string
  description = "ARN of RDS database resource for IAM auth (format: arn:aws:rds-db:region:account-id:dbuser:cluster-id/db-username)"
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Common tags for all resources"
  default     = {}
}

