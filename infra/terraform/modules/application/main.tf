# Application Layer
# Combines: ECS, ALB, Frontend

# ALB Module
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

# ECS Module
module "ecs" {
  source = "../ecs"

  project_name                = var.project_name
  environment                 = var.environment
  aws_region                  = var.aws_region
  vpc_id                      = var.vpc_id
  private_subnet_ids          = var.private_subnet_ids
  ecs_task_execution_role_arn = var.ecs_task_execution_role_arn
  ecs_task_runtime_role_arn   = var.ecs_task_runtime_role_arn

  aurora_endpoint             = var.aurora_endpoint
  aurora_port                 = var.aurora_port
  aurora_database_name        = var.aurora_database_name
  openai_secret_arn           = var.openai_secret_arn
  db_password_secret_arn       = var.db_password_secret_arn        # JSON format (for RDS Data API)
  db_password_plain_secret_arn = var.db_password_plain_secret_arn # Plain string (for ECS)
  db_username_secret_arn       = var.db_username_secret_arn

  container_image = var.container_image
  container_name  = var.container_name
  container_port  = var.container_port

  task_cpu    = var.ecs_task_cpu
  task_memory = var.ecs_task_memory

  desired_count = var.ecs_desired_count
  bedrock_model_id = var.bedrock_model_id

  alb_target_group_arn  = module.alb.target_group_arn
  alb_security_group_id = module.alb.security_group_id

  enable_container_insights = var.enable_container_insights
  enable_execute_command    = var.enable_execute_command
  log_retention_days        = var.log_retention_days

  tags = var.tags
}

# Update Aurora security group to allow ECS tasks
resource "aws_security_group_rule" "aurora_from_ecs" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = module.ecs.security_group_id
  security_group_id        = var.aurora_security_group_id
  description              = "PostgreSQL from ECS tasks"
}

# Frontend Module
module "frontend" {
  source = "../frontend"

  project_name = var.project_name
  environment  = var.environment

  enable_versioning = var.enable_frontend_versioning
  cloudfront_price_class = var.cloudfront_price_class
  certificate_arn   = var.frontend_certificate_arn
  api_origin_id     = var.frontend_api_origin_id

  tags = var.tags
}

