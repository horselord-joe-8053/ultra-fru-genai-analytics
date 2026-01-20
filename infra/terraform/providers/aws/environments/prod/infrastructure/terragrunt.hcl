# Infrastructure layer for prod environment
# This file includes root and component base (non-nested includes)

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "component" {
  path = "${get_terragrunt_dir()}/../../_component/infrastructure-base.hcl"
}

# Prod-specific overrides (if any)
# Most values come from env.hcl via the component base template

