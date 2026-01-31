output "cluster_id" {
  description = "ECS cluster ID"
  value       = aws_ecs_cluster.main.id
}

output "cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.fru_api.name
}

output "service_id" {
  description = "ECS service ID"
  value       = aws_ecs_service.fru_api.id
}

output "task_definition_arn" {
  description = "Task definition ARN"
  value       = aws_ecs_task_definition.fru_api.arn
}

output "security_group_id" {
  description = "Security group ID for ECS tasks"
  value       = aws_security_group.ecs_tasks.id
}

output "log_group_name" {
  description = "CloudWatch log group name"
  value       = aws_cloudwatch_log_group.ecs.name
}

# ALB Outputs
output "alb_dns_name" {
  description = "ALB DNS name"
  value       = module.alb.alb_dns_name
}

output "alb_arn" {
  description = "ALB ARN"
  value       = module.alb.alb_arn
}

# Frontend Outputs
output "cloudfront_domain_name" {
  description = "CloudFront domain name"
  value       = module.frontend.cloudfront_domain_name
}

output "s3_bucket_id" {
  description = "S3 bucket ID for frontend"
  value       = module.frontend.s3_bucket_id
}

