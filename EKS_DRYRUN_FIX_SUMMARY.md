# EKS Dry-Run Fix Summary

## Problem
EKS dry-run was getting stuck/timing out with errors:
1. `Error: Unsupported argument; An argument named "skip" is not expected here`
2. `Call to function "get_aws_account_id" failed: operation error STS: GetCallerIdentity, get identity: get credentials: failed to refresh cached credentials`

## Root Causes

### 1. Invalid Dependency Block Syntax
The dependency block had an invalid `skip = false` argument that Terragrunt doesn't support.

### 2. Missing AWS Credentials
When Terragrunt processes `root.hcl`, it calls `get_aws_account_id()` which requires AWS credentials. The `AWS_PROFILE` environment variable wasn't being exported before running `terragrunt plan` for the EKS layer.

## Fixes Applied

### Fix 1: Removed Invalid `skip` Argument
**File:** `infra/terraform/providers/aws/environments/dev/eks/terragrunt.hcl`

**Before:**
```hcl
dependency "infrastructure" {
  config_path = "../infrastructure"
  skip_outputs = false
  skip = false  # ❌ Invalid argument
  ...
}
```

**After:**
```hcl
dependency "infrastructure" {
  config_path = "../infrastructure"
  mock_outputs = { ... }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  # ✅ Removed invalid 'skip' argument
}
```

### Fix 2: Export AWS_PROFILE Before Terragrunt Plan
**File:** `run_scripts/main_application_scripts/aws/terraform/deploy.sh`

**Added:**
```bash
# Ensure AWS credentials are available for Terragrunt (needed for root.hcl get_aws_account_id)
export AWS_PROFILE="${AWS_PROFILE:-admin}"
log_info "Using AWS profile: $AWS_PROFILE for Terragrunt operations"
```

## Verification

After fixes, `terragrunt plan` now:
- ✅ Successfully authenticates with AWS
- ✅ Fetches dependency outputs (or uses mocks)
- ✅ Shows real-time progress (refreshing state, generating plan)
- ✅ Completes without hanging

## Why It Was "Stuck"

The process wasn't actually stuck - it was **failing immediately** but the error wasn't visible because:
1. Terragrunt tried to evaluate `root.hcl` → called `get_aws_account_id()` → failed silently
2. The invalid `skip` argument caused a parse error
3. Both errors occurred before any visible progress could be shown

## Current Status

✅ **Fixed and Working**
- EKS dry-run now runs successfully
- Shows progress in real-time
- Uses mock outputs when infrastructure dependency isn't initialized
- Falls back to real outputs when infrastructure is deployed

## Next Steps

The EKS dry-run should now complete successfully. If you want to see full progress:

```bash
./run_scripts/main_application_scripts/aws/run.sh deploy --container-type eks dev --dry-run
```

The plan will show:
- State refresh progress
- Resource changes (create/update/delete)
- Full Terraform plan output

