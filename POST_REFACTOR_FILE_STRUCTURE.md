# Post-Refactor File Structure for ECS and EKS

## BEFORE (Current Structure):

```
infra/terraform/
├── modules/
│   ├── ecs/                          # Base ECS resources only
│   │   ├── main.tf                   # ECS cluster, service, task definition
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── README.md
│   │
│   ├── application-ecs/              # Composite: ECS + ALB + Frontend
│   │   ├── main.tf                   # Calls: module "ecs", module "alb", module "frontend"
│   │   ├── variables.tf
│   │   └── outputs.tf
│   │
│   ├── eks/                          # Base EKS resources only
│   │   ├── main.tf                   # EKS cluster, node groups, OIDC
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── README.md
│   │
│   └── application-eks/              # Composite: EKS + Frontend
│       ├── main.tf                   # Calls: module "eks", module "frontend"
│       ├── variables.tf
│       └── outputs.tf
│
└── environments/
    ├── dev/
    │   ├── application-ecs/         # Points to modules/application-ecs
    │   │   └── terragrunt.hcl
    │   └── application-eks/         # Points to modules/application-eks
    │       └── terragrunt.hcl
    │
    └── prod/
        ├── application/              # Points to modules/application (OLD, inconsistent)
        │   └── terragrunt.hcl
        └── eks/                      # Points to modules/eks (OLD, missing frontend)
            └── terragrunt.hcl
```

## AFTER (Post-Refactor Structure):

```
infra/terraform/
├── modules/
│   ├── ecs/                          # ✅ CONSOLIDATED: ECS + ALB + Frontend
│   │   ├── main.tf                   # Contains:
│   │   │                             #   - ECS resources (inline, from old modules/ecs/)
│   │   │                             #   - module "alb" { source = "../alb" }
│   │   │                             #   - module "frontend" { source = "../frontend" }
│   │   │                             #   - Security group rules connecting them
│   │   ├── variables.tf              # Merged from modules/ecs/ + modules/application-ecs/
│   │   ├── outputs.tf                # Merged from modules/ecs/ + modules/application-ecs/
│   │   └── README.md                 # Updated documentation
│   │
│   ├── eks/                          # ✅ CONSOLIDATED: EKS + Frontend
│   │   ├── main.tf                   # Contains:
│   │   │                             #   - EKS resources (already there, from old modules/eks/)
│   │   │                             #   - module "frontend" { source = "../frontend" }
│   │   ├── variables.tf              # Merged from modules/eks/ + modules/application-eks/
│   │   ├── outputs.tf                # Merged from modules/eks/ + modules/application-eks/
│   │   └── README.md                 # Updated documentation
│   │
│   ├── alb/                          # ✅ UNCHANGED (used by ecs module)
│   ├── frontend/                     # ✅ UNCHANGED (used by both ecs and eks modules)
│   └── ... (other modules unchanged)
│
└── environments/
    ├── dev/
    │   ├── ecs/                      # ✅ RENAMED from application-ecs
    │   │   └── terragrunt.hcl        # source = "../../modules//ecs"
    │   └── eks/                       # ✅ RENAMED from application-eks
    │       └── terragrunt.hcl         # source = "../../modules//eks"
    │
    └── prod/
        ├── ecs/                      # ✅ RENAMED from application (now consistent with dev)
        │   └── terragrunt.hcl        # source = "../../modules//ecs"
        └── eks/                       # ✅ UPDATED (now includes frontend like dev)
            └── terragrunt.hcl         # source = "../../modules//eks"
```

## Key Changes Summary:

### Modules Directory:
- ❌ **DELETED**: `modules/application-ecs/` → ✅ **MERGED INTO**: `modules/ecs/`
- ❌ **DELETED**: `modules/application-eks/` → ✅ **MERGED INTO**: `modules/eks/`
- ✅ **UPDATED**: `modules/ecs/` (now includes ALB + Frontend modules)
- ✅ **UPDATED**: `modules/eks/` (now includes Frontend module)

