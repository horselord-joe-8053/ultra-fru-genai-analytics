# ALB Module

Creates an Application Load Balancer for exposing ECS services to the internet.

## Features

- Application Load Balancer in public subnets
- HTTP listener (redirects to HTTPS if certificate provided)
- HTTPS listener (if certificate ARN provided)
- Target group for ECS tasks
- Health checks

## Usage

```hcl
module "alb" {
  source = "../../modules/alb"

  project_name      = "fru"
  environment       = "prod"
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids

  target_port        = 5000
  health_check_path  = "/health"
  certificate_arn    = "arn:aws:acm:us-east-1:123456789012:certificate/xxx" # Optional

  tags = {
    Project = "FRU-GenAI"
  }
}
```

## Outputs

- `alb_dns_name` - Use this for your API endpoint
- `target_group_arn` - Use in ECS module
- `security_group_id` - Use in ECS module for ingress rule

