# OpenAI API Key Secret
resource "aws_secretsmanager_secret" "openai_key" {
  name        = "${var.project_name}/${var.environment}/openai-api-key"
  description = "OpenAI API key for embeddings"

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-openai-key"
    }
  )
}

# OpenAI API Key Secret Version
resource "aws_secretsmanager_secret_version" "openai_key" {
  secret_id = aws_secretsmanager_secret.openai_key.id
  secret_string = jsonencode({
    api_key = var.openai_api_key
  })
}

# Database Password Secret
resource "aws_secretsmanager_secret" "db_password" {
  name        = "${var.project_name}/${var.environment}/aurora-db-password"
  description = "Aurora PostgreSQL master password"

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-db-password"
    }
  )
}

# Database Password Secret Version
# JSON format required for RDS Data API (used by post_create_pgvector.sh)
resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = jsonencode({
    # Include both username and password so this secret can be used with the RDS Data API
    username = var.db_username
    password = var.db_password
  })
}

# Database Password Secret (Plain String) - for ECS task definitions
# ECS doesn't support JSON key extraction, so we need a separate plain string secret
resource "aws_secretsmanager_secret" "db_password_plain" {
  name        = "${var.project_name}/${var.environment}/aurora-db-password-plain"
  description = "Aurora PostgreSQL master password (plain string for ECS)"

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-db-password-plain"
    }
  )
}

# Database Password Secret Version (Plain String)
# Plain string format required for ECS task definition secrets
resource "aws_secretsmanager_secret_version" "db_password_plain" {
  secret_id     = aws_secretsmanager_secret.db_password_plain.id
  secret_string = var.db_password  # Plain string, not JSON
}

# Database Username Secret (optional, if not using IAM auth)
resource "aws_secretsmanager_secret" "db_username" {
  count       = var.create_db_username_secret ? 1 : 0
  name        = "${var.project_name}/${var.environment}/aurora-db-username"
  description = "Aurora PostgreSQL master username"

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-db-username"
    }
  )
}

# Database Username Secret Version
# Store as plain string (not JSON) for ECS task definition compatibility
resource "aws_secretsmanager_secret_version" "db_username" {
  count       = var.create_db_username_secret ? 1 : 0
  secret_id   = aws_secretsmanager_secret.db_username[0].id
  secret_string = var.db_username
}

