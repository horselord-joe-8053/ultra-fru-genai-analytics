# Final Expected File Structure for `infra/terraform/`
## Incorporating All Synergies and Workarounds

## Current Structure Analysis

### Current Files:
- `modules/` - AWS-specific modules (alb, aurora, ecs, eks, frontend, iam, infrastructure, s3-data, secrets-manager, vpc)
- `environments/` - AWS-specific environments (dev, prod with infrastructure, ecs, eks layers)
- `environments/root.hcl` - AWS-specific root config

### Synergies to Address:
1. **Between environments (dev/prod)**: ~90-95% duplication → Use shared component base templates
2. **Between container types (ecs/eks)**: ~80% common structure → Use shared component base templates
3. **Between providers (AWS/GCP)**: Similar patterns → Provider separation with similar structure

---

## Final Expected Structure

```
infra/terraform/
├── providers/
│   ├── aws/
│   │   ├── modules/                          # AWS-specific Terraform modules
│   │   │   ├── alb/
│   │   │   │   ├── main.tf
│   │   │   │   ├── variables.tf
│   │   │   │   ├── outputs.tf
│   │   │   │   └── README.md
│   │   │   ├── aurora/
│   │   │   │   ├── main.tf
│   │   │   │   ├── variables.tf
│   │   │   │   ├── outputs.tf
│   │   │   │   └── README.md
│   │   │   ├── ecs/
│   │   │   │   ├── main.tf
│   │   │   │   ├── variables.tf
│   │   │   │   ├── outputs.tf
│   │   │   │   └── README.md
│   │   │   ├── eks/
│   │   │   │   ├── main.tf
│   │   │   │   ├── variables.tf
│   │   │   │   ├── outputs.tf
│   │   │   │   └── README.md
│   │   │   ├── frontend/
│   │   │   │   ├── main.tf
│   │   │   │   ├── variables.tf
│   │   │   │   ├── outputs.tf
│   │   │   │   └── README.md
│   │   │   ├── iam/
│   │   │   │   ├── main.tf
│   │   │   │   ├── variables.tf
│   │   │   │   ├── outputs.tf
│   │   │   │   └── README.md
│   │   │   ├── infrastructure/
│   │   │   │   ├── main.tf
│   │   │   │   ├── variables.tf
│   │   │   │   └── outputs.tf
│   │   │   ├── s3-data/
│   │   │   │   ├── main.tf
│   │   │   │   ├── variables.tf
│   │   │   │   └── outputs.tf
│   │   │   ├── secrets-manager/
│   │   │   │   ├── main.tf
│   │   │   │   ├── variables.tf
│   │   │   │   ├── outputs.tf
│   │   │   │   └── README.md
│   │   │   └── vpc/
│   │   │       ├── main.tf
│   │   │       ├── variables.tf
│   │   │       ├── outputs.tf
│   │   │       └── README.md
│   │   └── environments/
│   │       ├── root.hcl                      # AWS-specific: S3 backend, AWS provider
│   │       ├── _component/                   # ✅ Shared component base templates (workaround)
│   │       │   ├── infrastructure-base.hcl  # Common infrastructure layer structure
│   │       │   ├── ecs-base.hcl              # Common ECS layer structure
│   │       │   └── eks-base.hcl              # Common EKS layer structure
│   │       ├── dev/
│   │       │   ├── env.hcl                   # Dev-specific environment values
│   │       │   ├── infrastructure/
│   │       │   │   └── terragrunt.hcl        # ✅ Simplified: includes root + component (~5 lines)
│   │       │   ├── ecs/
│   │       │   │   └── terragrunt.hcl        # ✅ Simplified: includes root + component (~5 lines)
│   │       │   └── eks/
│   │       │       └── terragrunt.hcl        # ✅ Simplified: includes root + component (~5 lines)
│   │       └── prod/
│   │           ├── env.hcl                    # Prod-specific environment values
│   │           ├── infrastructure/
│   │           │   └── terragrunt.hcl        # ✅ Simplified: includes root + component (~5 lines)
│   │           ├── ecs/
│   │           │   └── terragrunt.hcl        # ✅ Simplified: includes root + component (~5 lines)
│   │           └── eks/
│   │               └── terragrunt.hcl        # ✅ Simplified: includes root + component (~5 lines)
│   └── gcp/
│       ├── modules/                          # GCP-specific Terraform modules (future)
│       │   ├── cloud-run/
│       │   │   ├── main.tf
│       │   │   ├── variables.tf
│       │   │   ├── outputs.tf
│       │   │   └── README.md
│       │   ├── gke/
│       │   │   ├── main.tf
│       │   │   ├── variables.tf
│       │   │   ├── outputs.tf
│       │   │   └── README.md
│       │   ├── cloud-sql/
│       │   │   ├── main.tf
│       │   │   ├── variables.tf
│       │   │   ├── outputs.tf
│       │   │   └── README.md
│       │   ├── load-balancer/
│       │   │   ├── main.tf
│       │   │   ├── variables.tf
│       │   │   ├── outputs.tf
│       │   │   └── README.md
│       │   ├── vpc/
│       │   │   ├── main.tf
│       │   │   ├── variables.tf
│       │   │   ├── outputs.tf
│       │   │   └── README.md
│       │   ├── iam/
│       │   │   ├── main.tf
│       │   │   ├── variables.tf
│       │   │   ├── outputs.tf
│       │   │   └── README.md
│       │   ├── secret-manager/
│       │   │   ├── main.tf
│       │   │   ├── variables.tf
│       │   │   ├── outputs.tf
│       │   │   └── README.md
│       │   ├── cloud-storage/
│       │   │   ├── main.tf
│       │   │   ├── variables.tf
│       │   │   ├── outputs.tf
│       │   │   └── README.md
│       │   ├── frontend/
│       │   │   ├── main.tf
│       │   │   ├── variables.tf
│       │   │   ├── outputs.tf
│       │   │   └── README.md
│       │   └── infrastructure/
│       │       ├── main.tf
│       │       ├── variables.tf
│       │       └── outputs.tf
│       └── environments/
│           ├── root.hcl                      # GCP-specific: GCS backend, Google provider
│           ├── _component/                   # ✅ Shared component base templates (workaround)
│           │   ├── infrastructure-base.hcl  # Common infrastructure layer structure
│           │   ├── cloud-run-base.hcl       # Common Cloud Run layer structure
│           │   └── gke-base.hcl             # Common GKE layer structure
│           ├── dev/
│           │   ├── env.hcl                   # Dev-specific environment values
│           │   ├── infrastructure/
│           │   │   └── terragrunt.hcl        # ✅ Simplified: includes root + component (~5 lines)
│           │   ├── cloud-run/
│           │   │   └── terragrunt.hcl       # ✅ Simplified: includes root + component (~5 lines)
│           │   └── gke/
│           │       └── terragrunt.hcl      # ✅ Simplified: includes root + component (~5 lines)
│           └── prod/
│               ├── env.hcl                    # Prod-specific environment values
│               ├── infrastructure/
│               │   └── terragrunt.hcl        # ✅ Simplified: includes root + component (~5 lines)
│               ├── cloud-run/
│               │   └── terragrunt.hcl       # ✅ Simplified: includes root + component (~5 lines)
│               └── gke/
│                   └── terragrunt.hcl      # ✅ Simplified: includes root + component (~5 lines)
└── common/                                    # ✅ Future: Cross-provider shared patterns (if any)
    └── _patterns/                             # Common Terragrunt patterns (if truly identical)
        └── (future: if patterns are identical across providers)
```

