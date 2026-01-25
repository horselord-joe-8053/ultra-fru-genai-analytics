# Refactor Plan: Version Consistency Guarantee

## Overview

**Goal:** Ensure version information displayed to users always matches what's actually deployed and running, regardless of when/how builds happen.

**Problem Statement:** Version info can become inconsistent when:
- Backend pods run new image but `CONTAINER_IMAGE` env var isn't updated
- Frontend is rebuilt but version isn't verified after deployment
- CloudFront cache serves old versions even after deployment

**Scope:** This plan focuses ONLY on version consistency (Problem A). Build trigger logic (Problem B) is working as expected and not modified.

---

## Phase 1: Backend Version Synchronization

### Problem
When Kubernetes deployment updates the container image, the `CONTAINER_IMAGE` environment variable in pods doesn't get updated, causing the `/version` endpoint to return stale version info.

### Solution
Always sync `CONTAINER_IMAGE` env var when container image changes.

### Implementation Steps

#### 1.1 Create `sync_deployment_image_and_env()` Function

**File:** `run_scripts/main_application_scripts/aws/shared/helpers/kubernetes-manifests.sh`

**Function Signature:**
```bash
sync_deployment_image_and_env() {
    local deployment_name=$1      # e.g., "fru-api"
    local namespace=$2            # e.g., "default" or "fru-api-dev"
    local new_image_uri=$3        # Full ECR URI with tag
    local container_name="${4:-fru-api}"  # Container name in deployment (default: fru-api)
}
```

**Implementation:**
1. Extract image tag from full URI (everything after `:`)
2. Update deployment image: `kubectl set image deployment/$deployment_name $container_name=$new_image_uri -n $namespace`
3. Update `CONTAINER_IMAGE` env var: `kubectl set env deployment/$deployment_name CONTAINER_IMAGE=$new_image_uri -n $namespace`
4. Verify both are set correctly:
   - Check deployment spec has correct image
   - Check deployment spec has correct `CONTAINER_IMAGE` env var
   - Log verification results
5. Return 0 on success, 1 on failure

**Error Handling:**
- If `kubectl set image` fails, log error and return 1
- If `kubectl set env` fails, log error and return 1
- If verification fails, log warning but don't fail (may be timing issue)

#### 1.2 Integrate into `apply_kubernetes_manifests()`

**Location:** After successful `kubectl apply` of deployment manifest

**Logic:**
1. After applying deployment manifest, check if it's a Deployment resource
2. Extract deployment name and namespace from applied manifest
3. If `CONTAINER_IMAGE` is set, call `sync_deployment_image_and_env()`
4. Log: "Synchronized image and CONTAINER_IMAGE env var for deployment: $deployment_name"

**Code Location:** In `apply_kubernetes_manifests()`, after line ~850 (after successful kubectl apply)

#### 1.3 Add Deployment Template Validation

**Location:** In `generate_kubernetes_manifests()` or before applying

**Logic:**
1. Check if deployment template includes `CONTAINER_IMAGE` env var
2. If missing, log warning: "Deployment template missing CONTAINER_IMAGE env var - version endpoint may not work correctly"
3. Don't fail, but document requirement

---

## Phase 2: Frontend Version Verification

### Problem
Frontend version is baked into build, but we need to verify the deployed version matches what was built.

### Solution
Extract and track frontend version after build, verify it's deployed correctly.

### Implementation Steps

#### 2.1 Extract Frontend Version After Build

**File:** `run_scripts/main_application_scripts/aws/shared/deploy-frontend.sh`

**Location:** After `npm run build` succeeds (around line 170)

