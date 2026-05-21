# root_ecs

**Root/composition module** for the **ecs** Terragrunt layer. One `terragrunt apply` or `terragrunt destroy` for the ecs layer runs Terraform with this directory as the root.

## Why "root_"?

Unlike leaf modules (e.g. `alb/`), this module is the **entry point** for the whole ECS layer: cluster, service, task definition, and ALB (via `../alb`). Frontend (S3/CloudFront) lives in a separate layer (`frontend-ecs` in module_infra_basic). The `root_` prefix marks this as the layer root.

## What it creates

Creates an ECS Fargate service with proper security practices: secrets from Secrets Manager, separate execution/runtime roles.

## Security Best Practices

1. **Secrets Management**: Sensitive values (OPENAI_API_KEY, PGPASSWORD) come from Secrets Manager, not environment variables
2. **Role Separation**: Uses separate execution and runtime roles
3. **Private Subnets**: Tasks run in private subnets only
4. **Security Groups**: Restricted ingress (only from ALB if configured)

## Usage

Used by Terragrunt as the root for the ecs layer (`source = ".../modules//root_ecs"`). If calling as a module:

```hcl
module "ecs" {
  source = "../../modules/root_ecs"

  project_name                = "fru"
  environment                 = "prod"
  aws_region                  = "us-east-1"
  vpc_id                      = module.vpc.vpc_id
  private_subnet_ids          = module.vpc.private_subnet_ids
  ecs_task_execution_role_arn = module.iam.ecs_task_execution_role_arn
  ecs_task_runtime_role_arn   = module.iam.ecs_task_runtime_role_arn

  aurora_endpoint        = module.aurora.cluster_endpoint
  aurora_database_name   = module.aurora.database_name
  openai_secret_arn      = module.secrets_manager.openai_secret_arn
  db_password_secret_arn  = module.secrets_manager.db_password_secret_arn

  container_image = "999999999999.dkr.ecr.us-east-1.amazonaws.com/fru-api:latest"

  desired_count = 2
  task_cpu      = 512
  task_memory   = 1024

  alb_target_group_arn  = module.alb.target_group_arn
  alb_security_group_id = module.alb.security_group_id

  tags = {
    Project = "FRU-GenAI"
  }
}
```

## Environment Variables vs Secrets

**Environment Variables** (non-sensitive):
- `PGHOST` - Database endpoint (public knowledge)
- `PGPORT` - Database port (standard)
- `PGDATABASE` - Database name (not sensitive)
- `AWS_REGION` - AWS region
- `BEDROCK_MODEL_ID` - Model identifier

**Secrets** (from Secrets Manager):
- `OPENAI_API_KEY` - API key (sensitive)
- `PGPASSWORD` - Database password (sensitive)
- `PGUSER` - Database username (optional, if not using IAM auth)

## Outputs

- `cluster_id` - ECS cluster ID
- `service_name` - ECS service name
- `security_group_id` - Security group ID (needed for Aurora ingress rule)