---

## Key Design Decisions

### 1. Provider Separation
- **Why**: Each provider has different backends (S3 vs GCS), providers (AWS vs Google), and modules
- **Structure**: `providers/aws/` and `providers/gcp/` are completely separate
- **Benefit**: Clear separation, no cross-contamination, easy to add new providers

### 2. Shared Component Base Templates (Workaround)
- **Why**: Avoids nested includes while still reducing duplication
- **Structure**: `_component/` directory with base templates that use `read_terragrunt_config()`
- **Benefit**: ~90% duplication reduction between environments and container types

### 3. Environment-Specific Values
- **Why**: Each environment (dev/prod) has different values
- **Structure**: `env.hcl` in each environment directory
- **Benefit**: Single source of truth for environment-specific configuration

### 4. Simplified Child Configs
- **Why**: Most structure is in base templates
- **Structure**: Child `terragrunt.hcl` files are ~5 lines (just includes)
- **Benefit**: Easy to maintain, easy to add new environments

---

## File Count Comparison

### Before (Current):
- Infrastructure: 2 files × ~50 lines = 100 lines
- ECS: 2 files × ~110 lines = 220 lines
- EKS: 2 files × ~75 lines = 150 lines
- **Total: ~470 lines across 6 files**

### After (Proposed):
- Infrastructure base: 1 file × ~50 lines = 50 lines
- ECS base: 1 file × ~110 lines = 110 lines
- EKS base: 1 file × ~75 lines = 75 lines
- Environment-specific: 6 files × ~5 lines = 30 lines
- **Total: ~265 lines across 9 files**

