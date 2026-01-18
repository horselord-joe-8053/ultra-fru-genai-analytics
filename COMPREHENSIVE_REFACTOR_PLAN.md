# Comprehensive Refactoring Plan: AWS Deployment & Teardown Scripts

## Overview

**Goal**: Clean up and consolidate AWS deployment/teardown logic by:
1. **Eliminating auto-detection** - Use explicit `--container-type` parameter everywhere
2. **Extracting common logic** - Reduce ~80% code duplication
3. **Clear separation** - Container-specific logic in helpers, common logic in shared
4. **Complete teardown** - Proper EKS cleanup via kubectl

**Why Explicit Parameters > Auto-Detection**:
- ✅ **Clear intent**: Explicit `--container-type ecs|eks` makes behavior obvious
- ✅ **No ambiguity**: Avoids conflicts when both ECS and EKS exist
- ✅ **Easier debugging**: Know exactly which path is taken
- ✅ **Better testing**: Can test each container type independently
- ✅ **Simpler code**: No complex detection logic needed

---

## Current Problems

### 1. **Auto-Detection Issues**
- `teardown-resources.sh` uses auto-detection (checks ECS first, then EKS)
- If both clusters exist, only first one (ECS) gets cleaned up
- No way to explicitly target EKS when ECS also exists

### 2. **Code Duplication**
- `deploy_ecs_full()` and `deploy_eks_full()` have ~80% identical code
- Both handle: image build, infrastructure, database, data lake, frontend
- Only difference: application deployment method

### 3. **Logic Organization**
- EKS-specific logic (kubectl, manifests) embedded in `eks/deploy.sh`
- ECS teardown logic (~120 lines) embedded in `teardown-resources.sh`
- Frontend building logic duplicated in ECS/EKS `deploy.sh`

### 4. **Incomplete Teardown**
- EKS teardown only logs a note, doesn't actually clean up Kubernetes resources
- No kubectl cleanup before cluster deletion

---

## Refactored File Structure

```
run_scripts/main_application_scripts/aws/
├── shared/
│   ├── build-push-ecr.sh                    # ✅ Keep (already shared)
│   ├── deploy-frontend.sh                   # ✅ Keep (already shared)
│   ├── container-deploy-common.sh          # 🆕 NEW: Common deployment phases
│   └── helpers/
│       ├── prepare-frontend.sh              # 🆕 NEW: Frontend building logic
│       ├── check-kubectl.sh                 # 🆕 NEW: kubectl checks (from eks/deploy.sh)
│       ├── kubernetes-manifests.sh          # 🆕 NEW: K8s manifest operations (from eks/deploy.sh)
│       ├── stop-ecs-services.sh             # 🆕 NEW: ECS teardown (from teardown-resources.sh)
│       └── stop-eks-services.sh             # 🆕 NEW: EKS teardown (NEW - kubectl cleanup)
│   └── resources_cleanup/
│       └── teardown-resources.sh            # 🔄 REFACTORED: Use helpers, require --container-type
│           └── helpers/                     # ✅ Keep existing helpers
├── ecs/
│   └── deploy.sh                            # ✅ Keep minimal (or document as deprecated)
└── eks/
    └── deploy.sh                            # 🔄 SIMPLIFIED: Use shared helpers
```

---

## Phase 1: Extract Common Deployment Logic

### 1.1 Create `shared/container-deploy-common.sh`

**Purpose**: Common deployment phases used by both ECS and EKS

**Functions**:
```bash
# Phase 1.3: Check/build container image
deploy_phase_check_image() {
    # Extract from check_or_build_image() in run.sh
}

# Phase 2.2: Setup Terraform state bucket
deploy_phase_setup_state_bucket() {
    # Extract from terraform/setup-s3-bucket.sh invocation
}

# Phase 2.3: Deploy infrastructure
deploy_phase_deploy_infrastructure() {
    # Extract Terraform infrastructure deployment
}

# Phase 3: Setup database
deploy_phase_setup_database() {
    # Extract database setup logic
}

# Phase 4: Setup data lake (optional)
deploy_phase_setup_data_lake() {
    # Extract data lake setup (if enabled)
}

# Phase 5: Deploy frontend
deploy_phase_deploy_frontend() {
    # Extract frontend deployment logic
}
```

**Source**: Extract from `deploy_ecs_full()` and `deploy_eks_full()` in `run.sh`

