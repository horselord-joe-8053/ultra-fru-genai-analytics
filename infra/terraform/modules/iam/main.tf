# ============================================================================
# ECS Task Execution Role
# ============================================================================
# This role is used by the ECS service to:
# - Pull images from ECR
# - Write logs to CloudWatch
# - Pull secrets from Secrets Manager (for task definition)

resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project_name}-${var.environment}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-ecs-task-execution-role"
    }
  )
}

# Attach AWS managed policy for ECS task execution
resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Additional policy for Secrets Manager access (for task definition secrets)
resource "aws_iam_role_policy" "ecs_task_execution_secrets" {
  name = "${var.project_name}-${var.environment}-ecs-execution-secrets"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = concat(
          [
            var.openai_secret_arn,            # JSON format (for backward compatibility)
            var.openai_secret_plain_arn,      # Plain string (for ECS)
            var.db_password_secret_arn,        # JSON format (for RDS Data API)
            var.db_password_plain_secret_arn   # Plain string (for ECS)
          ],
          var.db_username_secret_arn != "" ? [var.db_username_secret_arn] : []
        )
      }
    ]
  })
}

# ============================================================================
# ECS Task Runtime Role
# ============================================================================
# This role is assumed by the running container and used to:
# - Invoke Bedrock models
# - Read secrets from Secrets Manager (at runtime)
# - Connect to Aurora using IAM database authentication (if enabled)

resource "aws_iam_role" "ecs_task_runtime" {
  name = "${var.project_name}-${var.environment}-ecs-task-runtime-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-ecs-task-runtime-role"
    }
  )
}

# Policy for Bedrock access
resource "aws_iam_role_policy" "ecs_task_runtime_bedrock" {
  name = "${var.project_name}-${var.environment}-ecs-runtime-bedrock"
  role = aws_iam_role.ecs_task_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        # Allow both model ARNs and inference profile ARNs
        # Inference profiles are referenced as: arn:aws:bedrock:region:account-id:inference-profile/profile-id
        Resource = concat(
          var.bedrock_model_arns,
          var.bedrock_inference_profile_arns != null ? var.bedrock_inference_profile_arns : []
        )
      }
    ]
  })
}

# Policy for Secrets Manager access (at runtime)
resource "aws_iam_role_policy" "ecs_task_runtime_secrets" {
  name = "${var.project_name}-${var.environment}-ecs-runtime-secrets"
  role = aws_iam_role.ecs_task_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = concat(
          [
            var.openai_secret_arn,            # JSON format (for backward compatibility)
            var.openai_secret_plain_arn,      # Plain string (for ECS)
            var.db_password_secret_arn,        # JSON format (for RDS Data API)
            var.db_password_plain_secret_arn   # Plain string (for ECS)
          ],
          var.db_username_secret_arn != "" ? [var.db_username_secret_arn] : []
        )
      }
    ]
  })
}

# Policy for IAM database authentication (if using Aurora IAM auth)
resource "aws_iam_role_policy" "ecs_task_runtime_rds_iam" {
  count = var.enable_rds_iam_auth ? 1 : 0
  name  = "${var.project_name}-${var.environment}-ecs-runtime-rds-iam"
  role  = aws_iam_role.ecs_task_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "rds-db:connect"
        ]
        Resource = var.rds_db_resource_arn
      }
    ]
  })
}

# Policy for S3 access (for Delta tables and raw data)
# This allows ECS tasks to read/write analytics data in S3
# We always create this policy since we always create the S3 bucket in the infrastructure layer
resource "aws_iam_role_policy" "ecs_task_runtime_s3" {
  name  = "${var.project_name}-${var.environment}-ecs-runtime-s3"
  role  = aws_iam_role.ecs_task_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = var.s3_data_bucket_arn != "" ? [
          var.s3_data_bucket_arn,
          "${var.s3_data_bucket_arn}/*"
        ] : []
      }
    ]
  })
}