### Environment Directories:
- ❌ **DELETED**: `environments/dev/application-ecs/` → ✅ **RENAMED TO**: `environments/dev/ecs/`
- ❌ **DELETED**: `environments/dev/application-eks/` → ✅ **RENAMED TO**: `environments/dev/eks/`
- ❌ **DELETED**: `environments/prod/application/` → ✅ **RENAMED TO**: `environments/prod/ecs/`
- ✅ **UPDATED**: `environments/prod/eks/` (now includes frontend configuration, consistent with dev)

## Detailed Module Contents:

### `modules/ecs/main.tf` (Post-Refactor):

```terraform
# ECS Module - Consolidated
# Combines: ECS Cluster/Service + ALB + Frontend

# ============================================================================
# ECS Resources (from old modules/ecs/main.tf - now inline)
# ============================================================================

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-${var.environment}-cluster"
  # ... (all ECS cluster configuration)
}

# Security Group for ECS Tasks
resource "aws_security_group" "ecs_tasks" {
  # ... (all security group configuration)
}

# ECS Task Definition
resource "aws_ecs_task_definition" "fru_api" {
  # ... (all task definition configuration)
}

# ECS Service
resource "aws_ecs_service" "main" {
  # ... (all service configuration)
}

# ============================================================================
# ALB Module (from old modules/application-ecs/main.tf)
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
# Security Group Rules (from old modules/application-ecs/main.tf)
# ============================================================================

# Update Aurora security group to allow ECS tasks
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
# Frontend Module (from old modules/application-ecs/main.tf)
# ============================================================================

module "frontend" {
  source = "../frontend"

  project_name = var.project_name
  environment  = var.environment
  enable_versioning = var.enable_frontend_versioning
  cloudfront_price_class = var.cloudfront_price_class
  certificate_arn   = var.frontend_certificate_arn
  api_origin_id     = var.frontend_api_origin_id
  alb_dns_name      = module.alb.alb_dns_name
  tags = var.tags
}
```

### `modules/eks/main.tf` (Post-Refactor):

```terraform
# EKS Module - Consolidated
# Combines: EKS Cluster + Frontend

# ============================================================================
# EKS Resources (already in old modules/eks/main.tf - keep as-is)
# ============================================================================

# Security Group for EKS Cluster
resource "aws_security_group" "eks_cluster" {
  # ... (all EKS cluster security group configuration)
}

# EKS Cluster
resource "aws_eks_cluster" "main" {
  # ... (all EKS cluster configuration)
}

# ... (all other EKS resources: node groups, OIDC, KMS, etc.)

# ============================================================================
# Frontend Module (from old modules/application-eks/main.tf - add this)
# ============================================================================

module "frontend" {
  source = "../frontend"

  project_name = var.project_name
  environment  = var.environment
  enable_versioning = var.enable_frontend_versioning
  cloudfront_price_class = var.cloudfront_price_class
  certificate_arn   = var.frontend_certificate_arn
  api_origin_id     = var.frontend_api_origin_id
  # Note: alb_dns_name is optional for EKS - ALB DNS comes from Kubernetes Ingress
  alb_dns_name      = var.alb_dns_name
  tags = var.tags
}
```

## File Count Changes:

### Before:
- **Modules**: 4 directories (ecs, application-ecs, eks, application-eks)
- **Environments**: 4 directories (dev/application-ecs, dev/application-eks, prod/application, prod/eks)

### After:
- **Modules**: 2 directories (ecs, eks) - **50% reduction**
- **Environments**: 4 directories (dev/ecs, dev/eks, prod/ecs, prod/eks) - **same count, better naming**

## Benefits:

1. ✅ **Simpler**: One module per container type instead of two
2. ✅ **Consistent**: Same naming pattern for dev and prod
3. ✅ **Centralized**: All ECS logic in one place, all EKS logic in one place
4. ✅ **Intuitive**: `ecs` and `eks` are self-explanatory module names
5. ✅ **Maintainable**: Easier to find and update related code