**Reduction: ~44% fewer lines, ~90% less duplication per environment**

---

## Example File Contents

### `providers/aws/environments/_component/infrastructure-base.hcl`
```hcl
# Infrastructure layer base template
# NOTE: This file does NOT include root or env - that's done by the child terragrunt.hcl
# This avoids nested includes while still allowing access to environment values

locals {
  env_config = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env_name = basename(dirname(get_terragrunt_dir()))
  layer_name = basename(get_terragrunt_dir())
}

terraform {
  source = "${get_terragrunt_dir()}/../../../../providers/aws/modules//infrastructure"
}

download_dir = "${get_path_to_repo_root()}/temp_terra_gen/.terragrunt-cache/${local.env_name}/${local.layer_name}"

inputs = {
  project_name      = local.env_config.inputs.project_name
  environment       = local.env_config.inputs.environment
  aws_region        = local.env_config.inputs.aws_region
  vpc_cidr          = local.env_config.inputs.vpc_cidr
  availability_zones = local.env_config.inputs.availability_zones
  
  enable_nat_gateway         = local.env_config.inputs.enable_nat_gateway
  enable_bedrock_vpc_endpoint = local.env_config.inputs.enable_bedrock_vpc_endpoint
  
  openai_api_key = local.env_config.inputs.openai_api_key
  db_password    = local.env_config.inputs.db_password
  db_username     = local.env_config.inputs.db_username
  
  create_db_username_secret = true
  
  aurora_database_name = local.env_config.inputs.aurora_database_name
  aurora_min_capacity  = local.env_config.inputs.aurora_min_capacity
  aurora_max_capacity  = local.env_config.inputs.aurora_max_capacity
  aurora_instance_count = local.env_config.inputs.aurora_instance_count
  
  enable_iam_auth = local.env_config.inputs.enable_iam_auth
  deletion_protection = local.env_config.inputs.deletion_protection
  
  bedrock_inference_profile_id = local.env_config.inputs.bedrock_inference_profile_id
  
  tags = local.env_config.inputs.tags
}
```

