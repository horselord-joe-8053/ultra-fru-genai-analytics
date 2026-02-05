output "openai_secret_arn" {
  description = "ARN of OpenAI API key secret (JSON format - for backward compatibility)"
  value       = aws_secretsmanager_secret.openai_key.arn
}

output "openai_secret_name" {
  description = "Name of OpenAI API key secret"
  value       = aws_secretsmanager_secret.openai_key.name
}

output "openai_secret_plain_arn" {
  description = "ARN of OpenAI API key secret (plain string for ECS)"
  value       = aws_secretsmanager_secret.openai_key_plain.arn
}

output "db_password_secret_arn" {
  description = "ARN of database password secret"
  value       = aws_secretsmanager_secret.db_password.arn
}

output "db_password_secret_name" {
  description = "Name of database password secret"
  value       = aws_secretsmanager_secret.db_password.name
}

output "db_password_plain_secret_arn" {
  description = "ARN of database password secret (plain string for ECS)"
  value       = aws_secretsmanager_secret.db_password_plain.arn
}

output "db_username_secret_arn" {
  description = "ARN of database username secret (if created)"
  value       = var.create_db_username_secret ? aws_secretsmanager_secret.db_username[0].arn : null
}

output "db_username_secret_name" {
  description = "Name of database username secret (if created)"
  value       = var.create_db_username_secret ? aws_secretsmanager_secret.db_username[0].name : null
}