**Implementation:**
```bash
# After successful build
extract_frontend_version() {
    local dist_dir="$REPO_ROOT/frontend/dist"
    local version_file="$REPO_ROOT/.frontend-version.txt"
    
    # Try to extract version from built JS files
    # Look for version pattern: V_YYMMDD-HHMMSS_...
    local version_pattern="V_[0-9]{6}-[0-9]{6}_[^\"'\\s]+"
    local extracted_version=""
    
    # Search in built JS files
    if [ -d "$dist_dir/assets" ]; then
        extracted_version=$(grep -oh "$version_pattern" "$dist_dir/assets"/*.js 2>/dev/null | head -1)
    fi
    
    # If not found in JS, try HTML
    if [ -z "$extracted_version" ]; then
        extracted_version=$(grep -oh "$version_pattern" "$dist_dir/index.html" 2>/dev/null | head -1)
    fi
    
    if [ -n "$extracted_version" ]; then
        echo "$extracted_version" > "$version_file"
        log_info "Frontend version extracted: $extracted_version"
        export FRONTEND_VERSION="$extracted_version"
        return 0
    else
        log_warning "Could not extract frontend version from build"
        return 1
    fi
}
```

**Integration:**
- Call `extract_frontend_version` after successful build
- Store version in `.frontend-version.txt` for later verification
- Export `FRONTEND_VERSION` for use in deployment summary

#### 2.2 Log Frontend Version After Deployment

**Location:** After S3 sync completes (around line 220)

**Implementation:**
- Read `.frontend-version.txt` if it exists
- Log: "Frontend deployed with version: $FRONTEND_VERSION"
- Include in deployment summary

---

## Phase 3: Post-Deployment Version Verification

### Problem
No verification that deployed versions match what's actually running.

### Solution
Create comprehensive version verification function that checks both frontend and backend.

### Implementation Steps

#### 3.1 Create `verify_deployment_versions()` Function

**File:** `run_scripts/main_application_scripts/aws/shared/helpers/verify-deployment-versions.sh` (new file)

**Function Signature:**
```bash
verify_deployment_versions() {
    local expected_backend_version=$1    # Image tag expected
    local expected_frontend_version=$2    # Frontend version string (optional)
    local cloudfront_domain=$3            # CloudFront domain (optional)
    local namespace="${4:-default}"       # Kubernetes namespace
    local deployment_name="${5:-fru-api}" # Deployment name
}
```

**Implementation:**

1. **Backend Version Check:**
   ```bash
   # Get backend version from /version endpoint
   local backend_url="https://${cloudfront_domain}/version"
   local actual_backend_version=$(curl -s "$backend_url" 2>/dev/null | jq -r '.version' || echo "")
   
   # Compare with expected
   if [ "$actual_backend_version" = "$expected_backend_version" ]; then
       log_success "Backend version matches: $actual_backend_version"
   else
       log_warning "Backend version mismatch!"
       log_warning "  Expected: $expected_backend_version"
       log_warning "  Actual: $actual_backend_version"
   fi
   ```

2. **Kubernetes Pod Verification:**
   ```bash
   # Check pods are running expected image
   local pod_image=$(kubectl get pods -n $namespace -l app=$deployment_name \
       -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null | cut -d: -f2)
   
   # Check CONTAINER_IMAGE env var
   local pod_env_image=$(kubectl get pods -n $namespace -l app=$deployment_name \
       -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="CONTAINER_IMAGE")].value}' 2>/dev/null | cut -d: -f2)
   
   # Verify both match expected
   ```

3. **Frontend Version Check (if domain provided):**
   ```bash
   # Extract frontend version from page (requires parsing HTML/JS)
   # Or use API endpoint if available
   # This is optional and may require frontend changes
   ```

4. **Health Check:**
   ```bash
   # Verify pods are ready
   kubectl wait --for=condition=ready pod -l app=$deployment_name -n $namespace --timeout=60s
   
   # Check /health endpoint
   local health_status=$(curl -s "https://${cloudfront_domain}/health" 2>/dev/null | jq -r '.status' || echo "")
   ```

5. **Return Status:**
   - Return 0 if all checks pass
   - Return 1 if any critical check fails
   - Log warnings for non-critical mismatches

#### 3.2 Integrate into Deployment Flow

**File:** `run_scripts/main_application_scripts/aws/eks/deploy.sh`

