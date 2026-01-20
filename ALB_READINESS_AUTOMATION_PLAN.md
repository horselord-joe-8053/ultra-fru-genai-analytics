# ALB Readiness Automation Plan

## Goal
Automate waiting for Kubernetes Ingress ALB to be ready and update CloudFront distribution with ALB DNS name, integrated into EKS deployment workflow.

## Requirements
- Wait for Ingress ALB to provision (timeout: 10 minutes)
- Fail-fast if timeout exceeded
- Update CloudFront distribution with ALB DNS name automatically
- Isolated logic from main deployment flow
- Works in both dry-run and non-dry-run modes

## Current Architecture

### Deployment Flow
```
run.sh deploy --container-type eks dev
  → deploy_eks_full()
    → deploy_phase_check_image()
    → deploy_phase_setup_state_bucket()
    → deploy_phase_deploy_infrastructure()  # Terraform (creates EKS cluster, CloudFront without ALB DNS)
    → deploy_phase_deploy_application()     # kubectl apply (creates Ingress, ALB starts provisioning)
    → [MISSING: Wait for ALB + Update CloudFront]
```

### Current Gaps
1. **No ALB readiness check**: Deployment completes before ALB is ready
2. **No CloudFront update**: CloudFront `alb_dns_name` remains `null`
3. **Manual step required**: Must manually get ALB DNS and update CloudFront

## Proposed Solution

### Phase 1: Create Isolated Helper Script

**File**: `run_scripts/main_application_scripts/aws/shared/helpers/cloudfront-alb-integration.sh`

**Responsibilities:**
- Wait for Ingress ALB to be ready (with timeout)
- Extract ALB DNS name from Ingress
- Update CloudFront distribution with ALB DNS name
- Handle errors gracefully (fail-fast on timeout)

**Functions:**
```bash
# Wait for Ingress ALB to be ready
wait_for_ingress_alb_ready() {
  # Parameters:
  #   $1: Ingress name (default: fru-api-ingress)
  #   $2: Namespace (default: default)
  #   $3: Timeout in seconds (default: 600 = 10 minutes)
  # Returns: ALB DNS name on success, exits on failure
}

# Update CloudFront distribution with ALB DNS
update_cloudfront_with_alb_dns() {
  # Parameters:
  #   $1: CloudFront distribution ID
  #   $2: ALB DNS name
  #   $3: API origin ID (for matching origin)
  # Returns: Success/failure
}

# Main orchestration function
wait_and_update_cloudfront_alb() {
  # Parameters:
  #   $1: Environment (dev/prod)
  #   $2: Container type (eks)
  #   $3: Ingress name (optional)
  #   $4: Timeout (optional)
  # Orchestrates: wait_for_ingress_alb_ready → update_cloudfront_with_alb_dns
}
```

**Implementation Details:**
- **Polling interval**: 10 seconds (check Ingress status every 10s)
- **Timeout**: 10 minutes (600 seconds)
- **Progress logging**: Heartbeat every 30 seconds (using progress-indicator.sh)
- **Error handling**: Fail-fast on timeout, log error details

### Phase 2: Integration Points

#### Option A: Add to `deploy_phase_deploy_application()` (Recommended)
**File**: `run_scripts/main_application_scripts/aws/shared/container-deploy-common.sh`

**Change:**
```bash
deploy_phase_deploy_application() {
  # ... existing code (kubectl apply) ...
  
  # For EKS: Wait for ALB and update CloudFront
  if [ "$CONTAINER_TYPE" = "eks" ]; then
    source "$SCRIPT_DIR/aws/shared/helpers/cloudfront-alb-integration.sh"
    wait_and_update_cloudfront_alb "$ENVIRONMENT" "$CONTAINER_TYPE" || {
      log_error "Failed to wait for ALB or update CloudFront"
      return 1
    }
  fi
}
```

**Pros:**
- Runs immediately after Ingress is created
- Part of deployment workflow (automatic)
- Isolated in shared function

**Cons:**
- Adds dependency on Kubernetes Ingress
- Only runs for EKS (conditional logic)

#### Option B: Add as Separate Phase (Alternative)
**File**: `run_scripts/main_application_scripts/aws/run.sh`

**Change:**
```bash
deploy_eks_full() {
  # ... existing phases ...
  
  # New phase: Wait for ALB and update CloudFront
  deploy_phase_wait_alb_and_update_cloudfront() {
    log_step "Waiting for Ingress ALB and updating CloudFront..."
    source "$SCRIPT_DIR/shared/helpers/cloudfront-alb-integration.sh"
    wait_and_update_cloudfront_alb "$ENVIRONMENT" "$CONTAINER_TYPE" || {
      log_error "ALB readiness check or CloudFront update failed"
      return 1
    }
  }
  
  # Call after deploy_phase_deploy_application
  deploy_phase_wait_alb_and_update_cloudfront
}
```

