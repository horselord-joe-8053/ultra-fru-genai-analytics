# Frontend layer base template
# Inputs (and dependencies) are in child terragrunt.hcl

locals {
  env_config = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env_name   = basename(dirname(get_terragrunt_dir()))
  layer_name = basename(get_terragrunt_dir())
}

terraform {
  source = "${get_terragrunt_dir()}/../../../modules//frontend"
}

download_dir = "${get_path_to_repo_root()}/temp_terra_gen/.terragrunt-cache/${local.env_name}/${local.layer_name}"
