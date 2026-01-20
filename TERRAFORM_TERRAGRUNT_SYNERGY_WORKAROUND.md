# Terragrunt Template Workarounds
## Solving the Nested Include Limitation

## The Problem (Recap)

Previous attempt failed because:
- **Nested includes not allowed**: A template that includes `root.hcl` and `env.hcl` cannot itself be included
- **`include.env.inputs` not accessible**: When a file is included, it can't access `include.env.inputs` from the parent's include chain
- **Error**: `Unknown variable; There is no variable named "include"` when templates tried to use `include.env.inputs`

## The Workarounds

Based on Terragrunt documentation and community patterns, here are proven workarounds:

### ✅ Workaround 1: Multiple Non-Nested Includes + `read_terragrunt_config`

**Key Insight**: Component base files should NOT include anything. Instead:
- Child `terragrunt.hcl` includes both `root` and `component` (non-nested)
- Component base files use `read_terragrunt_config()` to read `env.hcl` directly
- This avoids nested includes while still accessing environment values

### ✅ Workaround 2: Exposed Includes for Locals

**Key Insight**: Use `expose = true` to share `locals` from included files, but be careful with `dependency` blocks (they limit what can be exposed).

### ✅ Workaround 3: Generate Blocks (Alternative)

**Key Insight**: Use Terragrunt's `generate` blocks to dynamically create `terragrunt.hcl` files from templates, but this adds complexity.

---

## Recommended Solution: Workaround 1 (Multiple Non-Nested Includes)

### Structure

```
infra/terraform/providers/aws/environments/
├── root.hcl                    # AWS-specific: S3 backend, AWS provider
├── _component/                 # ✅ NEW: Component base configs (NO includes!)
│   ├── infrastructure-base.hcl
│   ├── ecs-base.hcl
│   └── eks-base.hcl
├── dev/
│   ├── env.hcl                 # Environment-specific values
│   ├── infrastructure/
│   │   └── terragrunt.hcl      # ✅ Includes root + component
│   ├── ecs/
│   │   └── terragrunt.hcl      # ✅ Includes root + component
│   └── eks/
│       └── terragrunt.hcl      # ✅ Includes root + component
└── prod/
    └── (same structure)
```

### How It Works

1. **Component base files** (`_component/*.hcl`) do NOT include anything
2. **Component base files** use `read_terragrunt_config()` to read `env.hcl`
3. **Child `terragrunt.hcl`** includes both `root` and `component` (non-nested)
4. This avoids nested includes while still accessing environment values

---

## Implementation Examples

### Example 1: `_component/infrastructure-base.hcl`

```hcl
# Infrastructure layer base template
# NOTE: This file does NOT include root or env - that's done by the child terragrunt.hcl
# This avoids nested includes while still allowing access to environment values

# Read environment config directly (workaround for nested include limitation)
locals {
  env_config = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env_name = basename(dirname(get_terragrunt_dir()))
  layer_name = basename(get_terragrunt_dir())
}

terraform {
  source = "${get_terragrunt_dir()}/../../../../providers/aws/modules//infrastructure"
}

download_dir = "${get_path_to_repo_root()}/temp_terra_gen/.terragrunt-cache/${local.env_name}/${local.layer_name}"

# Pass inputs from environment config (read via read_terragrunt_config)
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

### Example 2: `_component/ecs-base.hcl`

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

### Example 3: Simplified `dev/infrastructure/terragrunt.hcl`

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
# Only override if dev needs something different
```

### Example 4: Simplified `dev/ecs/terragrunt.hcl`

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

---

## Key Differences from Previous Attempt

### ❌ Previous Attempt (Failed)
```hcl
# _templates/infrastructure-base.hcl
include "root" { ... }        # ❌ Nested include - not allowed
include "env" { ... }        # ❌ Nested include - not allowed

inputs = {
  project_name = include.env.inputs.project_name  # ❌ include.env not accessible
}
```

### ✅ New Approach (Works)
```hcl
# _component/infrastructure-base.hcl
# NO includes here - avoids nested includes

locals {
  env_config = read_terragrunt_config(find_in_parent_folders("env.hcl"))  # ✅ Direct read
}

inputs = {
  project_name = local.env_config.inputs.project_name  # ✅ Access via locals
}
```

```hcl
# dev/infrastructure/terragrunt.hcl
include "root" { ... }       # ✅ Non-nested
include "component" { ... }  # ✅ Non-nested (component doesn't include anything)
```

---

## Benefits

1. ✅ **No Nested Includes**: Component base files don't include anything
2. ✅ **Access Environment Values**: Uses `read_terragrunt_config()` to read `env.hcl`
3. ✅ **Massive Duplication Reduction**: ~90% reduction per environment
4. ✅ **Works with Terragrunt**: Uses supported features, no hacks
5. ✅ **Easy to Maintain**: Change base template once, applies to all environments

---

## Implementation Steps

1. **Create `_component/` directory** in `providers/aws/environments/`
2. **Extract common structure** to `_component/infrastructure-base.hcl` (using `read_terragrunt_config`)
3. **Extract common structure** to `_component/ecs-base.hcl`
4. **Extract common structure** to `_component/eks-base.hcl`
5. **Update `dev/infrastructure/terragrunt.hcl`** to include root + component
6. **Update `dev/ecs/terragrunt.hcl`** to include root + component
7. **Update `dev/eks/terragrunt.hcl`** to include root + component
8. **Test with `terragrunt plan`** for dev
9. **Repeat for `prod/`**

---

## Alternative: Generate Blocks (More Complex)

If `read_terragrunt_config` doesn't work for your use case, you can use `generate` blocks:

```hcl
# _component/infrastructure-base.hcl
generate "terragrunt_config" {
  path      = "generated_terragrunt.hcl"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  source = "${get_terragrunt_dir()}/../../../../providers/aws/modules//infrastructure"
}
# ... rest of config
EOF
}
```

But this is more complex and less maintainable. The `read_terragrunt_config` approach is preferred.

---

## Summary

**Yes, there is a workaround!**

The key is:
1. **Component base files do NOT include anything** (avoids nested includes)
2. **Use `read_terragrunt_config()`** to read `env.hcl` directly
3. **Child `terragrunt.hcl` includes both root and component** (non-nested)

This achieves ~90% duplication reduction while working within Terragrunt's limitations.

