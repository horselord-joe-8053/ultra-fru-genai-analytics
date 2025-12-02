# Secrets Manager Module

Stores sensitive credentials in AWS Secrets Manager instead of environment variables.

## Security Best Practices

- **Never store secrets in environment variables** - Use Secrets Manager
- Secrets are encrypted at rest using KMS
- Access controlled via IAM policies
- Automatic rotation support (can be configured separately)

## Secrets Created

1. **OpenAI API Key**: For embedding generation
2. **Database Password**: Aurora PostgreSQL master password
3. **Database Username** (optional): If not using IAM database authentication

## Usage

```hcl
module "secrets_manager" {
  source = "../../modules/secrets-manager"

  project_name     = "fru"
  environment      = "prod"
  openai_api_key   = "sk-..." # From variable or terraform.tfvars
  db_password      = "SecurePassword123!" # From variable or terraform.tfvars
  db_username      = "fru_user"
  
  create_db_username_secret = false # Set to true if not using IAM auth

  tags = {
    Project = "FRU-GenAI"
  }
}
```

## Accessing Secrets in ECS

Secrets are referenced in the ECS task definition using the `secrets` block:

```json
{
  "secrets": [
    {
      "name": "OPENAI_API_KEY",
      "valueFrom": "arn:aws:secretsmanager:region:account:secret:name"
    },
    {
      "name": "PGPASSWORD",
      "valueFrom": "arn:aws:secretsmanager:region:account:secret:name"
    }
  ]
}
```

## Outputs

- `openai_secret_arn` - Use in IAM policies and ECS task definition
- `db_password_secret_arn` - Use in IAM policies and ECS task definition

