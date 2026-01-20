# Refactor Evaluation: Consolidate ECS/EKS Modules

## Current Structure

### Modules:
- `modules/ecs/` - Base ECS resources (cluster, service, task definition)
- `modules/application-ecs/` - Composite: ECS + ALB + Frontend
- `modules/eks/` - Base EKS resources (cluster, node groups, OIDC)
- `modules/application-eks/` - Composite: EKS + Frontend

### Environment Configs:
- `environments/dev/application-ecs/` → `modules/application-ecs`
- `environments/dev/application-eks/` → `modules/application-eks`
- `environments/prod/application/` → `modules/application` (OLD, inconsistent)
- `environments/prod/eks/` → `modules/eks` (OLD, missing frontend)

## Proposed Refactor

1. Merge `modules/application-ecs/` → `modules/ecs/`
2. Merge `modules/application-eks/` → `modules/eks/`
3. Update all environment configs to point to consolidated modules

## Evaluation

### ✅ PROS (Consistency, Simplicity, Correctness):

1. **Simplicity**: One module per container type instead of two
   - Easier to understand: "ECS module" vs "application-ecs module"
   - No confusion about which module to use

2. **Consistency**: Same pattern for ECS and EKS
   - Both become self-contained modules
   - Both include frontend deployment

3. **Centralization**: All logic in one place
   - ECS: cluster + service + ALB + frontend in `modules/ecs/`
   - EKS: cluster + node groups + frontend in `modules/eks/`

4. **Naming**: Simpler, more intuitive
   - `ecs` instead of `application-ecs`
   - `eks` instead of `application-eks`

5. **Correctness**: Matches actual usage
   - ECS is always deployed with ALB + Frontend in this project
   - EKS is always deployed with Frontend in this project
   - No use case for standalone ECS/EKS without these components

6. **Environment Consistency**: Fixes prod inconsistency
   - `prod/application/` → `prod/ecs/` (consistent with dev)
   - `prod/eks/` → `prod/eks/` (now includes frontend like dev)

### ⚠️ CONS (Potential Issues):

1. **Module Reusability**: 
   - If someone wants ECS without ALB/Frontend, they can't
   - **Mitigation**: Not a use case in this project

2. **Breaking Change**:
   - Need to update all references (51+ occurrences found)
   - Need to migrate Terraform state
   - **Mitigation**: Can be done systematically with find/replace

3. **State Migration Complexity**:
   - Need to move state from `application-ecs` → `ecs`
   - Need to move state from `application-eks` → `eks`
   - **Mitigation**: Use `terraform state mv` commands or import existing resources

## Recommendation: ✅ APPROVE

**Reasoning:**
- The refactor improves consistency, simplicity, and correctness
- The cons are manageable (state migration is straightforward)
- The benefits outweigh the costs
- It fixes the prod inconsistency issue
- Aligns with the user's goal of centralizing logic

## Implementation Plan

### Phase 1: Merge Modules
1. Merge `modules/application-ecs/main.tf` into `modules/ecs/main.tf`
2. Merge `modules/application-ecs/variables.tf` into `modules/ecs/variables.tf`
3. Merge `modules/application-ecs/outputs.tf` into `modules/ecs/outputs.tf`
4. Repeat for `application-eks` → `eks`

### Phase 2: Update Environment Configs
1. Rename `environments/dev/application-ecs/` → `environments/dev/ecs/`
2. Rename `environments/dev/application-eks/` → `environments/dev/eks/`
3. Rename `environments/prod/application/` → `environments/prod/ecs/`
4. Update `environments/prod/eks/` to include frontend (match dev structure)
5. Update all `terragrunt.hcl` files to point to new module paths

### Phase 3: Update Scripts
1. Update `run_scripts/main_application_scripts/aws/terraform/deploy.sh`:
   - Change `application-ecs` → `ecs`
   - Change `application-eks` → `eks`
2. Update `run_scripts/main_application_scripts/aws/run.sh`:
   - Update references to new paths
3. Update all verification/cleanup scripts:
   - `fetch-deployment-info.sh`
   - `print-manual-hints.sh`
   - `deploy-frontend.sh`
   - `reference-check-frontend-bucket.sh`
   - `teardown.sh`

### Phase 4: State Migration
1. For dev environment:
   - `terraform state mv module.application-ecs module.ecs` (if needed)
   - `terraform state mv module.application-eks module.eks` (if needed)
2. For prod environment:
   - Import existing resources or migrate state
   - Handle the `application` → `ecs` migration

### Phase 5: Testing
1. Test `./run.sh deploy aws --container-type ecs dev --preempt`
2. Test `./run.sh deploy aws --container-type eks dev --preempt`
3. Verify both succeed and clean up correctly

## Files to Update

### Modules (4 files):
- `modules/ecs/main.tf` (merge from `application-ecs`)
- `modules/ecs/variables.tf` (merge from `application-ecs`)
- `modules/ecs/outputs.tf` (merge from `application-ecs`)
- `modules/eks/main.tf` (merge from `application-eks`)
- `modules/eks/variables.tf` (merge from `application-eks`)
- `modules/eks/outputs.tf` (merge from `application-eks`)

### Environment Configs (4 directories):
- `environments/dev/application-ecs/` → `environments/dev/ecs/`
- `environments/dev/application-eks/` → `environments/dev/eks/`
- `environments/prod/application/` → `environments/prod/ecs/`
- `environments/prod/eks/` (update to include frontend)

### Scripts (8+ files):
- `run_scripts/main_application_scripts/aws/terraform/deploy.sh`
- `run_scripts/main_application_scripts/aws/terraform/teardown.sh`
- `run_scripts/main_application_scripts/aws/run.sh`
- `run_scripts/main_application_scripts/aws/shared/deploy-frontend.sh`
- `run_scripts/main_application_scripts/aws/verification/fetch-deployment-info.sh`
- `run_scripts/main_application_scripts/aws/verification/print-manual-hints.sh`
- `run_scripts/main_application_scripts/aws/shared/resources_cleanup/helpers/reference-check-frontend-bucket.sh`

## Risk Assessment

**Low Risk:**
- Module merging is straightforward (copy/paste with adjustments)
- Script updates are find/replace operations
- State migration can be done incrementally

**Medium Risk:**
- Need to ensure all references are updated (51+ occurrences)
- Prod state migration may require import if old state is lost

**Mitigation:**
- Use grep to find all references before starting
- Test in dev environment first
- Keep backups of Terraform state before migration

