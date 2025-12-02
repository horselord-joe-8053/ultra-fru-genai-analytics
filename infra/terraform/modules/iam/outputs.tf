output "ecs_task_execution_role_arn" {
  description = "ARN of the ECS task execution role"
  value       = aws_iam_role.ecs_task_execution.arn
}

output "ecs_task_execution_role_name" {
  description = "Name of the ECS task execution role"
  value       = aws_iam_role.ecs_task_execution.name
}

output "ecs_task_runtime_role_arn" {
  description = "ARN of the ECS task runtime role"
  value       = aws_iam_role.ecs_task_runtime.arn
}

output "ecs_task_runtime_role_name" {
  description = "Name of the ECS task runtime role"
  value       = aws_iam_role.ecs_task_runtime.name
}

