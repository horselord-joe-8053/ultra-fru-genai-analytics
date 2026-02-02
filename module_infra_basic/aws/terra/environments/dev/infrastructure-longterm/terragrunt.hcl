# Long-term layer (Secrets Manager only) for dev.
# Not destroyed by main teardown; see docs/learned/TERRA_LEARNED.md Option B.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "component" {
  path = "${get_terragrunt_dir()}/../../_component/longterm-base.hcl"
}
