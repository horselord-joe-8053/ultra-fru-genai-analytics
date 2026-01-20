# Terraform/Terragrunt Synergy Analysis
## Minimizing Duplication Between Providers and Environments

## Current Duplication Analysis

### 1. Between Environments (dev vs prod)

**High Duplication Found:**

#### Infrastructure Layer (`dev/infrastructure/terragrunt.hcl` vs `prod/infrastructure/terragrunt.hcl`)
- **95% identical** - Only `download_dir` path differs (`dev/` vs `prod/`)
- Same `include` blocks
- Same `terraform` source
- Same `inputs` structure (values come from `env.hcl`)

#### ECS Layer (`dev/ecs/terragrunt.hcl` vs `prod/ecs/terragrunt.hcl`)
- **90% identical** - Only `download_dir` and some `mock_outputs` differ
- Same `include` blocks
- Same `terraform` source
- Same `dependencies` structure
- Same `inputs` structure (values come from `env.hcl` and `dependency`)

#### EKS Layer (`dev/eks/terragrunt.hcl` vs `prod/eks/terragrunt.hcl`)
- **95% identical** - Only `download_dir` differs
- Same structure as ECS

### 2. Between Container Types (ecs vs eks)

**Moderate Duplication Found:**

#### Common Patterns:
- Same `include` blocks (root, env)
- Same `dependencies` structure (depends on infrastructure)
- Same `dependency` block pattern
- Similar `inputs` structure (project_name, environment, aws_region, vpc_id, etc.)
- Same `download_dir` pattern

#### Differences:
- Different `terraform.source` (modules/ecs vs modules/eks)
- Different `inputs` (ECS has more: aurora_endpoint, secrets, etc.)

### 3. Between Providers (AWS vs GCP - Future)

**Potential for Shared Patterns:**
- Terragrunt structure (includes, dependencies, inputs pattern)
- Layer organization (infrastructure, application)
- Environment variable handling
- Tag management

---

## Proposed Solution: Shared Terragrunt Templates

### Strategy: Use Terragrunt's `include` with Shared Base Configs

**Key Insight:** Terragrunt allows multiple `include` blocks and can use shared base configurations.

### Proposed Structure

```
infra/terraform/
├── providers/
│   ├── aws/
│   │   ├── modules/              # AWS-specific modules (unchanged)
│   │   └── environments/
│   │       ├── root.hcl          # AWS-specific: S3 backend, AWS provider
│   │       ├── _templates/       # ✅ NEW: Shared Terragrunt templates
│   │       │   ├── infrastructure-base.hcl
│   │       │   ├── ecs-base.hcl
│   │       │   └── eks-base.hcl
│   │       ├── dev/
│   │       │   ├── env.hcl
│   │       │   ├── infrastructure/
│   │       │   │   └── terragrunt.hcl  # ✅ SIMPLIFIED: Just includes base + env-specific
│   │       │   ├── ecs/
│   │       │   │   └── terragrunt.hcl  # ✅ SIMPLIFIED: Just includes base + env-specific
│   │       │   └── eks/
│   │       │       └── terragrunt.hcl  # ✅ SIMPLIFIED: Just includes base + env-specific
│   │       └── prod/
│   │           ├── env.hcl
│   │           ├── infrastructure/
│   │           │   └── terragrunt.hcl  # ✅ SIMPLIFIED: Just includes base + env-specific
│   │           ├── ecs/
│   │           │   └── terragrunt.hcl  # ✅ SIMPLIFIED: Just includes base + env-specific
│   │           └── eks/
│   │               └── terragrunt.hcl  # ✅ SIMPLIFIED: Just includes base + env-specific
│   └── gcp/
│       └── environments/
│           ├── root.hcl          # GCP-specific: GCS backend, Google provider
│           ├── _templates/       # ✅ NEW: GCP-specific templates (similar structure)
│           └── dev/              # Similar structure to AWS
└── common/                        # ✅ NEW: Cross-provider shared patterns (if any)
    └── _patterns/                 # Common Terragrunt patterns
        └── (future: if patterns are truly identical across providers)
```