### `providers/aws/environments/_component/ecs-base.hcl`
```hcl
# ECS layer base template
# NOTE: This file does NOT include root or env - that's done by the child terragrunt.hcl

locals {
  env_config = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env_name = basename(dirname(get_terragrunt_dir()))
  layer_name = basename(get_terragrunt_dir())
}

terraform {
  source = "${get_terragrunt_dir()}/../../../../providers/aws/modules//ecs"
}

download_dir = "${get_path_to_repo_root()}/temp_terra_gen/.terragrunt-cache/${local.env_name}/${local.layer_name}"

dependencies {
  paths = ["../infrastructure"]
}

dependency "infrastructure" {
  config_path = "../infrastructure"
  
  mock_outputs = {
    vpc_id                    = "vpc-xxxxxxxx"
    public_subnet_ids         = ["subnet-xxxxxxxx", "subnet-yyyyyyyy"]
    private_subnet_ids        = ["subnet-zzzzzzzz", "subnet-aaaaaaaa"]
    aurora_endpoint           = "fru-${local.env_config.inputs.environment}-aurora-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com"
    aurora_port               = 5432
    aurora_database_name      = "fru_db"
    aurora_security_group_id  = "sg-xxxxxxxx"
    ecs_task_execution_role_arn = "arn:aws:iam::123456789012:role/fru-${local.env_config.inputs.environment}-ecs-task-execution-role"
    ecs_task_runtime_role_arn   = "arn:aws:iam::123456789012:role/fru-${local.env_config.inputs.environment}-ecs-task-runtime-role"
    openai_secret_arn            = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fru/${local.env_config.inputs.environment}/openai-api-key"
    openai_secret_plain_arn      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fru/${local.env_config.inputs.environment}/openai-api-key-plain"
    db_password_secret_arn       = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fru/${local.env_config.inputs.environment}/aurora-db-password"
    db_password_plain_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fru/${local.env_config.inputs.environment}/aurora-db-password-plain"
    db_username_secret_arn       = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fru/${local.env_config.inputs.environment}/aurora-db-username"
    s3_data_bucket_id            = "fru-${local.env_config.inputs.environment}-analytics-data-123456789012"
    s3_data_bucket_arn           = "arn:aws:s3:::fru-${local.env_config.inputs.environment}-analytics-data-123456789012"
    s3_delta_table_path          = "s3://fru-${local.env_config.inputs.environment}-analytics-data-123456789012/delta"
  }
  
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  project_name      = local.env_config.inputs.project_name
  environment       = local.env_config.inputs.environment
  aws_region        = local.env_config.inputs.aws_region
  
  vpc_id             = dependency.infrastructure.outputs.vpc_id
  public_subnet_ids  = dependency.infrastructure.outputs.public_subnet_ids
  private_subnet_ids = dependency.infrastructure.outputs.private_subnet_ids
  
  ecs_task_execution_role_arn = dependency.infrastructure.outputs.ecs_task_execution_role_arn
  ecs_task_runtime_role_arn  = dependency.infrastructure.outputs.ecs_task_runtime_role_arn
  
  aurora_endpoint        = dependency.infrastructure.outputs.aurora_endpoint
  aurora_port            = dependency.infrastructure.outputs.aurora_port
  aurora_database_name   = dependency.infrastructure.outputs.aurora_database_name
  aurora_security_group_id = dependency.infrastructure.outputs.aurora_security_group_id
  
  openai_secret_arn            = dependency.infrastructure.outputs.openai_secret_arn
  openai_secret_plain_arn      = dependency.infrastructure.outputs.openai_secret_plain_arn
  db_password_secret_arn       = dependency.infrastructure.outputs.db_password_secret_arn
  db_password_plain_secret_arn = dependency.infrastructure.outputs.db_password_plain_secret_arn
  db_username_secret_arn       = dependency.infrastructure.outputs.db_username_secret_arn
  
  container_image = get_env("CONTAINER_IMAGE", "")
  ecs_desired_count = local.env_config.inputs.ecs_desired_count
  ecs_task_cpu     = local.env_config.inputs.ecs_task_cpu
  ecs_task_memory  = local.env_config.inputs.ecs_task_memory
  
  bedrock_inference_profile_id = local.env_config.inputs.bedrock_inference_profile_id
  aws_bedrock_model_id = local.env_config.inputs.aws_bedrock_model_id
  log_level = local.env_config.inputs.log_level
  allowed_origins = local.env_config.inputs.allowed_origins
  openai_embed_model = local.env_config.inputs.openai_embed_model
  use_agent_query = local.env_config.inputs.use_agent_query
  
  s3_data_bucket_id = dependency.infrastructure.outputs.s3_data_bucket_id
  s3_delta_table_path = dependency.infrastructure.outputs.s3_delta_table_path
  
  enable_analytics_scheduler = local.env_config.inputs.enable_analytics_scheduler
  analytics_scheduler_interval_seconds = local.env_config.inputs.analytics_scheduler_interval_seconds
  spark_home = local.env_config.inputs.spark_home
  delta_table_path = "${dependency.infrastructure.outputs.s3_delta_table_path}/fru_sales"
  delta_lake_package = local.env_config.inputs.delta_lake_package
  container_type = "ecs"
  
  deletion_protection = local.env_config.inputs.deletion_protection
  
  enable_frontend_versioning = false
  cloudfront_price_class     = "PriceClass_100"
  frontend_certificate_arn   = null
  frontend_api_origin_id     = "ALB-${local.env_config.inputs.project_name}-${local.env_config.inputs.environment}-ecs"
  health_check_path = "/health"
  certificate_arn = null
  
  tags = local.env_config.inputs.tags
}
```