---

### 1.2 Create `shared/helpers/prepare-frontend.sh`

**Purpose**: Build frontend if needed (extract from ECS/EKS `deploy.sh`)

**Function**:
```bash
build_frontend_if_needed() {
    # Check if frontend/dist exists
    # If not, or if source is newer, build frontend
    # Extract from lines 54-61 in ecs/deploy.sh and 340-347 in eks/deploy.sh
}
```

---

### 1.3 Create `shared/helpers/check-kubectl.sh`

**Purpose**: kubectl installation and configuration checks

**Functions**:
```bash
check_kubectl_installation() { ... }      # Check if kubectl is installed
check_kubectl_context() { ... }           # Check if context is configured
check_kubectl_cluster_access() { ... }    # Check if cluster is accessible
check_kubectl_complete() { ... }          # All-in-one check (from eks/deploy.sh:check_kubectl)
```

**Source**: Extract from `eks/deploy.sh` lines 51-86

---

### 1.4 Create `shared/helpers/kubernetes-manifests.sh`

**Purpose**: Kubernetes manifest operations

**Functions**:
```bash
find_manifests_directory() { ... }        # Find K8s manifests dir (from eks/deploy.sh:find_manifests_dir)
generate_kubernetes_manifests() { ... }   # Generate ConfigMap/Secret (from eks/deploy.sh:generate_manifests)
apply_kubernetes_manifests() { ... }      # Apply manifests (from eks/deploy.sh:apply_manifests)
verify_kubernetes_deployment() { ... }    # Verify deployment (from eks/deploy.sh:verify_deployment)
```

**Source**: Extract from `eks/deploy.sh` lines 88-312

---

## Phase 2: Extract Teardown Logic

### 2.1 Create `shared/helpers/stop-ecs-services.sh`

**Purpose**: Stop ECS services and tasks

**Function**:
```bash
stop_ecs_services() {
    # Parameters: cluster_name, aws_profile, aws_region, dry_run
    # Extract from teardown-resources.sh lines 251-370
    # - Scale services to 0
    # - Stop running tasks
    # - Wait for tasks to fully stop
}
```

---

### 2.2 Create `shared/helpers/stop-eks-services.sh` 🆕

**Purpose**: Stop EKS services (Kubernetes deployments/resources)

**Function**:
```bash
stop_eks_services() {
    # Parameters: cluster_name, aws_profile, aws_region, dry_run
    # NEW - Add proper EKS cleanup:
    # - Check kubectl availability
    # - Scale deployments to 0
    # - Wait for pods to terminate
    # - Delete deployments/services (optional - cluster deletion will handle it)
}
```

**Why This Is New**: Currently `teardown-resources.sh` only logs a note for EKS. This adds actual cleanup.

---

### 2.3 Refactor `shared/resources_cleanup/teardown-resources.sh`

**Changes**:

1. **Require `--container-type` parameter** (remove auto-detection):
```bash
# Argument parsing
CONTAINER_TYPE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --container-type)
            CONTAINER_TYPE="$2"
            if [[ "$CONTAINER_TYPE" != "ecs" && "$CONTAINER_TYPE" != "eks" ]]; then
                log_error "Invalid container type: $CONTAINER_TYPE (must be ecs or eks)"
                exit 1
            fi
            shift 2
            ;;
        # ... other args ...
    esac
done

# Require container type
if [ -z "$CONTAINER_TYPE" ]; then
    log_error "--container-type parameter is required"
    log_info "Usage: $0 <environment> --container-type <ecs|eks> [options...]"
    exit 1
fi
```

2. **Use helpers in `stop_services()`**:
```bash
stop_services() {
    log_step "Substep 1: Stopping ${CONTAINER_TYPE^^} Services and Tasks"
    
    local cluster_name="${PROJECT_NAME}-${ENVIRONMENT}-cluster"
    local helpers_dir="$SCRIPT_DIR/../helpers"
    
    if [ "$CONTAINER_TYPE" = "ecs" ]; then
        source "$helpers_dir/stop-ecs-services.sh"
        stop_ecs_services "$cluster_name" "$AWS_PROFILE" "$AWS_REGION" "$DRY_RUN"
    elif [ "$CONTAINER_TYPE" = "eks" ]; then
        source "$helpers_dir/stop-eks-services.sh"
        stop_eks_services "$cluster_name" "$AWS_PROFILE" "$AWS_REGION" "$DRY_RUN"
    fi
}
```

