# AWS Teardown Scripts Reference

This document explains each teardown script, their purpose, usage, and relationships. Scripts are ordered from lowest-level (Terraform-specific) to highest-level (orchestrator).

---

## 1. terraform/teardown.sh

**Description**: Low-level Terraform/Terragrunt destroy wrapper. Destroys Terraform-managed infrastructure layers using `terragrunt destroy`, handling dependency ordering (application before infrastructure) and auto-confirming when `PREEMPT=true`.

**Usage**:
```bash
./run_scripts/main_application_scripts/aws/terraform/teardown.sh <ENVIRONMENT> <LAYER>
```

**Parameters**:
- `ENVIRONMENT`: `dev` or `prod`
- `LAYER`: `infrastructure` | `ecs` | `eks` | `all`

**Example**:
```bash
./run_scripts/main_application_scripts/aws/terraform/teardown.sh dev eks
```

**Relationships**:
- **Called by**: `teardown-resources-nonshared.sh` (container-type layer), `teardown-resources-all.sh` (infrastructure layer)
- **Calls**: Terragrunt/Terraform directly
- **Note**: Only destroys Terraform-managed resources. Does not stop services, empty S3 buckets, or clean orphaned resources.

---

## 2. delete-recreatable-resources.sh

**Description**: Helper script to clean up orphaned AWS resources that Terraform may have missed. Deletes orphaned ECS clusters/services, unused ECR images/repositories, orphaned S3 buckets (except state bucket), CloudFront distributions, ALB/ELB load balancers, VPC resources, and Aurora clusters. Preserves Secrets Manager secrets and Terraform state bucket.

**Usage**:
```bash
./run_scripts/main_application_scripts/aws/shared/resources_cleanup/delete-recreatable-resources.sh <ENVIRONMENT> [--dry-run] [--skip-confirmation]
```

**Options**:
- `--dry-run`: Preview without deleting
- `--skip-confirmation`: Skip prompts (auto-confirms when `PREEMPT=true`)

**Example**:
```bash
./run_scripts/main_application_scripts/aws/shared/resources_cleanup/delete-recreatable-resources.sh dev --skip-confirmation
```

**Relationships**:
- **Called by**: `teardown-resources-nonshared.sh` and `teardown-resources-all.sh` (final cleanup step)
- **Calls**: AWS CLI directly

---

## 3. teardown-resources-nonshared.sh

**Description**: Destroys container-type specific infrastructure (ECS OR EKS) while preserving shared infrastructure (VPC, Aurora, IAM). Stops services, empties S3 buckets, destroys container-type Terraform layer, cleans local Docker images, and removes orphaned resources. Use when tearing down one container orchestrator without affecting the other or shared infrastructure.

**Usage**:
```bash
./run_scripts/main_application_scripts/aws/shared/resources_cleanup/teardown-resources-nonshared.sh <ENVIRONMENT> --container-type <ecs|eks> [OPTIONS]
```

**Required Parameters**:
- `ENVIRONMENT`: `dev`, `staging`, or `prod`
- `--container-type`: `ecs` or `eks`

**Options**:
- `--force`: Skip confirmation prompts
- `--dry-run`: Preview changes
- `--clean-local-only`: Only clean local Docker images (skip AWS teardown)

**Example**:
```bash
./run_scripts/main_application_scripts/aws/shared/resources_cleanup/teardown-resources-nonshared.sh dev --container-type eks --force
```

**Relationships**:
- **Called by**: `teardown-resources-all.sh` (as part of complete teardown)
- **Calls**: `terraform/teardown.sh` (container-type layer), `delete-recreatable-resources.sh` (orphan cleanup)

---

## 4. teardown-resources-all.sh

**Description**: Complete infrastructure destruction including shared resources. Calls `teardown-resources-nonshared.sh` to destroy container-type layer, waits for VPC endpoints and Aurora to delete, destroys shared infrastructure via `terraform/teardown.sh infrastructure`, cleans local Docker images, and removes orphaned resources. Most destructive script - destroys VPC, Aurora, IAM, and all container-type resources. Preserves Secrets Manager secrets (30-day recovery window).

**Usage**:
```bash
./run_scripts/main_application_scripts/aws/shared/resources_cleanup/teardown-resources-all.sh <ENVIRONMENT> --container-type <ecs|eks> [OPTIONS]
```

