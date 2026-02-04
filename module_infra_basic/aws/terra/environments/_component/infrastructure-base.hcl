# Infrastructure layer base template
# NOTE: This file does NOT include root or env - that's done by the child terragrunt.hcl
# This avoids nested includes while still allowing access to environment values
# Uses read_terragrunt_config() workaround to access env.hcl

locals {
  env_config = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env_name = basename(dirname(get_terragrunt_dir()))
  layer_name = basename(get_terragrunt_dir())
}

terraform {
  source = "${get_terragrunt_dir()}/../../../modules//root_infrastructure"
}

download_dir = "${get_path_to_repo_root()}/temp_terra_gen/.terragrunt-cache/${local.env_name}/${local.layer_name}"

inputs = {
  project_name      = local.env_config.inputs.project_name
  environment       = local.env_config.inputs.environment
  aws_region        = local.env_config.inputs.aws_region
  tf_state_bucket   = get_env("TF_STATE_BUCKET", "fru-terraform-state-${get_aws_account_id()}")
  vpc_cidr          = local.env_config.inputs.vpc_cidr
  availability_zones = local.env_config.inputs.availability_zones
  
  enable_nat_gateway         = local.env_config.inputs.enable_nat_gateway
  enable_bedrock_vpc_endpoint = local.env_config.inputs.enable_bedrock_vpc_endpoint
  
  db_password = local.env_config.inputs.db_password
  db_username = local.env_config.inputs.db_username
  
  aurora_database_name = local.env_config.inputs.aurora_database_name
  aurora_min_capacity  = local.env_config.inputs.aurora_min_capacity
  aurora_max_capacity  = local.env_config.inputs.aurora_max_capacity
  aurora_instance_count = local.env_config.inputs.aurora_instance_count
  
  enable_iam_auth = local.env_config.inputs.enable_iam_auth
  deletion_protection = local.env_config.inputs.deletion_protection
  
  bedrock_inference_profile_id = local.env_config.inputs.bedrock_inference_profile_id
  
  tags = local.env_config.inputs.tags
}

