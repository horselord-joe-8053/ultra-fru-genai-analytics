variable "project_name" {
  type        = string
  description = "Project name (e.g., 'fru')"
}

variable "environment" {
  type        = string
  description = "Environment name (e.g., 'dev', 'prod')"
}

variable "tags" {
  type        = map(string)
  description = "Common tags for all resources"
  default     = {}
}

