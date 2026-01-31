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

variable "public_subnet_ids" {
  type        = list(string)
  description = "List of public subnet IDs"
}

variable "target_port" {
  type        = number
  description = "Target port for ECS tasks"
  default     = 5000
}

variable "health_check_path" {
  type        = string
  description = "Health check path"
  default     = "/health"
}

variable "certificate_arn" {
  type        = string
  description = "ACM certificate ARN for HTTPS (optional)"
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

