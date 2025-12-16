# Infrastructure layer for prod environment
# This includes: VPC, Aurora, IAM, Secrets Manager

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path = "${get_terragrunt_dir()}/../env.hcl"
  expose = true
}

terraform {
  source = "${get_terragrunt_dir()}/../../../modules//infrastructure"
}

# Set custom cache directory location for this configuration
download_dir = "${get_path_to_repo_root()}/temp_terra_gen/.terragrunt-cache/prod/infrastructure"

# Pass inputs from environment config
inputs = {
  project_name      = include.env.inputs.project_name
  environment       = include.env.inputs.environment
  aws_region        = include.env.inputs.aws_region
  vpc_cidr          = include.env.inputs.vpc_cidr
  availability_zones = include.env.inputs.availability_zones
  
  enable_nat_gateway         = include.env.inputs.enable_nat_gateway
  enable_bedrock_vpc_endpoint = include.env.inputs.enable_bedrock_vpc_endpoint
  
  openai_api_key = include.env.inputs.openai_api_key
  db_password    = include.env.inputs.db_password
  db_username     = include.env.inputs.db_username
  
  # Create username secret so ECS can use PGUSER from Secrets Manager (single source of truth: .env)
  create_db_username_secret = true
  
  aurora_database_name = "fru_db"
  aurora_min_capacity  = include.env.inputs.aurora_min_capacity
  aurora_max_capacity  = include.env.inputs.aurora_max_capacity
  aurora_instance_count = include.env.inputs.aurora_instance_count
  
  enable_iam_auth = include.env.inputs.enable_iam_auth
  deletion_protection = include.env.inputs.deletion_protection
  
  tags = include.env.inputs.tags
}

# Dependencies: None (infrastructure layer is the foundation)