**Location:** At end of `main()` function, after all deployment steps complete

**Implementation:**
```bash
# After successful deployment
if [ "$SKIP_FRONTEND" = false ]; then
    local cloudfront_domain=$(get_cloudfront_domain)  # Helper to get from Terraform
    local expected_backend=$(echo "$CONTAINER_IMAGE" | cut -d: -f2)
    local expected_frontend=$(cat "$REPO_ROOT/.frontend-version.txt" 2>/dev/null || echo "")
    
    source "$REPO_ROOT/run_scripts/main_application_scripts/aws/shared/helpers/verify-deployment-versions.sh"
    verify_deployment_versions "$expected_backend" "$expected_frontend" "$cloudfront_domain" "$namespace" "$deployment_name"
fi
```

**File:** `run_scripts/main_application_scripts/aws/run.sh`

**Location:** In `deploy_eks_full()`, after Phase 5 (around line 890)

**Implementation:**
- Call verification after Kubernetes manifests are deployed
- Include in deployment summary

---

## Phase 4: CloudFront Invalidation Tracking

### Problem
Invalidation IDs are not tracked, making it hard to verify invalidation completed and debug version visibility issues.

### Solution
Track invalidation IDs and provide tools to verify completion.

### Implementation Steps

#### 4.1 Store Invalidation IDs

**File:** `run_scripts/main_application_scripts/aws/shared/deploy-frontend.sh`

**Location:** After invalidation is created (around line 251)

**Implementation:**
```bash
# After invalidation created
local invalidation_log="$REPO_ROOT/.cloudfront-invalidations.log"
local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "$timestamp|$cloudfront_dist_id|$invalidation_id|/*" >> "$invalidation_log"
log_info "Invalidation ID logged: $invalidation_id"
```

**File Format:** `.cloudfront-invalidations.log`
```
2026-01-25T19:22:14Z|E33TA1D0OAYUNR|IEV0VXTJNCT9UOTQT9WC5BRTGY|/*
2026-01-25T20:07:42Z|E33TA1D0OAYUNR|IBQ311FQ6O3IBLHYW2Z5QZ7N3K|/*
```

#### 4.2 Create Invalidation Status Checker

**File:** `run_scripts/main_application_scripts/aws/shared/helpers/check-cloudfront-invalidation.sh` (new file)

**Function:**
```bash
check_invalidation_status() {
    local distribution_id=$1
    local invalidation_id=$2
    
    local status=$(aws cloudfront get-invalidation \
        --distribution-id "$distribution_id" \
        --id "$invalidation_id" \
        --profile "${AWS_PROFILE:-admin}" \
        --output json 2>/dev/null | jq -r '.Invalidation.Status' || echo "Unknown")
    
    echo "$status"
}
```

**Usage:** Can be called manually or from verification scripts

#### 4.3 Enhanced Invalidation Logging

**File:** `run_scripts/main_application_scripts/aws/shared/helpers/cloudfront-invalidation.sh`

**Location:** In `wait_for_invalidation()`, when invalidation completes

**Enhancement:**
- Log completion time: "Invalidation completed in X minutes Y seconds"
- Store completion status in log file
- Update `.cloudfront-invalidations.log` with completion status

#### 4.4 Manual Invalidation Helper Script

**File:** `run_scripts/main_application_scripts/aws/shared/helpers/manual-invalidate-cloudfront.sh` (new file)

**Purpose:** Standalone script to manually invalidate CloudFront cache

**Usage:**
```bash
./manual-invalidate-cloudfront.sh [distribution-id] [paths]
```

**Implementation:**
- Get distribution ID from Terraform if not provided
- Create invalidation
- Wait for completion (optional flag)
- Log invalidation ID

---

## Phase 5: Deployment State Tracking (Optional)

### Problem
No record of what versions were deployed when, making it hard to debug version issues.

### Solution
Track deployment state with version information.

### Implementation Steps

#### 5.1 Create Deployment State File