3. **Remove auto-detection logic** (lines 246-378)

---

## Phase 3: Simplify Deployment Scripts

### 3.1 Simplify `eks/deploy.sh`

**Before**: ~395 lines with all EKS logic embedded

**After**: ~100 lines, uses shared helpers

```bash
#!/bin/bash
# Main EKS deployment orchestrator (simplified)
# Uses shared helpers for common operations

source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"
source "$REPO_ROOT/run_scripts/main_application_scripts/aws/shared/helpers/prepare-frontend.sh"
source "$REPO_ROOT/run_scripts/main_application_scripts/aws/shared/helpers/check-kubectl.sh"
source "$REPO_ROOT/run_scripts/main_application_scripts/aws/shared/helpers/kubernetes-manifests.sh"

main() {
    log_step "Starting AWS EKS deployment"
    
    # Step 1: Check AWS credentials
    "$REPO_ROOT/run_scripts/main_application_scripts/aws/check-aws-credentials.sh" || exit 1
    
    # Step 2: Check kubectl (using helper)
    check_kubectl_complete || exit 1
    
    # Step 3: Build and push to ECR
    if [ "${SKIP_BUILD:-false}" = false ]; then
        "$REPO_ROOT/run_scripts/main_application_scripts/aws/shared/build-push-ecr.sh" || exit 1
    fi
    
    # Step 4: Deploy frontend
    if [ "${SKIP_FRONTEND:-false}" = false ]; then
        build_frontend_if_needed  # Using helper
        "$REPO_ROOT/run_scripts/main_application_scripts/aws/shared/deploy-frontend.sh" || exit 1
    fi
    
    # Step 5: Apply Kubernetes manifests (using helper)
    local manifests_dir
    manifests_dir=$(find_manifests_directory) || exit 1
    apply_kubernetes_manifests "$manifests_dir"
    verify_kubernetes_deployment
}
```

---

### 3.2 Update `ecs/deploy.sh` (optional)

**Current**: Mostly empty, just reminders

