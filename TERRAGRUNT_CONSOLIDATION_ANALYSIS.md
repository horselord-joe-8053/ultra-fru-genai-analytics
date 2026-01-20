# Analysis: Merging Terragrunt Logic from environments/ to modules/

## Current Structure:

```
infra/terraform/
├── modules/
│   ├── ecs/              # Terraform code (reusable)
│   └── eks/              # Terraform code (reusable)
│
└── environments/
    ├── dev/
    │   ├── ecs/          # Terragrunt config (environment-specific)
    │   │   └── terragrunt.hcl
    │   └── eks/          # Terragrunt config (environment-specific)
    │       └── terragrunt.hcl
    └── prod/
        ├── ecs/          # Terragrunt config (environment-specific)
        │   └── terragrunt.hcl
        └── eks/          # Terragrunt config (environment-specific)
            └── terragrunt.hcl
```

## Question: Can we merge terragrunt.hcl logic into modules/?

### Option 1: Move terragrunt.hcl into modules/ (❌ NOT RECOMMENDED)

**What it would look like:**
```
infra/terraform/
├── modules/
│   ├── ecs/
│   │   ├── main.tf
│   │   ├── terragrunt.hcl  # ❌ Environment-specific config in module?
│   │   └── ...
│   └── eks/
│       ├── main.tf
│       ├── terragrunt.hcl  # ❌ Environment-specific config in module?
│       └── ...
└── environments/
    └── (empty or minimal)
```

**Problems:**
1. ❌ **Violates Terragrunt best practices**: Modules should be reusable, environment configs should be separate
2. ❌ **Can't have different configs per environment**: Dev and prod would need the same terragrunt.hcl
3. ❌ **Loses Terragrunt's dependency management**: Can't easily reference infrastructure outputs
4. ❌ **Breaks Terragrunt's include system**: Can't use `include "env"` for environment-specific values
5. ❌ **State management issues**: Terragrunt state keys are based on path_relative_to_include(), which needs environments/

**Verdict: ❌ This does NOT make sense**

### Option 2: Create shared terragrunt.hcl template (✅ RECOMMENDED)

**What it would look like:**
```
infra/terraform/
├── modules/
│   ├── ecs/              # Terraform code (unchanged)
│   └── eks/              # Terraform code (unchanged)
│
└── environments/
    ├── _templates/       # ✅ NEW: Shared templates
    │   ├── ecs.hcl       # Shared terragrunt.hcl for ECS
    │   └── eks.hcl       # Shared terragrunt.hcl for EKS
    ├── dev/
    │   ├── ecs/
    │   │   └── terragrunt.hcl  # include "../../_templates/ecs.hcl"
    │   └── eks/
    │       └── terragrunt.hcl  # include "../../_templates/eks.hcl"
    └── prod/
        ├── ecs/
        │   └── terragrunt.hcl  # include "../../_templates/ecs.hcl"
        └── eks/
            └── terragrunt.hcl  # include "../../_templates/eks.hcl"
```

**Benefits:**
1. ✅ **Reduces duplication**: Common logic in templates (~90% of terragrunt.hcl is identical)
2. ✅ **Maintains separation**: Modules stay reusable, configs stay environment-specific
3. ✅ **Follows Terragrunt best practices**: Uses include system
4. ✅ **Allows environment overrides**: Each environment can override template values
5. ✅ **Centralizes container-type logic**: All ECS terragrunt logic in one template, all EKS in another

**Example Implementation:**