**File:** `run_scripts/main_application_scripts/aws/shared/helpers/save-deployment-state.sh` (new file)

**Function:**
```bash
save_deployment_state() {
    local environment=$1
    local container_type=$2
    local backend_version=$3
    local frontend_version=$4
    local cloudfront_invalidation_id=$5
    
    local state_file="$REPO_ROOT/.deployment-state.json"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Create or update state file
    local state_json=$(cat "$state_file" 2>/dev/null || echo "{}")
    state_json=$(echo "$state_json" | jq --arg env "$environment" \
        --arg ct "$container_type" \
        --arg bv "$backend_version" \
        --arg fv "$frontend_version" \
        --arg inv "$cloudfront_invalidation_id" \
        --arg ts "$timestamp" \
        '. + {
            last_deployment: {
                timestamp: $ts,
                environment: $env,
                container_type: $ct,
                backend_version: $bv,
                frontend_version: $fv,
                cloudfront_invalidation_id: $inv
            },
            deployments: (.deployments // []) + [{
                timestamp: $ts,
                environment: $env,
                container_type: $ct,
                backend_version: $bv,
                frontend_version: $fv,
                cloudfront_invalidation_id: $inv
            }]
        }')
    
    echo "$state_json" > "$state_file"
    log_info "Deployment state saved to $state_file"
}
```

**File Format:** `.deployment-state.json`
```json
{
  "last_deployment": {
    "timestamp": "2026-01-25T19:22:14Z",
    "environment": "dev",
    "container_type": "eks",
    "backend_version": "fru_dev_20260125_6d6f61f_dirty_20260125_185415",
    "frontend_version": "V_260125-192214_aws_eks_dev",
    "cloudfront_invalidation_id": "IEV0VXTJNCT9UOTQT9WC5BRTGY"
  },
  "deployments": [...]
}
```

#### 5.2 Integrate State Saving

**File:** `run_scripts/main_application_scripts/aws/eks/deploy.sh`

**Location:** At end of `main()`, after successful deployment

**Implementation:**
- Call `save_deployment_state()` with all version info
- Include invalidation ID if available

#### 5.3 Version History Lookup

**File:** `run_scripts/main_application_scripts/aws/shared/helpers/show-deployment-history.sh` (new file)

**Purpose:** Display deployment history for debugging

**Usage:**
```bash
./show-deployment-history.sh [--last N] [--environment dev]
```

---

## Phase 6: Enhanced Verification (Optional)

### Problem
No proactive detection of version drift or inconsistencies.

### Solution
Compare current running state vs expected state.

### Implementation Steps

#### 6.1 Version Drift Detection

**File:** `run_scripts/main_application_scripts/aws/shared/helpers/detect-version-drift.sh` (new file)

**Function:**
```bash
detect_version_drift() {
    local namespace=$1
    local deployment_name=$2
    
    # Get expected version from deployment state
    local expected_backend=$(jq -r '.last_deployment.backend_version' "$REPO_ROOT/.deployment-state.json" 2>/dev/null)
    
    # Get actual running version
    local actual_backend=$(kubectl get pods -n $namespace -l app=$deployment_name \
        -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null | cut -d: -f2)
    
    # Compare
    if [ "$expected_backend" != "$actual_backend" ]; then
        log_warning "Version drift detected!"
        log_warning "  Expected: $expected_backend"
        log_warning "  Actual: $actual_backend"
        return 1
    fi
    
    return 0
}
```

#### 6.2 Periodic Verification

**File:** `run_scripts/main_application_scripts/aws/shared/helpers/verify-running-versions.sh` (new file)

**Purpose:** Standalone script to verify current running versions match expected

**Usage:**
```bash
./verify-running-versions.sh [--environment dev] [--namespace default]
```

---

## Implementation Order

### Priority 1 (Critical - Fixes Core Issue)
1. **Phase 1: Backend Version Synchronization**
   - Implement `sync_deployment_image_and_env()`
   - Integrate into `apply_kubernetes_manifests()`
   - Test: Deploy and verify `CONTAINER_IMAGE` env var matches image