### Implementation: Shared Base Templates

#### Example: `_templates/infrastructure-base.hcl`

```hcl
# Infrastructure layer base template
# This file contains the common structure for infrastructure layer across all environments
# Environment-specific values come from env.hcl

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path = "${get_terragrunt_dir()}/../env.hcl"
  expose = true
}

terraform {
  source = "${get_terragrunt_dir()}/../../../../providers/aws/modules//infrastructure"
}

# Set custom cache directory location
# Uses get_terragrunt_dir() to determine environment (dev/prod)
locals {
  env_name = basename(dirname(get_terragrunt_dir()))
  layer_name = basename(get_terragrunt_dir())
}

download_dir = "${get_path_to_repo_root()}/temp_terra_gen/.terragrunt-cache/${local.env_name}/${local.layer_name}"

# Pass inputs from environment config
inputs = {
  project_name      = include.env.inputs.project_name
  environment       = include.env.inputs.environment
  aws_region        = include.env.inputs.aws_region
  vpc_cidr          = include.env.inputs.vpc_cidr
  availability_zones = include.env.inputs.availability_zones
  
  enable_nat_gateway         = include.env.inputs.enable_nat_gateway
  enable_bedrock_vpc_endpoint = include.env.inputs.enable_bedrock_vpc_endpoint
  
  openai_api_key = include.env.inputs.openai_api_key
  db_password    = include.env.inputs.db_password
  db_username     = include.env.inputs.db_username
  
  # Create username secret so ECS can use PGUSER from Secrets Manager
  create_db_username_secret = true
  
  aurora_database_name = include.env.inputs.aurora_database_name
  aurora_min_capacity  = include.env.inputs.aurora_min_capacity
  aurora_max_capacity  = include.env.inputs.aurora_max_capacity
  aurora_instance_count = include.env.inputs.aurora_instance_count
  
  enable_iam_auth = include.env.inputs.enable_iam_auth
  deletion_protection = include.env.inputs.deletion_protection
  
  # Bedrock inference profile ID (for IAM permissions)
  bedrock_inference_profile_id = include.env.inputs.bedrock_inference_profile_id
  
  tags = include.env.inputs.tags
}

# Dependencies: None (infrastructure layer is the foundation)
```

#### Example: `_templates/ecs-base.hcl`

