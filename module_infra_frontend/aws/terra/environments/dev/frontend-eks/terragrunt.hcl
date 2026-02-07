# Frontend (EKS) layer for dev - S3 + CloudFront, depends on EKS (ALB DNS from Ingress/var)
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
  paths = ["${get_terragrunt_dir()}/../../../../../../module_infra_kubetypes/kube/aws/terra/environments/${local.env_name}/eks"]
}

dependency "app" {
  config_path = "${get_terragrunt_dir()}/../../../../../../module_infra_kubetypes/kube/aws/terra/environments/${local.env_name}/eks"

  mock_outputs = {
    # EKS ALB DNS comes from Kubernetes Ingress; use placeholder for plan when EKS not applied
    alb_dns_name = "k8s-placeholder.elb.us-east-1.amazonaws.com"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init", "refresh", "state", "destroy", "import"]
}

# alb_dns_name for EKS: from Kubernetes Ingress after deploy (kubectl get ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
# Set EKS_ALB_DNS_NAME env var after Ingress is created, or use placeholder for plan
inputs = {
  aws_region            = local.env_config.inputs.aws_region
  project_name          = local.env_config.inputs.project_name
  environment           = local.env_config.inputs.environment
  container_type        = "eks"
  alb_dns_name          = get_env("EKS_ALB_DNS_NAME", "k8s-placeholder.elb.us-east-1.amazonaws.com")
  enable_versioning     = false
  cloudfront_price_class = "PriceClass_100"
  certificate_arn       = null
  api_origin_id         = "ALB-${local.env_config.inputs.project_name}-${local.env_config.inputs.environment}-eks"
  tags                  = local.env_config.inputs.tags
}