**Pros:**
- Explicit phase (clear in workflow)
- Easy to skip with flag (--skip-alb-wait)

**Cons:**
- Additional phase (more complexity)
- Must be called explicitly

**Recommendation: Option A** (integrated into deploy_phase_deploy_application)

### Phase 3: CloudFront Update Implementation

**Challenge**: Update CloudFront distribution origin with ALB DNS name

**Approach**: Use Terraform data source + `terraform apply` (not AWS CLI)

**File**: `infra/terraform/providers/aws/modules/eks/main.tf`

**Change:**
```hcl
# Data source to fetch ALB DNS from Ingress (after it's created)
data "external" "ingress_alb_dns" {
  count   = var.alb_dns_name == null && var.wait_for_alb ? 1 : 0
  program = ["bash", "-c", <<-EOT
    kubectl get ingress -n default fru-api-ingress \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo ""
  EOT
  ]
  
  # Only run after Ingress is created
  depends_on = [module.frontend]
}

# Update frontend module with ALB DNS (if available)
module "frontend" {
  # ... existing config ...
  
  # Use data source if alb_dns_name is null
  alb_dns_name = var.alb_dns_name != null ? var.alb_dns_name : (
    var.wait_for_alb && length(data.external.ingress_alb_dns) > 0 && 
    data.external.ingress_alb_dns[0].result.result != "" ? 
    data.external.ingress_alb_dns[0].result.result : null
  )
}
```

**Alternative Approach**: Use AWS CLI to update CloudFront directly
- **Pros**: No Terraform state change
- **Cons**: Out-of-band change (not in Terraform state)

**Recommendation**: Use Terraform data source (keeps state in sync)

### Phase 4: Dry-Run Support

**For dry-run mode:**
- Skip ALB wait (Ingress not created)
- Log message: "Skipping ALB readiness check (dry-run mode)"
- Return success (no-op)

**Implementation:**
```bash
wait_and_update_cloudfront_alb() {
  if [ "$DRY_RUN" = "true" ]; then
    log_info "Skipping ALB readiness check (dry-run mode)"
    return 0
  fi
  # ... normal flow ...
}
```

### Phase 5: Error Handling

**Failure Scenarios:**
1. **Ingress not found**: Fail-fast immediately (deployment issue)
2. **Timeout exceeded**: Fail-fast with clear error message
3. **CloudFront update fails**: Fail-fast, log error details
4. **ALB DNS invalid**: Validate DNS format before updating CloudFront

**Error Messages:**
```bash
# Timeout
"[ERROR] Ingress ALB did not become ready within 10 minutes. Check Ingress status: kubectl get ingress -n default fru-api-ingress"

# Ingress not found
"[ERROR] Ingress 'fru-api-ingress' not found in namespace 'default'. Ensure Kubernetes manifests were applied successfully."

# CloudFront update failed
"[ERROR] Failed to update CloudFront distribution with ALB DNS. Distribution ID: <id>, ALB DNS: <dns>"
```

## File Structure

```
run_scripts/main_application_scripts/aws/shared/helpers/
  └── cloudfront-alb-integration.sh     # NEW: ALB wait + CloudFront update logic

run_scripts/main_application_scripts/aws/shared/
  └── container-deploy-common.sh        # MODIFY: Add ALB wait after kubectl apply

infra/terraform/providers/aws/modules/eks/
  └── main.tf                           # MODIFY: Add data source for ALB DNS

infra/terraform/providers/aws/modules/eks/variables.tf
  └── variables.tf                      # ADD: wait_for_alb variable (default: true)
```

## Testing Strategy

1. **Unit Tests** (manual):
   - Test `wait_for_ingress_alb_ready()` with mock Ingress
   - Test timeout scenario (set timeout to 1 second)
   - Test CloudFront update with mock distribution

2. **Integration Tests**:
   - Full EKS deployment (verify ALB wait + CloudFront update)
   - Dry-run mode (verify skip)
   - Error scenarios (Ingress not found, timeout)

## Rollout Plan

1. **Phase 1**: Create helper script (no integration)
2. **Phase 2**: Test helper script independently
3. **Phase 3**: Integrate into deployment flow
4. **Phase 4**: Test full deployment workflow
5. **Phase 5**: Monitor production deployments

## Backward Compatibility

- **Existing deployments**: No breaking changes (ALB wait is additive)
- **Optional feature**: Can be disabled with flag (if needed)
- **Dry-run**: Always skips (no changes)

## Success Criteria

✅ ALB readiness check completes within 10 minutes  
✅ CloudFront distribution updated with ALB DNS automatically  
✅ No manual intervention required  
✅ Fail-fast on errors (clear error messages)  
✅ Works in dry-run mode (skips gracefully)  
✅ Isolated logic (doesn't affect main deployment flow)