```hcl
# ECS layer base template
# This file contains the common structure for ECS layer across all environments

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path = "${get_terragrunt_dir()}/../env.hcl"
  expose = true
}

terraform {
  source = "${get_terragrunt_dir()}/../../../../providers/aws/modules//ecs"
}

locals {
  env_name = basename(dirname(get_terragrunt_dir()))
  layer_name = basename(get_terragrunt_dir())
}

download_dir = "${get_path_to_repo_root()}/temp_terra_gen/.terragrunt-cache/${local.env_name}/${local.layer_name}"

# Dependencies on infrastructure layer
dependencies {
  paths = ["../infrastructure"]
}

dependency "infrastructure" {
  config_path = "../infrastructure"
  
  # Mock outputs (can be overridden per environment if needed)
  mock_outputs = {
    vpc_id                    = "vpc-xxxxxxxx"
    public_subnet_ids         = ["subnet-xxxxxxxx", "subnet-yyyyyyyy"]
    private_subnet_ids        = ["subnet-zzzzzzzz", "subnet-aaaaaaaa"]
    aurora_endpoint           = "fru-${include.env.inputs.environment}-aurora-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com"
    aurora_port               = 5432
    aurora_database_name      = "fru_db"
    aurora_security_group_id  = "sg-xxxxxxxx"
    ecs_task_execution_role_arn = "arn:aws:iam::123456789012:role/fru-${include.env.inputs.environment}-ecs-task-execution-role"
    ecs_task_runtime_role_arn   = "arn:aws:iam::123456789012:role/fru-${include.env.inputs.environment}-ecs-task-runtime-role"
    openai_secret_arn            = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fru/${include.env.inputs.environment}/openai-api-key"
    openai_secret_plain_arn      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fru/${include.env.inputs.environment}/openai-api-key-plain"
    db_password_secret_arn       = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fru/${include.env.inputs.environment}/aurora-db-password"
    db_password_plain_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fru/${include.env.inputs.environment}/aurora-db-password-plain"
    db_username_secret_arn       = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fru/${include.env.inputs.environment}/aurora-db-username"
    s3_data_bucket_id            = "fru-${include.env.inputs.environment}-analytics-data-123456789012"
    s3_data_bucket_arn           = "arn:aws:s3:::fru-${include.env.inputs.environment}-analytics-data-123456789012"
    s3_delta_table_path          = "s3://fru-${include.env.inputs.environment}-analytics-data-123456789012/delta"
  }
  
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Pass inputs from environment config and infrastructure outputs
inputs = {
  project_name      = include.env.inputs.project_name
  environment       = include.env.inputs.environment
  aws_region        = include.env.inputs.aws_region
  
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
  ecs_desired_count = include.env.inputs.ecs_desired_count
  ecs_task_cpu     = include.env.inputs.ecs_task_cpu
  ecs_task_memory  = include.env.inputs.ecs_task_memory
  
  # Application configuration
  bedrock_inference_profile_id = include.env.inputs.bedrock_inference_profile_id
  aws_bedrock_model_id = include.env.inputs.aws_bedrock_model_id
  log_level = include.env.inputs.log_level
  allowed_origins = include.env.inputs.allowed_origins
  openai_embed_model = include.env.inputs.openai_embed_model
  use_agent_query = include.env.inputs.use_agent_query
  
  # S3 configuration
  s3_data_bucket_id = dependency.infrastructure.outputs.s3_data_bucket_id
  s3_delta_table_path = dependency.infrastructure.outputs.s3_delta_table_path
  
  # Analytics scheduler configuration
  enable_analytics_scheduler = include.env.inputs.enable_analytics_scheduler
  analytics_scheduler_interval_seconds = include.env.inputs.analytics_scheduler_interval_seconds
  spark_home = include.env.inputs.spark_home
  delta_table_path = "${dependency.infrastructure.outputs.s3_delta_table_path}/fru_sales"
  delta_lake_package = include.env.inputs.delta_lake_package
  container_type = "ecs"
  
  deletion_protection = include.env.inputs.deletion_protection
  
  # Frontend Configuration (can be overridden per environment)
  enable_frontend_versioning = false
  cloudfront_price_class     = "PriceClass_100"
  frontend_certificate_arn   = null
  frontend_api_origin_id     = "ALB-${include.env.inputs.project_name}-${include.env.inputs.environment}-ecs"
  health_check_path = "/health"
  certificate_arn = null
  
  tags = include.env.inputs.tags
}
```

#### Example: Simplified `dev/infrastructure/terragrunt.hcl`

```hcl
# Infrastructure layer for dev environment
# Includes base template and adds any dev-specific overrides

include "base" {
  path = "${get_terragrunt_dir()}/../../_templates/infrastructure-base.hcl"
}

# Dev-specific overrides (if any)
# Most values come from env.hcl via the base template
# Only override if dev needs something different
```

#### Example: Simplified `dev/ecs/terragrunt.hcl`

```hcl
# ECS layer for dev environment
# Includes base template and adds any dev-specific overrides

include "base" {
  path = "${get_terragrunt_dir()}/../../_templates/ecs-base.hcl"
}

# Dev-specific overrides (if any)
# Most values come from env.hcl and dependency outputs via the base template
```

### Alternative: Using Terragrunt's `generate` Blocks

If `include` doesn't work well for this use case, we can use `generate` blocks to create shared patterns:

