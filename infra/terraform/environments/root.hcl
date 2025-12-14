# Root Terragrunt configuration
# This file contains common configuration shared across all environments

# Configure Terragrunt to use remote state
remote_state {
  backend = "s3"
  
  config = {
    bucket         = get_env("TF_STATE_BUCKET", "fru-terraform-state-${get_aws_account_id()}")
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = get_env("AWS_REGION", "us-east-1")
    encrypt        = true
    
    # AWS S3 now provides a native state lock table. Therefore it is prefered
    # that we use a lockfile from S3 as a single service, instead of managing 
    # 2 services (S3 bucket and DynamoDB table). Still, needs testing.
    # dynamodb_table = get_env("TF_STATE_LOCK_TABLE", "fru-terraform-locks")
    use_lockfile   = true
  }

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}

# Generate provider configuration
# NOTE: Terraform generates a provider configuration by itself. It is
# good practice to let the modules create provider config so we
# can use it anywhere else, instead of creating with root.hcl.
# generate "provider" {
#   path      = "provider.tf"
#   if_exists = "overwrite_terragrunt"
#   contents  = <<EOF
# terraform {
#   required_version = ">= 1.5.0"
#   required_providers {
#     aws = {
#       source  = "hashicorp/aws"
#       version = "~> 5.0"
#     }
#   }
# }
# 
# provider "aws" {
#   region = var.aws_region
# }
# EOF
# }

# Common inputs (can be overridden by environment-specific configs)
inputs = {
  aws_region = get_env("AWS_REGION", "us-east-1")
  
  # Common tags
  common_tags = {
    Project     = "FRU-GenAI"
    ManagedBy   = "Terraform"
    Environment = get_env("ENVIRONMENT", "dev")
  }
}