### `providers/aws/environments/_component/eks-base.hcl`
```hcl
# EKS layer base template
# NOTE: This file does NOT include root or env - that's done by the child terragrunt.hcl

locals {
  env_config = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env_name = basename(dirname(get_terragrunt_dir()))
  layer_name = basename(get_terragrunt_dir())
}

terraform {
  source = "${get_terragrunt_dir()}/../../../../providers/aws/modules//eks"
}

download_dir = "${get_path_to_repo_root()}/temp_terra_gen/.terragrunt-cache/${local.env_name}/${local.layer_name}"

dependencies {
  paths = ["../infrastructure"]
}

dependency "infrastructure" {
  config_path = "../infrastructure"
  
  mock_outputs = {
    vpc_id             = "vpc-xxxxxxxx"
    public_subnet_ids  = ["subnet-xxxxxxxx", "subnet-yyyyyyyy"]
    private_subnet_ids = ["subnet-zzzzzzzz", "subnet-aaaaaaaa"]
  }
  
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  project_name      = local.env_config.inputs.project_name
  environment       = local.env_config.inputs.environment
  aws_region        = local.env_config.inputs.aws_region
  
  vpc_id             = dependency.infrastructure.outputs.vpc_id
  public_subnet_ids  = dependency.infrastructure.outputs.public_subnet_ids
  private_subnet_ids = dependency.infrastructure.outputs.private_subnet_ids
  
  cluster_version = local.env_config.inputs.eks_cluster_version
  enable_fargate  = local.env_config.inputs.eks_enable_fargate
  
  node_group_instance_types = local.env_config.inputs.eks_node_group_instance_types
  node_group_desired_size   = local.env_config.inputs.eks_node_group_desired_size
  node_group_min_size       = local.env_config.inputs.eks_node_group_min_size
  node_group_max_size       = local.env_config.inputs.eks_node_group_max_size
  
  endpoint_private_access = local.env_config.inputs.eks_endpoint_private_access
  endpoint_public_access  = local.env_config.inputs.eks_endpoint_public_access
  endpoint_public_access_cidrs = local.env_config.inputs.eks_endpoint_public_access_cidrs
  
  enabled_cluster_log_types = local.env_config.inputs.eks_enabled_cluster_log_types
  
  enable_frontend_versioning = false
  cloudfront_price_class     = "PriceClass_100"
  frontend_certificate_arn   = null
  frontend_api_origin_id     = "ALB-${local.env_config.inputs.project_name}-${local.env_config.inputs.environment}-eks"
  alb_dns_name               = null
  
  tags = local.env_config.inputs.tags
}
```

### `providers/aws/environments/dev/infrastructure/terragrunt.hcl`
```hcl
# Infrastructure layer for dev environment
# This file includes root and component base (non-nested includes)

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "component" {
  path = "${get_terragrunt_dir()}/../../_component/infrastructure-base.hcl"
}

# Dev-specific overrides (if any)
# Most values come from env.hcl via the component base template
```

### `providers/aws/environments/dev/ecs/terragrunt.hcl`
```hcl
# ECS layer for dev environment
# This file includes root and component base (non-nested includes)

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "component" {
  path = "${get_terragrunt_dir()}/../../_component/ecs-base.hcl"
}

# Dev-specific overrides (if any)
# Most values come from env.hcl and dependency outputs via the component base template
```

### `providers/aws/environments/dev/eks/terragrunt.hcl`
```hcl
# EKS layer for dev environment
# This file includes root and component base (non-nested includes)

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "component" {
  path = "${get_terragrunt_dir()}/../../_component/eks-base.hcl"
}

# Dev-specific overrides (if any)
# Most values come from env.hcl and dependency outputs via the component base template
```