```hcl
# _templates/shared-inputs.hcl
generate "shared_inputs" {
  path      = "shared_inputs.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
# Auto-generated shared inputs
# This file is generated from _templates/shared-inputs.hcl
EOF
}
```

### Benefits of This Approach

1. ✅ **Massive Duplication Reduction**: 
   - Infrastructure layer: ~95% reduction (from ~50 lines to ~5 lines per environment)
   - ECS/EKS layers: ~90% reduction (from ~110 lines to ~5 lines per environment)

2. ✅ **Single Source of Truth**: 
   - Common structure in `_templates/`
   - Environment-specific values in `env.hcl`
   - Container-specific differences in base templates

3. ✅ **Easy to Maintain**: 
   - Change structure once in base template, applies to all environments
   - Add new environment: just create `env.hcl` and minimal `terragrunt.hcl`

4. ✅ **Provider-Specific Templates**: 
   - AWS templates in `providers/aws/environments/_templates/`
   - GCP templates in `providers/gcp/environments/_templates/`
   - Similar structure, different implementations

5. ✅ **Cross-Provider Patterns** (if needed):
   - If patterns are truly identical, can create `common/_patterns/`
   - But likely each provider will have different structures

### Challenges and Solutions

#### Challenge 1: Terragrunt `include` Limitations
- **Issue**: Terragrunt has limitations with nested includes and accessing `include.env.inputs` from templates
- **Solution**: Use `include` for base templates, but ensure templates don't try to access `include.env` directly - instead, pass values explicitly or use `locals`

#### Challenge 2: Environment-Specific Overrides
- **Issue**: Some environments might need different values
- **Solution**: Allow environment-specific `terragrunt.hcl` to override base template values using Terragrunt's merge behavior

#### Challenge 3: Container-Specific Differences
- **Issue**: ECS and EKS have different inputs
- **Solution**: Separate base templates (`ecs-base.hcl` vs `eks-base.hcl`)

### Implementation Phases

#### Phase 1: Create Base Templates (AWS)
1. Create `providers/aws/environments/_templates/`
2. Extract common structure to `infrastructure-base.hcl`
3. Extract common structure to `ecs-base.hcl`
4. Extract common structure to `eks-base.hcl`
5. Update `dev/infrastructure/terragrunt.hcl` to use base
6. Update `dev/ecs/terragrunt.hcl` to use base
7. Update `dev/eks/terragrunt.hcl` to use base
8. Test with `terragrunt plan` for dev
9. Repeat for `prod/`

#### Phase 2: Verify and Refine
1. Test all environments (dev/prod) with all layers (infrastructure/ecs/eks)
2. Ensure no functionality is lost
3. Refine templates based on any edge cases

#### Phase 3: Apply to GCP (Future)
1. Create `providers/gcp/environments/_templates/`
2. Create GCP-specific base templates (similar structure, different modules)
3. Apply same pattern to GCP environments

### Estimated Duplication Reduction

**Before:**
- Infrastructure: 2 files × ~50 lines = 100 lines
- ECS: 2 files × ~110 lines = 220 lines
- EKS: 2 files × ~75 lines = 150 lines
- **Total: ~470 lines**

**After:**
- Infrastructure base: 1 file × ~50 lines = 50 lines
- ECS base: 1 file × ~110 lines = 110 lines
- EKS base: 1 file × ~75 lines = 75 lines
- Environment-specific: 6 files × ~5 lines = 30 lines
- **Total: ~265 lines**

**Reduction: ~44% fewer lines, ~90% less duplication per environment**

### Summary

**Yes, there is significant potential for synergy!**

1. **Between Environments**: ~90-95% duplication can be eliminated using shared base templates
2. **Between Container Types**: ~80% common structure can be shared via base templates
3. **Between Providers**: Similar patterns can be reused (but implementations differ)

**Recommended Approach:**
- Use Terragrunt `include` blocks with shared base templates
- Keep environment-specific values in `env.hcl`
- Keep container-specific differences in separate base templates
- This reduces duplication by ~90% while maintaining clarity and flexibility

