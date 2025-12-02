# Aurora Module

Creates an Aurora PostgreSQL cluster with pgvector support, IAM authentication, and security best practices.

## Features

- Aurora PostgreSQL Serverless v2 (scales automatically)
- pgvector extension support (via parameter group)
- IAM database authentication (recommended)
- Encryption at rest
- CloudWatch Logs integration
- Security group restricting access to ECS tasks only

## Usage

```hcl
module "aurora" {
  source = "../../modules/aurora"

  project_name         = "fru"
  environment          = "prod"
  vpc_id               = module.vpc.vpc_id
  private_subnet_ids   = module.vpc.private_subnet_ids
  ecs_security_group_id = module.ecs.security_group_id

  database_name    = "fru_db"
  master_username  = "fru_user"
  master_password  = "ChangeMe123!" # Use Secrets Manager in production

  min_capacity = 0.5
  max_capacity = 16

  enable_iam_auth = true
  deletion_protection = true # Enable in prod

  tags = {
    Project = "FRU-GenAI"
  }
}
```

## Security Notes

1. **IAM Database Authentication**: When enabled, ECS tasks can authenticate using IAM roles instead of passwords. This is more secure than password-based auth.

2. **Secrets Manager**: Store `master_password` in Secrets Manager and reference it in the module. Never hardcode passwords.

3. **After Deployment**: Run SQL to enable pgvector extension:
   ```sql
   CREATE EXTENSION IF NOT EXISTS vector;
   ```

4. **IAM Database User Setup** (if using IAM auth):
   ```sql
   CREATE USER fru_app_user;
   GRANT rds_iam TO fru_app_user;
   GRANT ALL ON DATABASE fru_db TO fru_app_user;
   ```

## Outputs

- `cluster_endpoint` - Cluster endpoint (use this for PGHOST)
- `cluster_reader_endpoint` - Reader endpoint for read replicas
- `security_group_id` - Security group ID (needed for ECS)