### Priority 2 (Important - Prevents Future Issues)
2. **Phase 3: Post-Deployment Version Verification**
   - Create `verify_deployment_versions.sh`
   - Integrate into deployment flow
   - Test: Run deployment and verify versions match

3. **Phase 2: Frontend Version Verification**
   - Extract version after build
   - Log version after deployment
   - Test: Verify version is extracted and logged correctly

### Priority 3 (Enhancement - Improves Debugging)
4. **Phase 4: CloudFront Invalidation Tracking**
   - Store invalidation IDs
   - Create status checker
   - Test: Verify invalidations are tracked

5. **Phase 5: Deployment State Tracking**
   - Create state file structure
   - Integrate state saving
   - Test: Verify state is saved correctly

### Priority 4 (Optional - Nice to Have)
6. **Phase 6: Enhanced Verification**
   - Create drift detection
   - Create periodic verification script
   - Test: Verify drift detection works

---

## Testing Strategy

### For Each Phase

1. **Unit Testing:**
   - Test functions in isolation
   - Mock external dependencies (kubectl, aws cli)
   - Verify error handling

2. **Integration Testing:**
   - Run full deployment
   - Verify versions match at each step
   - Check logs for version information

3. **Manual Verification:**
   - Deploy to dev environment
   - Check `/version` endpoint
   - Verify frontend version in browser
   - Check deployment state file

### Test Scenarios

1. **Normal Deployment:**
   - Deploy with new image
   - Verify backend version updates
   - Verify frontend version updates
   - Verify CloudFront invalidation completes

2. **Partial Failure:**
   - Simulate invalidation failure
   - Verify deployment continues
   - Verify versions are still tracked

3. **Version Mismatch:**
   - Manually change pod image
   - Run verification
   - Verify mismatch is detected

---

## Success Criteria

### Phase 1 Success
- ✅ `CONTAINER_IMAGE` env var always matches container image after deployment
- ✅ `/version` endpoint returns correct version immediately after deployment
- ✅ No manual intervention needed to sync env var

### Phase 2 Success
- ✅ Frontend version is extracted and logged after build
- ✅ Version is available for verification

### Phase 3 Success
- ✅ Post-deployment verification runs automatically
- ✅ Version mismatches are detected and reported
- ✅ Deployment summary includes version information

### Phase 4 Success
- ✅ Invalidation IDs are tracked
- ✅ Invalidation status can be checked manually
- ✅ Completion time is logged

### Phase 5 Success
- ✅ Deployment state is saved after each deployment
- ✅ History can be viewed for debugging
- ✅ State file is human-readable

### Phase 6 Success
- ✅ Version drift is detected
- ✅ Verification can be run independently
- ✅ Issues are reported clearly

---

## Maintenance Notes

1. **State Files:**
   - `.frontend-version.txt` - Can be gitignored (temporary)
   - `.cloudfront-invalidations.log` - Should be gitignored
   - `.deployment-state.json` - Can be gitignored (optional to commit for team visibility)

2. **Log Rotation:**
   - Consider rotating `.cloudfront-invalidations.log` if it grows large
   - Keep last N deployments in state file (configurable)

3. **Error Handling:**
   - All verification steps should be non-blocking (warnings, not failures)
   - Deployment should succeed even if verification fails
   - Provide manual recovery commands

---

## Documentation Updates Needed

1. Update deployment documentation to mention version verification
2. Document manual verification commands
3. Document state file format
4. Add troubleshooting section for version mismatches

---

## Rollout Plan

1. **Week 1:** Implement Phase 1 (Backend sync)
2. **Week 2:** Implement Phase 3 (Verification)
3. **Week 3:** Implement Phase 2 (Frontend tracking)
4. **Week 4:** Implement Phase 4 (Invalidation tracking)
5. **Week 5:** Implement Phase 5 & 6 (State tracking, drift detection)

Each phase should be tested in dev environment before moving to next phase.
