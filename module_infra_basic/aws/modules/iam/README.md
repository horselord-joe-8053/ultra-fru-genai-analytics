# IAM Module

Creates IAM roles for ECS tasks with proper separation of execution and runtime permissions.

## Security Best Practices

This module implements the **principle of least privilege** by separating:

1. **Execution Role**: Used by ECS service to start tasks
   - ECR: Pull container images
   - CloudWatch: Write logs
   - Secrets Manager: Read secrets for task definition

2. **Runtime Role**: Assumed by running containers
   - Bedrock: Invoke models
   - Secrets Manager: Read secrets at runtime
   - RDS IAM Auth: Connect to Aurora (if enabled)

## Usage

```hcl
module "iam" {
  source = "../../modules/iam"

  project_name            = "fru"
  environment             = "prod"
  openai_secret_arn       = module.secrets_manager.openai_secret_arn
  db_password_secret_arn  = module.secrets_manager.db_password_secret_arn
  
  enable_rds_iam_auth = true
  rds_db_resource_arn  = "arn:aws:rds-db:us-east-1:999999999999:dbuser:cluster-xxx/fru_app_user"

  tags = {
    Project = "FRU-GenAI"
  }
}
```

## Outputs

- `ecs_task_execution_role_arn` - Use in ECS task definition
- `ecs_task_runtime_role_arn` - Use in ECS task definition