`environments/_templates/ecs.hcl`:
```hcl
# Shared Terragrunt configuration for ECS deployments
# This file is included by dev/ecs/terragrunt.hcl and prod/ecs/terragrunt.hcl

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path = "${get_terragrunt_dir()}/../../${get_env("ENVIRONMENT", "dev")}/env.hcl"
  expose = true
}

terraform {
  source = "${get_terragrunt_dir()}/../../../modules//ecs"
}

# Dependencies on infrastructure layer
dependencies {
  paths = ["../infrastructure"]
}

dependency "infrastructure" {
  config_path = "../infrastructure"
  
  mock_outputs = {
    vpc_id                    = "vpc-xxxxxxxx"
    public_subnet_ids         = ["subnet-xxxxxxxx", "subnet-yyyyyyyy"]
    private_subnet_ids        = ["subnet-zzzzzzzz", "subnet-aaaaaaaa"]
    # ... (common mock outputs)
  }
  
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Common inputs (can be overridden by environment-specific terragrunt.hcl)
inputs = {
  project_name      = include.env.inputs.project_name
  environment       = include.env.inputs.environment
  aws_region        = include.env.inputs.aws_region
  
  vpc_id             = dependency.infrastructure.outputs.vpc_id
  public_subnet_ids  = dependency.infrastructure.outputs.public_subnet_ids
  private_subnet_ids = dependency.infrastructure.outputs.private_subnet_ids
  
  # ... (all common inputs)
}
```

`environments/dev/ecs/terragrunt.hcl`:
```hcl
# Dev-specific overrides for ECS
include {
  path = find_in_parent_folders("_templates/ecs.hcl")
}

# Dev-specific overrides (if any)
inputs = {
  # Override any dev-specific values here
  # Most values come from env.hcl via the template
}
```

**Verdict: ✅ This DOES make sense and is recommended**

### Option 3: Use Terragrunt's generate blocks (⚠️ COMPLEX)

**What it would look like:**
```
infra/terraform/
├── modules/
│   ├── ecs/
│   │   └── terragrunt.hcl.template  # Template file
│   └── eks/
│       └── terragrunt.hcl.template  # Template file
└── environments/
    └── (generate terragrunt.hcl from templates)
```

**Problems:**
1. ⚠️ **Complex**: Requires custom generation logic
2. ⚠️ **Less maintainable**: Harder to understand and debug
3. ⚠️ **Not standard Terragrunt pattern**: Most teams use include system

**Verdict: ⚠️ Possible but not recommended**

## Recommendation: ✅ Option 2 (Shared Templates)

### Why Option 2 makes sense:

1. **Centralizes container-type logic**: All ECS terragrunt configuration in one place (`_templates/ecs.hcl`)
2. **Reduces duplication**: ~90% of terragrunt.hcl is identical between dev and prod
3. **Maintains best practices**: Keeps modules reusable, configs environment-specific
4. **Easy to maintain**: Changes to ECS terragrunt logic only need to be made in one place
5. **Allows overrides**: Each environment can still override template values if needed

### Implementation Plan:

1. Create `environments/_templates/ecs.hcl` with all common ECS terragrunt logic
2. Create `environments/_templates/eks.hcl` with all common EKS terragrunt logic
3. Update `environments/dev/ecs/terragrunt.hcl` to include the template
4. Update `environments/dev/eks/terragrunt.hcl` to include the template
5. Update `environments/prod/ecs/terragrunt.hcl` to include the template
6. Update `environments/prod/eks/terragrunt.hcl` to include the template

### What gets centralized:

- ✅ Module source path
- ✅ Dependency definitions
- ✅ Mock outputs structure
- ✅ Common inputs mapping
- ✅ Infrastructure dependency references

### What stays environment-specific:

- ✅ `download_dir` path (dev vs prod)
- ✅ `include "env"` path (dev/env.hcl vs prod/env.hcl)
- ✅ Environment-specific overrides (if any)

## Answer to Question 2:

**Can we merge terragrunt container-type specific logic from environments/ to infra/terraform/?**

**Answer: ✅ YES, but use Option 2 (shared templates), NOT moving into modules/**

- ❌ **Don't move terragrunt.hcl into modules/**: This breaks Terragrunt's separation of concerns
- ✅ **Do create shared templates in environments/_templates/**: This centralizes logic while maintaining best practices

This approach:
- ✅ Centralizes container-type logic (as requested)
- ✅ Reduces duplication (~90% of terragrunt.hcl is identical)
- ✅ Maintains Terragrunt best practices
- ✅ Makes maintenance easier (one place to update ECS/EKS terragrunt logic)
