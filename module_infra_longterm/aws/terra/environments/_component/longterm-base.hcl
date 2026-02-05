# Long-term layer base: Secrets Manager only.
# This layer is NOT destroyed by main teardown (see docs/learned/TERRA_LEARNED.md Option B).
# Deploy order: apply this layer first, then infrastructure (which reads secret ARNs via remote_state).

locals {
  env_config = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env_name   = basename(dirname(get_terragrunt_dir()))
  layer_name = basename(get_terragrunt_dir())
}

terraform {
  source = "${get_terragrunt_dir()}/../../../modules//secrets-manager"
}

download_dir = "${get_path_to_repo_root()}/temp_terra_gen/.terragrunt-cache/${local.env_name}/${local.layer_name}"

inputs = {
  project_name              = local.env_config.inputs.project_name
  environment               = local.env_config.inputs.environment
  aws_region                = local.env_config.inputs.aws_region
  openai_api_key            = local.env_config.inputs.openai_api_key
  db_password               = local.env_config.inputs.db_password
  db_username               = local.env_config.inputs.db_username
  create_db_username_secret = true
  tags                      = local.env_config.inputs.tags
}
