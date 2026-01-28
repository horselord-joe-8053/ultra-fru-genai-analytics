variable "project_name" {
  type        = string
  description = "Project name prefix"
}

variable "environment" {
  type        = string
  description = "Environment (dev/prod)"
}

variable "aws_region" {
  type        = string
  description = "AWS region"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID (from infrastructure layer)"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs (for EKS nodes)"
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnet IDs (for load balancers)"
}

variable "cluster_version" {
  type        = string
  description = "Kubernetes version"
  default     = "1.28"
}

variable "enable_fargate" {
  type        = bool
  description = "Use Fargate instead of managed node groups"
  default     = true
}

variable "enable_ingress_node_group" {
  type        = bool
  description = "Enable small EC2 node group for ingress controllers (works alongside Fargate for app pods)"
  default     = false
}

# Managed Node Group Configuration (if enable_fargate = false OR enable_ingress_node_group = true)
variable "node_group_instance_types" {
  type        = list(string)
  description = "EC2 instance types for node groups"
  default     = ["t3.medium"]
}

variable "node_group_desired_size" {
  type        = number
  description = "Desired node count"
  default     = 2
}

variable "node_group_min_size" {
  type        = number
  description = "Minimum node count"
  default     = 1
}

variable "node_group_max_size" {
  type        = number
  description = "Maximum node count"
  default     = 3
}

variable "node_group_disk_size" {
  type        = number
  description = "Disk size in GB for node groups"
  default     = 20
}

# Fargate Profile Configuration (if enable_fargate = true)
variable "fargate_profiles" {
  type = list(object({
    name          = string
    selectors = list(object({
      namespace = string
      labels    = map(string)
    }))
  }))
  description = "Fargate profile configurations"
  default = [
    {
      name = "default"
      selectors = [
        {
          namespace = "default"
          labels    = {}
        },
        {
          namespace = "kube-system"
          labels    = {}
        }
      ]
    }
  ]
}

# Cluster Endpoint Configuration
# NOTE: EKS endpoint configuration differs from ECS deployment requirements
# - ECS: Uses AWS APIs (public endpoints) - no VPC access needed for deployment
# - EKS: Uses kubectl (direct network to API server) - requires public endpoint for remote deployment
# - Public endpoint still secure: IAM authentication required, pods remain private
variable "endpoint_private_access" {
  type        = bool
  description = "Enable private API endpoint"
  default     = true
}

variable "endpoint_public_access" {
  type        = bool
  description = "Enable public API endpoint. Required for kubectl access from deployment machines outside VPC (unlike ECS which uses AWS APIs). Default true for dev/staging, consider false for production with EC2 runner."
  default     = true  # Changed default to true - EKS needs this for kubectl deployment (unlike ECS)
}

variable "endpoint_public_access_cidrs" {
  type        = list(string)
  description = "CIDR blocks allowed to access public endpoint. Default ['0.0.0.0/0'] = all IPs (still requires IAM auth). Can restrict to specific IPs for additional security (e.g., office/home IPs)."
  default     = ["0.0.0.0/0"]  # Default = open to all IPs (still authenticated via IAM); can restrict if needed
}

# Cluster Logging
variable "enabled_cluster_log_types" {
  type        = list(string)
  description = "Control plane logging types"
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

# Encryption
variable "enable_secrets_encryption" {
  type        = bool
  description = "Enable secrets encryption"
  default     = true
}

variable "kms_key_id" {
  type        = string
  description = "KMS key ID for secrets encryption (optional, creates one if not provided)"
  default     = null
}

# Frontend Configuration
variable "container_type" {
  type        = string
  description = "Container type (ecs or eks) - used to create separate frontend instances per container type"
  default     = "eks"
}

variable "enable_frontend_versioning" {
  type        = bool
  description = "Enable S3 versioning for frontend"
  default     = false
}

variable "cloudfront_price_class" {
  type        = string
  description = "CloudFront price class"
  default     = "PriceClass_100"
}

variable "frontend_certificate_arn" {
  type        = string
  description = "CloudFront certificate ARN (must be in us-east-1)"
  default     = null
}

variable "frontend_api_origin_id" {
  type        = string
  description = "API origin ID for CloudFront"
  default     = null
}

variable "alb_dns_name" {
  type        = string
  description = "ALB DNS name for API origin (optional - for EKS, comes from Kubernetes Ingress)"
  default     = null
}

# Tags
variable "aurora_security_group_id" {
  type        = string
  description = "Aurora security group ID (for allowing EKS pods to connect)"
  default     = null
}

variable "api_replicas" {
  type        = number
  description = "Number of replicas for the API deployment"
  default     = 2
}

variable "tags" {
  type        = map(string)
  description = "Common tags"
  default     = {}
}

