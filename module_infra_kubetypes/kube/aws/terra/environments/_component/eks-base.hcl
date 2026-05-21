# EKS layer base template
# NOTE: This file does NOT include root or env - that's done by the child terragrunt.hcl
# Uses read_terragrunt_config() workaround to access env.hcl

locals {
  env_config = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env_name = basename(dirname(get_terragrunt_dir()))
  layer_name = basename(get_terragrunt_dir())
}

terraform {
  source = "${get_terragrunt_dir()}/../../../modules//root_eks"
}

download_dir = "${get_path_to_repo_root()}/temp_terra_gen/.terragrunt-cache/${local.env_name}/${local.layer_name}"

# Note: All inputs must be in child files because:
# 1. Dependencies must be defined in child files (not included files)
# 2. Inputs that reference dependencies must be in the same file as the dependency block
# This base template only provides terraform source and download_dir