**Options**:
1. Keep minimal as-is (document it's deprecated/unused)
2. Remove if completely unused
3. Update to use shared helpers (if still used)

**Recommendation**: Keep minimal, add note that real ECS deployment happens in `run.sh`

---

## Phase 4: Refactor `run.sh` Deployment Functions

### 4.1 Simplify `deploy_ecs_full()`

**Before**: ~220 lines with all deployment logic embedded

**After**: ~80 lines, uses shared phases

```bash
deploy_ecs_full() {
    local deploy_start_time=$(date +%s)
    log_step "Starting complete ECS deployment workflow"
    
    # Source common phases
    source "$SCRIPT_DIR/shared/container-deploy-common.sh"
    
    # Get step information from main()
    local step_num="${CURRENT_STEP:-5}"
    local total_steps="${TOTAL_STEPS:-13}"
    
    # Phase 1.3: Check/build image (using shared phase)
    deploy_phase_check_image || exit 1
    step_num=$((step_num + 1))
    
    # Phase 2: Infrastructure (using shared phases)
    deploy_phase_setup_state_bucket || exit 1
    step_num=$((step_num + 1))
    
    deploy_phase_deploy_infrastructure || exit 1
    step_num=$((step_num + 1))
    
    # Phase 3: Database (using shared phase)
    deploy_phase_setup_database || exit 1
    step_num=$((step_num + 1))
    
    # Phase 4: Data lake (optional, using shared phase)
    if should_setup_data_lake; then
        deploy_phase_setup_data_lake || exit 1
        step_num=$((step_num + 1))
    fi
    
    # Phase 5: Frontend (using shared phase)
    deploy_phase_deploy_frontend || exit 1
    step_num=$((step_num + 1))
    
    # Phase 6: Application deployment (ECS-specific: already done via Terraform)
    # Terraform application layer deployment already happened in infrastructure phase
    
    # Phase 7: Verification (ECS-specific)
    # ... verification logic ...
}
```

---

### 4.2 Simplify `deploy_eks_full()`

**Before**: ~180 lines with all deployment logic embedded

**After**: ~100 lines, uses shared phases + EKS-specific helpers

```bash
deploy_eks_full() {
    local deploy_start_time=$(date +%s)
    log_step "Starting complete EKS deployment workflow"
    
    # Source common phases and EKS helpers
    source "$SCRIPT_DIR/shared/container-deploy-common.sh"
    source "$SCRIPT_DIR/shared/helpers/check-kubectl.sh"
    source "$SCRIPT_DIR/shared/helpers/kubernetes-manifests.sh"
    
    # Get step information from main()
    local step_num="${CURRENT_STEP:-5}"
    local total_steps="${TOTAL_STEPS:-11}"
    
    # Phase 1.3: Check/build image (using shared phase)
    deploy_phase_check_image || exit 1
    step_num=$((step_num + 1))
    
    # Phase 2: Infrastructure (using shared phases)
    deploy_phase_setup_state_bucket || exit 1
    step_num=$((step_num + 1))
    
    deploy_phase_deploy_infrastructure || exit 1  # EKS cluster only
    step_num=$((step_num + 1))
    
    # Phase 3: Database (using shared phase)
    deploy_phase_setup_database || exit 1
    step_num=$((step_num + 1))
    
    # Phase 4: Data lake (optional, using shared phase)
    if should_setup_data_lake; then
        deploy_phase_setup_data_lake || exit 1
        step_num=$((step_num + 1))
    fi
    
    # Phase 5: Frontend (using shared phase)
    deploy_phase_deploy_frontend || exit 1
    step_num=$((step_num + 1))
    
    # Phase 6: EKS-specific - Kubernetes manifests
    check_kubectl_complete || exit 1
    step_num=$((step_num + 1))
    
    local manifests_dir
    manifests_dir=$(find_manifests_directory) || exit 1
    apply_kubernetes_manifests "$manifests_dir" || exit 1
    step_num=$((step_num + 1))
    
    # Phase 7: Verification (EKS-specific)
    verify_kubernetes_deployment
}
```

---

## Phase 5: Update Preempt Logic

### 5.1 Update `run.sh` preempt call

**Current** (line 1007):
```bash
local destroy_cmd="$SCRIPT_DIR/shared/resources_cleanup/teardown-resources.sh $ENVIRONMENT"
```

**After**:
```bash
# Pass CONTAINER_TYPE explicitly to teardown
local destroy_cmd="$SCRIPT_DIR/shared/resources_cleanup/teardown-resources.sh $ENVIRONMENT --container-type $CONTAINER_TYPE"
```

**Why**: Makes container type explicit, no ambiguity

---

## Migration Strategy

### Step 1: Create Helper Files (Non-Breaking)
- Create all new helper files in `shared/helpers/`
- Keep existing scripts unchanged
- Test helpers independently

### Step 2: Update Teardown (Backward Compatible Initially)
- Add `--container-type` parameter to `teardown-resources.sh`
- Support both explicit parameter and auto-detection (for transition)
- Add deprecation warning for auto-detection usage
- After verification, remove auto-detection entirely

### Step 3: Update Deployment Scripts
- Update `eks/deploy.sh` to use helpers
- Update `deploy_ecs_full()` and `deploy_eks_full()` in `run.sh`
- Test both ECS and EKS deployments

### Step 4: Remove Old Code
- Remove duplicate logic from `run.sh`
- Remove embedded logic from `eks/deploy.sh`
- Remove auto-detection from `teardown-resources.sh`

### Step 5: Verification
- Test ECS deployment: `./run.sh deploy --container-type ecs dev`
- Test EKS deployment: `./run.sh deploy --container-type eks dev`
- Test ECS teardown: `./run.sh deploy --container-type ecs dev --preempt`
- Test EKS teardown: `./run.sh deploy --container-type eks dev --preempt`

---

## Benefits

### 1. **Explicit Parameters Eliminate Ambiguity**
- ✅ `--container-type ecs|eks` makes behavior clear
- ✅ No guessing which container type is being used
- ✅ No conflicts when both ECS and EKS exist

### 2. **Reduced Duplication**
- ✅ ~80% code reduction in `deploy_ecs_full()` and `deploy_eks_full()`
- ✅ Common phases extracted to `container-deploy-common.sh`
- ✅ Container-specific logic in dedicated helpers

### 3. **Complete Teardown**
- ✅ EKS teardown now properly cleans up Kubernetes resources
- ✅ kubectl cleanup before cluster deletion
- ✅ Both ECS and EKS teardown use same pattern

### 4. **Better Organization**
- ✅ Clear separation: common vs. container-specific
- ✅ Helpers can be tested independently
- ✅ Easier to understand and maintain

### 5. **Cleaner Code**
- ✅ `eks/deploy.sh`: 395 lines → ~100 lines (75% reduction)
- ✅ `teardown-resources.sh`: Cleaner, uses helpers
- ✅ `run.sh`: Deployment functions much simpler

---

## Files Created

1. `shared/container-deploy-common.sh` - Common deployment phases
2. `shared/helpers/prepare-frontend.sh` - Frontend building logic
3. `shared/helpers/check-kubectl.sh` - kubectl checks
4. `shared/helpers/kubernetes-manifests.sh` - K8s manifest operations
5. `shared/helpers/stop-ecs-services.sh` - ECS teardown logic
6. `shared/helpers/stop-eks-services.sh` - EKS teardown logic (NEW)

## Files Modified

1. `shared/resources_cleanup/teardown-resources.sh` - Use helpers, require --container-type
2. `eks/deploy.sh` - Simplify to use helpers
3. `run.sh` - Refactor `deploy_ecs_full()` and `deploy_eks_full()` to use shared phases
4. `ecs/deploy.sh` - Optional: add deprecation note or remove

## Files Unchanged

- `shared/build-push-ecr.sh` - Already shared, keep as-is
- `shared/deploy-frontend.sh` - Already shared, keep as-is
- `shared/resources_cleanup/helpers/*` - Keep existing helpers

---

## Implementation Order

1. **Phase 2 (Teardown)** - Fix incomplete EKS teardown first (highest priority)
2. **Phase 1 (Helpers)** - Extract common helpers
3. **Phase 3 (Scripts)** - Simplify `eks/deploy.sh`
4. **Phase 4 (run.sh)** - Refactor deployment functions
5. **Phase 5 (Preempt)** - Update preempt logic

---

## Independent Teardown Usage

**Yes!** Teardown scripts can be run independently. After refactoring, `teardown-resources.sh` will accept `--container-type` parameter.

### Usage

```bash
./run_scripts/main_application_scripts/aws/shared/resources_cleanup/teardown-resources.sh <environment> --container-type <ecs|eks> [options...]
```

### Examples

#### ECS Teardown

**Dry-run (preview what would be destroyed)**:
```bash
./run_scripts/main_application_scripts/aws/shared/resources_cleanup/teardown-resources.sh dev --container-type ecs --dry-run
```

**Interactive (requires confirmation)**:
```bash
./run_scripts/main_application_scripts/aws/shared/resources_cleanup/teardown-resources.sh dev --container-type ecs
```

**Force (skip confirmation)**:
```bash
./run_scripts/main_application_scripts/aws/shared/resources_cleanup/teardown-resources.sh dev --container-type ecs --force
```

#### EKS Teardown

**Dry-run (preview what would be destroyed)**:
```bash
./run_scripts/main_application_scripts/aws/shared/resources_cleanup/teardown-resources.sh dev --container-type eks --dry-run
```

**Interactive (requires confirmation)**:
```bash
./run_scripts/main_application_scripts/aws/shared/resources_cleanup/teardown-resources.sh dev --container-type eks
```

**Force (skip confirmation)**:
```bash
./run_scripts/main_application_scripts/aws/shared/resources_cleanup/teardown-resources.sh dev --container-type eks --force
```

#### Production Teardown (Use with Caution!)

```bash
# ECS production
./run_scripts/main_application_scripts/aws/shared/resources_cleanup/teardown-resources.sh prod --container-type ecs --force

# EKS production
./run_scripts/main_application_scripts/aws/shared/resources_cleanup/teardown-resources.sh prod --container-type eks --force
```

#### Clean Local Docker Images Only

**Note**: `--clean-local-only` works with either `ecs` or `eks` (or any container type) since it only cleans local Docker images and doesn't interact with AWS container services. The `--container-type` parameter is still required for consistency, but the value doesn't affect local image cleanup.

```bash
# Skip AWS teardown, only clean local images (ECS or EKS - both work)
./run_scripts/main_application_scripts/aws/shared/resources_cleanup/teardown-resources.sh dev --container-type ecs --force --clean-local-only
./run_scripts/main_application_scripts/aws/shared/resources_cleanup/teardown-resources.sh dev --container-type eks --force --clean-local-only

# Both commands above do the same thing (only clean local Docker images)
```

### Integration with run.sh

**Via preempt flag** (automatically passes `--container-type`):
```bash
# ECS preempt
./run_scripts/main_application_scripts/aws/run.sh deploy --container-type ecs dev --preempt

# EKS preempt
./run_scripts/main_application_scripts/aws/run.sh deploy --container-type eks dev --preempt
```

### Options

- `<environment>` - Required: `dev`, `staging`, or `prod`
- `--container-type <ecs|eks>` - **Required after refactoring**: Specifies which container type to tear down
- `--force` or `--skip-confirmation` - Skip confirmation prompts
- `--dry-run` - Preview what would be destroyed without actually destroying
- `--clean-local-only` - Only clean local Docker images (skip AWS teardown)
- `--help` or `-h` - Show help message

### What Gets Destroyed

**For `--container-type ecs`**:
1. Stop ECS services (scale to 0)
2. Stop all running tasks
3. Empty S3 buckets
4. Destroy Terraform infrastructure (application layer → infrastructure layer)
5. Clean up local Docker images
6. Clean up orphaned AWS resources

**For `--container-type eks`**:
1. Stop EKS services (scale Kubernetes deployments to 0)
2. Delete Kubernetes deployments/services
3. Wait for pods to terminate
4. Empty S3 buckets
5. Destroy Terraform infrastructure (EKS layer → infrastructure layer)
6. Clean up local Docker images
7. Clean up orphaned AWS resources

---

## Testing Checklist

### ECS Deployment
- [ ] `./run.sh deploy --container-type ecs dev` works
- [ ] All phases complete successfully
- [ ] Frontend accessible
- [ ] API accessible

### EKS Deployment
- [ ] `./run.sh deploy --container-type eks dev` works
- [ ] kubectl checks pass
- [ ] Kubernetes manifests applied
- [ ] Pods running
- [ ] Frontend accessible
- [ ] API accessible

### ECS Teardown (Independent)
- [ ] `./run_scripts/.../teardown-resources.sh dev --container-type ecs --dry-run` shows preview
- [ ] `./run_scripts/.../teardown-resources.sh dev --container-type ecs` requires confirmation
- [ ] `./run_scripts/.../teardown-resources.sh dev --container-type ecs --force` destroys resources
- [ ] ECS services scaled to 0
- [ ] Tasks stopped
- [ ] Infrastructure destroyed

### EKS Teardown (Independent)
- [ ] `./run_scripts/.../teardown-resources.sh dev --container-type eks --dry-run` shows preview
- [ ] `./run_scripts/.../teardown-resources.sh dev --container-type eks` requires confirmation
- [ ] `./run_scripts/.../teardown-resources.sh dev --container-type eks --force` destroys resources
- [ ] Kubernetes deployments scaled to 0
- [ ] Pods terminated
- [ ] EKS cluster destroyed

### ECS Teardown (Via Preempt)
- [ ] `./run.sh deploy --container-type ecs dev --preempt` works
- [ ] ECS services scaled to 0
- [ ] Tasks stopped
- [ ] Infrastructure destroyed

### EKS Teardown (Via Preempt)
- [ ] `./run.sh deploy --container-type eks dev --preempt` works
- [ ] Kubernetes deployments scaled to 0
- [ ] Pods terminated
- [ ] EKS cluster destroyed

### Parameter Validation
- [ ] `--container-type` required in teardown (error if missing)
- [ ] Invalid container type rejected (error message)
- [ ] No auto-detection fallback (explicit parameter only)

---

## Summary

**Key Principle**: **Explicit Parameters > Auto-Detection**

- ✅ Require `--container-type` parameter everywhere
- ✅ Remove all auto-detection logic
- ✅ Clear intent, no ambiguity
- ✅ Better code organization
- ✅ Complete teardown for both ECS and EKS

**Impact**: 
- ~80% code reduction in deployment functions
- Complete EKS teardown (currently missing)
- Cleaner, more maintainable code structure
- Easier to test and debug

---

**Status**: Ready for implementation

**Priority**: 
1. **High**: Fix EKS teardown (incomplete)
2. **High**: Remove auto-detection (adds ambiguity)
3. **Medium**: Extract common logic (reduces duplication)
4. **Medium**: Simplify scripts (improves maintainability)

---

**Last Updated**: 2026-01-17

