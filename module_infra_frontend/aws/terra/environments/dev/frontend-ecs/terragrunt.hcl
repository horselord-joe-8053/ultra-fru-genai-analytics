# Frontend (ECS) layer for dev - S3 + CloudFront, depends on ECS for ALB DNS
include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "component" {
  path = "${get_terragrunt_dir()}/../../_component/frontend-base.hcl"
}

locals {
  env_config = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env_name   = basename(dirname(get_terragrunt_dir()))
}

dependencies {
  paths = ["${get_terragrunt_dir()}/../../../../../../module_infra_kubetypes/nonkube/aws/terra/environments/${local.env_name}/ecs"]
}

dependency "app" {
  config_path = "${get_terragrunt_dir()}/../../../../../../module_infra_kubetypes/nonkube/aws/terra/environments/${local.env_name}/ecs"

  mock_outputs = {
    alb_dns_name = "alb-dev-ecs-placeholder.elb.us-east-1.amazonaws.com"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init", "refresh", "state", "destroy", "import"]
}

inputs = {
  aws_region            = local.env_config.inputs.aws_region
  project_name          = local.env_config.inputs.project_name
  environment           = local.env_config.inputs.environment
  container_type        = "ecs"
  alb_dns_name          = try(dependency.app.outputs.alb_dns_name, "alb-dev-ecs-placeholder.elb.us-east-1.amazonaws.com")
  enable_versioning     = false
  cloudfront_price_class = "PriceClass_100"
  certificate_arn       = null
  api_origin_id         = "ALB-${local.env_config.inputs.project_name}-${local.env_config.inputs.environment}-ecs"
  tags                  = local.env_config.inputs.tags
}
