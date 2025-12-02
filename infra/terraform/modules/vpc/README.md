# VPC Module

Creates a VPC with public and private subnets, NAT gateways, and optional VPC endpoints for Bedrock.

## Features

- VPC with DNS support
- Public subnets (for ALB, NAT gateways)
- Private subnets (for ECS tasks, Aurora)
- Internet Gateway
- NAT Gateways (optional, for private subnet internet access)
- VPC Endpoint for Bedrock (optional but recommended for security)

## Usage

```hcl
module "vpc" {
  source = "../../modules/vpc"

  project_name      = "fru"
  environment       = "prod"
  aws_region        = "us-east-1"
  vpc_cidr          = "10.0.0.0/16"
  availability_zones = ["us-east-1a", "us-east-1b"]
  
  enable_nat_gateway         = true
  enable_bedrock_vpc_endpoint = true
  
  tags = {
    Project = "FRU-GenAI"
  }
}
```

## Outputs

- `vpc_id` - VPC ID
- `public_subnet_ids` - List of public subnet IDs
- `private_subnet_ids` - List of private subnet IDs
- `vpc_endpoint_security_group_id` - Security group for VPC endpoints