**Required Parameters**:
- `ENVIRONMENT`: `dev`, `staging`, or `prod`
- `--container-type`: `ecs` or `eks`

**Options**:
- `--force`: Skip confirmation prompts
- `--dry-run`: Preview changes
- `--clean-local-only`: Only clean local Docker images (skip AWS teardown)

**Example**:
```bash
./run_scripts/main_application_scripts/aws/shared/resources_cleanup/teardown-resources-all.sh dev --container-type eks --force
```

**Relationships**:
- **Called by**: `aws/run.sh` (when `--preempt` flag is used)
- **Calls**: `teardown-resources-nonshared.sh` (container-type layer), `terraform/teardown.sh` (infrastructure layer), `delete-recreatable-resources.sh` (orphan cleanup)
- **Architecture**: Uses DRY principle - delegates container-type destruction to `teardown-resources-nonshared.sh`, then adds shared infrastructure destruction.

---

## 5. aws/run.sh

**Description**: Main orchestrator script for AWS deployments. When `--preempt` is used, calls `teardown-resources-all.sh` to destroy all infrastructure before deployment, ensures non-interactive execution (auto-confirms all prompts), then proceeds with fresh deployment. Orchestrates complete deployment pipeline (teardown → infrastructure setup → application deployment → verification). Suitable for CI/CD pipelines.

**Usage**:
```bash
./run_scripts/main_application_scripts/aws/run.sh deploy --container-type <ecs|eks> <ENVIRONMENT> [--preempt] [--dry-run]
```

**Required Parameters**:
- `deploy`: Action (deploy, verify, etc.)
- `--container-type`: `ecs` or `eks`
- `ENVIRONMENT`: `dev`, `staging`, or `prod`

**Options**:
- `--preempt`: Destroy all infrastructure before deployment (calls `teardown-resources-all.sh`)
- `--dry-run`: Preview changes without modifying resources

**Example**:
```bash
./run_scripts/main_application_scripts/aws/run.sh deploy --container-type eks dev --preempt
```

**Relationships**:
- **Calls**: `teardown-resources-all.sh` (when `--preempt` is used)
- **Orchestrates**: Complete deployment pipeline

---

## Script Call Hierarchy

```
aws/run.sh (--preempt)
  └── teardown-resources-all.sh
      ├── teardown-resources-nonshared.sh
      │   ├── terraform/teardown.sh (container-type layer)
      │   └── delete-recreatable-resources.sh
      ├── terraform/teardown.sh (infrastructure layer)
      └── delete-recreatable-resources.sh
```

---

## Quick Reference

| Use Case | Script | Example |
|----------|--------|---------|
| Destroy EKS only (preserve ECS + shared) | `teardown-resources-nonshared.sh` | `teardown-resources-nonshared.sh dev --container-type eks --force` |
| Destroy everything (complete teardown) | `teardown-resources-all.sh` | `teardown-resources-all.sh dev --container-type eks --force` |
| Clean up orphaned resources only | `delete-recreatable-resources.sh` | `delete-recreatable-resources.sh dev --skip-confirmation` |
| Destroy Terraform layer directly | `terraform/teardown.sh` | `terraform/teardown.sh dev infrastructure` |
| Complete teardown + deploy | `aws/run.sh --preempt` | `aws/run.sh deploy --container-type eks dev --preempt` |

---

## Effect of --preempt Flag

When `--preempt` is used with `aws/run.sh`:

1. **Non-Interactive**: All confirmation prompts skipped (auto-confirmed)
2. **Complete Teardown**: Calls `teardown-resources-all.sh` which destroys container-type resources, shared infrastructure (VPC, Aurora, IAM), S3 buckets, local Docker images, and orphaned resources
3. **Fresh Deployment**: After teardown, proceeds with full deployment pipeline
4. **CI/CD Ready**: Suitable for automated pipelines (no manual intervention)

**Preserved**: Secrets Manager secrets (30-day recovery window), Terraform state bucket

**Example**:
```bash
./run_scripts/main_application_scripts/aws/run.sh deploy --container-type eks dev --preempt
```

---

## Notes

- All scripts support `--dry-run` to preview changes
- Use `--force` to skip confirmation prompts (or rely on `PREEMPT=true` for non-interactive mode)
- Scripts are idempotent: safe to run multiple times
- Terraform state bucket is never destroyed (by design)
- Secrets Manager secrets are preserved (30-day recovery window)
