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
    dynamodb_table = get_env("TF_STATE_LOCK_TABLE", "fru-terraform-locks")
  }

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}

# Generate provider configuration
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
EOF
}

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

