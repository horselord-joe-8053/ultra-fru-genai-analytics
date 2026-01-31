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
  description = "Enable NAT Gateway for private subnets"
  default     = true
}

variable "enable_bedrock_vpc_endpoint" {
  type        = bool
  description = "Enable VPC endpoint for Bedrock (recommended for security)"
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "Common tags for all resources"
  default     = {}
}