### `providers/aws/environments/dev/env.hcl`
```hcl
# Dev environment configuration
# NOTE: Do NOT include "root" here - it's included by infrastructure/terragrunt.hcl and ecs/terragrunt.hcl

inputs = {
  environment = "dev"
  project_name = "fru"
  
  aws_region = "us-east-1"
  availability_zones = ["us-east-1a", "us-east-1b"]
  vpc_cidr = "10.0.0.0/16"
  
  aurora_min_capacity = 0.5
  aurora_max_capacity = 2
  aurora_instance_count = 1
  
  ecs_desired_count = 1
  ecs_task_cpu = 1024
  ecs_task_memory = 4096
  
  eks_cluster_version = "1.29"
  eks_enable_fargate = true
  eks_node_group_instance_types = ["t3.medium"]
  eks_node_group_desired_size = 2
  eks_node_group_min_size = 1
  eks_node_group_max_size = 3
  eks_endpoint_private_access = true
  eks_endpoint_public_access = true
  eks_endpoint_public_access_cidrs = ["0.0.0.0/0"]
  eks_enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  
  openai_api_key = get_env("OPENAI_API_KEY", "")
  db_username    = get_env("PGUSER", "")
  db_password    = get_env("PGPASSWORD", "")
  
  bedrock_inference_profile_id = get_env("AWS_BEDROCK_INFERENCE_PROFILE_ID", "")
  aws_bedrock_model_id = get_env("AWS_BEDROCK_MODEL_ID", "")
  aurora_database_name = get_env("PGDATABASE", "")
  log_level = get_env("LOG_LEVEL", "")
  allowed_origins = get_env("ALLOWED_ORIGINS", "")
  openai_embed_model = get_env("OPENAI_EMBED_MODEL", "")
  use_agent_query = get_env("USE_AGENT_QUERY", "")
  
  enable_analytics_scheduler = get_env("ENABLE_ANALYTICS_SCHEDULER", "false")
  analytics_scheduler_interval_seconds = get_env("ANALYTICS_SCHEDULER_INTERVAL_SECONDS", "")
  spark_home = get_env("SPARK_HOME", "/opt/spark")
  delta_table_path = get_env("DELTA_TABLE_PATH", "data/delta/fru_sales")
  delta_lake_package = get_env("DELTA_LAKE_PACKAGE", "")
  
  enable_nat_gateway = true
  enable_bedrock_vpc_endpoint = true
  enable_iam_auth = false
  deletion_protection = false
  
  tags = {
    Environment = "dev"
    Project     = "FRU-GenAI"
    ManagedBy   = "Terraform"
  }
}
```

### `providers/aws/environments/root.hcl`
```hcl
# Root Terragrunt configuration for AWS
# This file contains common configuration shared across all AWS environments

remote_state {
  backend = "s3"
  
  config = {
    bucket         = get_env("TF_STATE_BUCKET", "fru-terraform-state-${get_aws_account_id()}")
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = get_env("AWS_REGION", "us-east-1")
    encrypt        = true
    use_lockfile   = true
  }

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
EOF
}

inputs = {
  aws_region = get_env("AWS_REGION", "us-east-1")
  
  common_tags = {
    Project     = "FRU-GenAI"
    ManagedBy   = "Terraform"
    Environment = get_env("ENVIRONMENT", "dev")
  }
}
```

---

## Migration Path

1. **Create provider structure**: `providers/aws/` and `providers/gcp/`
2. **Move AWS modules**: `modules/*` → `providers/aws/modules/`
3. **Move AWS environments**: `environments/*` → `providers/aws/environments/`
4. **Create component base templates**: Extract common structure to `_component/*.hcl`
5. **Simplify child configs**: Update `terragrunt.hcl` files to use includes
6. **Test thoroughly**: Verify all environments work
7. **Add GCP scaffolding**: Create GCP structure with similar patterns

---

## Summary

This structure achieves:
- ✅ **Provider separation**: Clear AWS/GCP separation
- ✅ **~90% duplication reduction**: Between environments and container types
- ✅ **Works with Terragrunt**: Uses supported features (no nested includes)
- ✅ **Easy to maintain**: Change base template once, applies everywhere
- ✅ **Easy to extend**: Add new environments or providers easily

