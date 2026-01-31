# ECS Module - Consolidated
# Combines: ECS Cluster/Service + ALB + Frontend (for ECS deployments)

# ============================================================================
# ALB Module
# ============================================================================

module "alb" {
  source = "../alb"

  project_name      = var.project_name
  environment       = var.environment
  vpc_id            = var.vpc_id
  public_subnet_ids = var.public_subnet_ids

  target_port       = var.container_port
  health_check_path = var.health_check_path
  certificate_arn   = var.certificate_arn
  deletion_protection = var.deletion_protection

  tags = var.tags
}

# ============================================================================
# ECS Resources
# ============================================================================

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-${var.environment}-cluster"

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-cluster"
    }
  )
}

# Security Group for ECS Tasks
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.project_name}-${var.environment}-ecs-tasks-sg"
  description = "Security group for ECS tasks"
  vpc_id      = var.vpc_id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-ecs-tasks-sg"
    }
  )
}

# Security Group Rule: Allow inbound from ALB
# ALB is always created in this consolidated module, so this rule is always needed.
resource "aws_security_group_rule" "ecs_from_alb" {
  type                     = "ingress"
  from_port                = var.container_port
  to_port                  = var.container_port
  protocol                 = "tcp"
  source_security_group_id = module.alb.security_group_id
  security_group_id        = aws_security_group.ecs_tasks.id
  description              = "Allow inbound from ALB"
}

# ECS Task Definition
resource "aws_ecs_task_definition" "fru_api" {
  family                   = "${var.project_name}-${var.environment}-api"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory

  # Execution role (for ECR, CloudWatch, Secrets Manager at task start)
  execution_role_arn = var.ecs_task_execution_role_arn

  # Runtime role (for Bedrock, Secrets Manager at runtime, RDS IAM auth)
  task_role_arn = var.ecs_task_runtime_role_arn

  container_definitions = jsonencode([
    {
      name  = var.container_name
      image = var.container_image

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      # Environment variables (non-sensitive)
      environment = [
        {
          name  = "PGHOST"
          value = var.aurora_endpoint
        },
        {
          name  = "PGPORT"
          value = tostring(var.aurora_port)
        },
        {
          name  = "PGDATABASE"
          value = var.aurora_database_name
        },
        {
          name  = "AWS_REGION"
          value = var.aws_region
        },
        # Bedrock configuration (inference profile is primary, model ID is fallback)
        {
          name  = "AWS_BEDROCK_INFERENCE_PROFILE_ID"
          value = var.bedrock_inference_profile_id
        },
        {
          name  = "AWS_BEDROCK_MODEL_ID"
          value = var.aws_bedrock_model_id
        },
        {
          name  = "LOG_LEVEL"
          value = var.log_level
        },
        {
          name  = "ALLOWED_ORIGINS"
          value = var.allowed_origins
        },
        {
          name  = "OPENAI_EMBED_MODEL"
          value = var.openai_embed_model
        },
        {
          name  = "USE_AGENT_QUERY"
          value = var.use_agent_query
        },
        {
          name  = "ENABLE_ANALYTICS_SCHEDULER"
          value = var.enable_analytics_scheduler
        },
        {
          name  = "ANALYTICS_SCHEDULER_INTERVAL_SECONDS"
          value = var.analytics_scheduler_interval_seconds
        },
        {
          name  = "SPARK_HOME"
          # Default to /opt/spark if spark_home is empty (handles case where env var is set to empty string)
          value = var.spark_home != "" ? var.spark_home : "/opt/spark"
        },
        {
          name  = "DELTA_TABLE_PATH"
          # For AWS: use S3 path (s3://bucket/delta/fru_sales)
          # For local: use local path (data/delta/fru_sales)
          # The scheduler will detect S3 vs local based on path prefix
          value = var.delta_table_path
        },
        {
          name  = "DELTA_LAKE_PACKAGE"
          # Delta Lake package (Maven coordinates) - required for Spark jobs
          # Format: io.delta:delta-spark_{SCALA_VERSION}:{DELTA_VERSION}
          # Standard: io.delta:delta-spark_2.13:4.0.0 (compatible with Spark 4.0.1)
          value = var.delta_lake_package
        },
        {
          name  = "CONTAINER_TYPE"
          # Container type (e.g., 'ecs', 'eks') - used by analytics scheduler
          # to determine if S3A packages and configuration are needed
          # Local deployments don't set this (will be empty/None)
          value = var.container_type
        },
        {
          name  = "CONTAINER_IMAGE"
          # Container image URI (for /version endpoint)
          # Format: registry/repo:tag (e.g., 744139897900.dkr.ecr.us-east-1.amazonaws.com/fru-api:fru_dev_20260124_6b038d3_dirty_20260125_122640)
          value = var.container_image
        }
      ]

      # Secrets (sensitive - from Secrets Manager)
      # Use plain string secrets for ECS (ECS doesn't support JSON key extraction)
      secrets = concat(
        [
          {
            name      = "OPENAI_API_KEY"
            valueFrom = var.openai_secret_plain_arn  # Use plain string secret
          },
          {
            name      = "PGPASSWORD"
            # Plain string secret (ECS doesn't support :json-key: syntax)
            valueFrom = var.db_password_plain_secret_arn
          }
        ],
        var.db_username_secret_arn != null ? [
          {
            name      = "PGUSER"
            valueFrom = var.db_username_secret_arn
          }
        ] : []
      )

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      healthCheck = {
        # Use Python for health check (curl is not available in python:3.11-slim)
        command     = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:${var.container_port}/health').read()\" || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-api-task"
    }
  )
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project_name}-${var.environment}"
  retention_in_days = var.log_retention_days

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-ecs-logs"
    }
  )
}

# ECS Service
resource "aws_ecs_service" "fru_api" {
  name            = "${var.project_name}-${var.environment}-api-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.fru_api.arn
  desired_count   = var.ecs_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  # Load balancer configuration (ALB is always created in this consolidated module)
  load_balancer {
    target_group_arn = module.alb.target_group_arn
    container_name   = var.container_name
    container_port   = var.container_port
  }

  # Service discovery (optional)
  dynamic "service_registries" {
    for_each = var.service_registry_arn != null ? [1] : []
    content {
      registry_arn = var.service_registry_arn
    }
  }

  # Deployment configuration (top-level attributes in AWS provider v5)
  deployment_maximum_percent         = var.deployment_maximum_percent
  deployment_minimum_healthy_percent = var.deployment_minimum_percent

  # Enable ECS Exec (for debugging)
  enable_execute_command = var.enable_execute_command

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-api-service"
    }
  )

  depends_on = [
    aws_cloudwatch_log_group.ecs
  ]
}

# ============================================================================
# Security Group Rule: Update Aurora security group to allow ECS tasks
# ============================================================================

resource "aws_security_group_rule" "aurora_from_ecs" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ecs_tasks.id
  security_group_id        = var.aurora_security_group_id
  description              = "PostgreSQL from ECS tasks"
}

# ============================================================================
# Frontend Module
# ============================================================================

module "frontend" {
  source = "../frontend"

  project_name = var.project_name
  environment  = var.environment
  container_type = var.container_type # Pass container_type to create separate frontend instances

  enable_versioning = var.enable_frontend_versioning
  cloudfront_price_class = var.cloudfront_price_class
  certificate_arn   = var.frontend_certificate_arn
  api_origin_id     = var.frontend_api_origin_id
  alb_dns_name      = module.alb.alb_dns_name # Pass ALB DNS for API origin

  tags = var.tags
}

