variable "project_name" {
  type        = string
  description = "Project name (e.g., fru)"
}

variable "environment" {
  type        = string
  description = "Environment (dev, staging, prod)"
}

variable "enable_versioning" {
  type        = bool
  description = "Enable S3 bucket versioning"
  default     = false
}

variable "cloudfront_price_class" {
  type        = string
  description = "CloudFront price class"
  default     = "PriceClass_100" # US, Canada, Europe
}

variable "certificate_arn" {
  type        = string
  description = "ACM certificate ARN for CloudFront (must be in us-east-1)"
  default     = null
}

variable "api_origin_id" {
  type        = string
  description = "Origin ID for API (ALB or API Gateway) - optional, for /query path"
  default     = null
}

variable "alb_dns_name" {
  type        = string
  description = "ALB DNS name for API origin - optional, for /query path"
  default     = null
}

variable "tags" {
  type        = map(string)
  description = "Common tags for all resources"
  default     = {}
}

