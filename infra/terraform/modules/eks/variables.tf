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

# Managed Node Group Configuration (if enable_fargate = false)
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
variable "endpoint_private_access" {
  type        = bool
  description = "Enable private API endpoint"
  default     = true
}

variable "endpoint_public_access" {
  type        = bool
  description = "Enable public API endpoint"
  default     = false
}

variable "endpoint_public_access_cidrs" {
  type        = list(string)
  description = "CIDR blocks allowed to access public endpoint"
  default     = ["0.0.0.0/0"]
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

# Tags
variable "tags" {
  type        = map(string)
  description = "Common tags"
  default     = {}
}

