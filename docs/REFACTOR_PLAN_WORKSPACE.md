# 🏗️ FRU System Refactor Plan: Workspace-Based Architecture

**Status**: Draft for Review  
**Created**: 2026-02-06  
**Author**: System Architecture Review

---

## 📋 Executive Summary

This document proposes a fundamental restructuring of the FRU GenAI Analytics system from a **monolithic multi-target deployment** to a **workspace-based modular architecture** aligned with industry best practices for Infrastructure as Code (IaC).

### Current State
- Single project with all deployment mechanisms (EKS, ECS, local-kube, local-nonkube)
- Heavy shell scripting orchestration (~108 files in `orchestration/`)
- Single entry point (`run.sh`, `teardown.sh`) managing all targets
- Complex dependency management across deployment types

### Proposed State
- **Workspace** containing independent projects
- **Core application** as standalone project (deployment-agnostic)
- **Deployment projects** as separate IaC implementations
- **Terraform/Terragrunt-first** approach with minimal scripting
- **Python over Shell** for necessary automation

---

## 🎯 Goals & Principles

### Primary Goals
1. **Align with Industry Best Practices**: Adopt the "infra/live" pattern used by Terragrunt and major IaC projects
2. **Reduce Complexity**: Eliminate unnecessary coupling between deployment mechanisms
3. **Improve Maintainability**: Clear separation of concerns, easier to extend
4. **Enable Multi-Cloud**: Structure that naturally supports GCP, Oracle, Azure
5. **Preserve Lessons Learned**: Retain all hard-won knowledge from current implementation

### Guiding Principles
1. **IaC-First**: Terraform/Terragrunt manages infrastructure; scripts only for what IaC can't do
2. **Deployment-Agnostic Core**: Application code knows nothing about deployment
3. **Python Over Shell**: When scripting is needed, prefer Python for testability and maintainability
4. **Explicit Over Implicit**: Clear dependencies, no hidden orchestration
5. **Progressive Enhancement**: Start with AWS, design for multi-cloud

---

## 📐 Proposed Architecture

### Workspace Structure

```
fru-workspace/
├── fru-core/                          # 1.1 Core Application (deployment-agnostic)
│   ├── backend/                       # Flask API, agentic query processing
│   ├── frontend/                      # React frontend
│   ├── sql/                           # Database schemas (PostgreSQL + pgvector)
│   ├── spark/                         # Spark + Delta Lake analytics
│   ├── docker/                        # Local development containers
│   ├── .env.example                   # Application configuration template
│   └── README.md                      # Core app documentation
│
├── fru-deploy-aws-eks/                # 1.2.1.1 AWS EKS Deployment
│   ├── infra/                         # Terragrunt "live" infrastructure
│   │   ├── _global/                   # Global resources (ECR, S3 state bucket)
│   │   ├── us-east-1/                 # Region-specific
│   │   │   ├── dev/                   # Environment
│   │   │   │   ├── vpc/               # VPC layer
│   │   │   │   ├── aurora/            # Database layer
│   │   │   │   ├── eks/               # EKS cluster layer
│   │   │   │   └── frontend/          # CloudFront + S3 layer
│   │   │   └── prod/                  # Production environment
│   │   └── terragrunt.hcl             # Root config
│   ├── modules/                       # Terraform modules
│   │   ├── vpc/
│   │   ├── aurora/
│   │   ├── eks/
│   │   └── frontend/
│   ├── scripts/                       # Python automation (minimal)
│   │   ├── deploy.py                  # Orchestrates terragrunt
│   │   ├── import_state.py            # State reconciliation
│   │   └── lib/                       # Shared utilities
│   ├── .env.example                   # Deployment configuration
│   └── README.md                      # EKS deployment guide
│
├── fru-deploy-aws-ecs/                # 1.2.2.1 AWS ECS Deployment
│   ├── infra/                         # Similar structure to EKS
│   │   ├── _global/
│   │   ├── us-east-1/
│   │   │   ├── dev/
│   │   │   │   ├── vpc/
│   │   │   │   ├── aurora/
│   │   │   │   ├── ecs/               # ECS + ALB layer
│   │   │   │   └── frontend/
│   │   │   └── prod/
│   │   └── terragrunt.hcl
│   ├── modules/
│   ├── scripts/
│   ├── .env.example
│   └── README.md
│
├── fru-deploy-local-kube/             # 1.2.3 Local Kubernetes (future)
│   └── (minikube/kind setup)
│
├── fru-deploy-local-native/           # 1.2.4 Local Native (future)
│   └── (docker-compose setup)
│
├── docs/                              # Shared documentation
│   ├── README_WAR_STORIES.md          # Preserved lessons learned
│   ├── ARCHITECTURE.md                # System architecture
│   └── MULTI_CLOUD_GUIDE.md           # Multi-cloud extension guide
│
└── README.md                          # Workspace overview
```

---

## 🔍 Detailed Component Analysis

### 1. Core Application (`fru-core/`)

**Purpose**: Deployment-agnostic application code

**Contents**:
- Backend API (Flask, agentic query processing)
- Frontend (React, TypeScript)
- Database schemas (SQL)
- Spark analytics jobs
- Docker configurations for local dev

**Key Changes from Current**:
- ✅ **Keep**: All code from `module_app_core/`
- ✅ **Keep**: SQL schemas, Spark jobs
- ✅ **Keep**: Docker Compose for local development
- ❌ **Remove**: All deployment-specific code
- ❌ **Remove**: AWS-specific configurations

**Configuration**:
- `.env.example` with application-level settings only
- No cloud provider credentials
- No infrastructure references

**Build Artifacts**:
- Docker images (tagged for deployment projects to consume)
- Frontend build artifacts (for S3/CloudFront deployment)

---

### 2. AWS EKS Deployment (`fru-deploy-aws-eks/`)

**Purpose**: Production-ready EKS deployment following Terragrunt best practices

**Structure**: "infra/live" pattern (industry standard)

```
infra/
├── _global/                           # Account-level resources
│   ├── ecr/                           # Container registry
│   │   └── terragrunt.hcl
│   └── s3-state/                      # Terraform state bucket
│       └── terragrunt.hcl
│
├── us-east-1/                         # Region
│   ├── region.hcl                     # Region config
│   ├── dev/                           # Environment
│   │   ├── env.hcl                    # Environment config
│   │   ├── vpc/
│   │   │   └── terragrunt.hcl         # VPC + subnets + NAT
│   │   ├── aurora/
│   │   │   └── terragrunt.hcl         # Aurora PostgreSQL + pgvector
│   │   ├── eks/
│   │   │   └── terragrunt.hcl         # EKS cluster + node groups
│   │   ├── k8s-app/                   # Kubernetes resources
│   │   │   └── terragrunt.hcl         # Helm charts, manifests
│   │   └── frontend/
│   │       └── terragrunt.hcl         # CloudFront + S3
│   └── prod/
│       └── (same structure)
│
└── terragrunt.hcl                     # Root configuration
```

**Key Features**:
1. **Dependency Management**: Terragrunt handles layer dependencies automatically
2. **DRY Configuration**: Shared configs in `region.hcl`, `env.hcl`, `terragrunt.hcl`
3. **Mock Outputs**: All layers use `mock_outputs` + `try()` for robust teardown
4. **State Management**: S3 backend with locking, organized by layer

**Deployment Flow**:
```bash
# Simple, declarative
cd infra/us-east-1/dev
terragrunt run-all apply

# Or layer-by-layer
cd vpc && terragrunt apply
cd ../aurora && terragrunt apply
cd ../eks && terragrunt apply
cd ../k8s-app && terragrunt apply
cd ../frontend && terragrunt apply
```

**Minimal Scripting** (`scripts/`):
- `deploy.py`: Thin wrapper around `terragrunt run-all apply`
  - Validates prerequisites
  - Builds and pushes Docker image
  - Runs terragrunt
  - Displays outputs
- `import_state.py`: Reconciles Terraform state with AWS reality
  - Used after manual changes or "nuclear" cleanup
  - Python with boto3 (not shell + AWS CLI)
- `lib/`: Shared utilities (logging, AWS helpers, state management)

**No Shell Orchestration**:
- ❌ No `run.sh` with complex phase management
- ❌ No `teardown.sh` with pre-destroy hooks
- ✅ Terragrunt handles dependencies
- ✅ Python scripts for what IaC can't do

---

### 3. AWS ECS Deployment (`fru-deploy-aws-ecs/`)

**Purpose**: Production-ready ECS deployment (similar structure to EKS)

**Structure**:
```
infra/
├── _global/                           # Shared with EKS
│   ├── ecr/
│   └── s3-state/
├── us-east-1/
│   ├── dev/
│   │   ├── vpc/                       # Same VPC module as EKS
│   │   ├── aurora/                    # Same Aurora module as EKS
│   │   ├── ecs/                       # ECS + ALB (different from EKS)
│   │   │   └── terragrunt.hcl
│   │   └── frontend/                  # Same frontend module as EKS
│   └── prod/
└── terragrunt.hcl
```

**Key Difference from EKS**:
- `ecs/` layer instead of `eks/` + `k8s-app/`
- ALB managed by Terraform (not Kubernetes Ingress Controller)
- Otherwise identical structure

**Module Reuse**:
- ✅ VPC module: Shared with EKS
- ✅ Aurora module: Shared with EKS
- ✅ Frontend module: Shared with EKS
- ❌ Compute layer: ECS-specific (ALB + ECS)

---

## 🔧 Migration Strategy

### Phase 1: Setup Workspace & Core (Week 1)

**Objective**: Extract core application into standalone project

**Tasks**:
1. Create `fru-workspace/` directory
2. Create `fru-core/` project:
   - Copy `module_app_core/` → `fru-core/backend/`, `fru-core/frontend/`
   - Copy SQL schemas → `fru-core/sql/`
   - Copy Spark jobs → `fru-core/spark/`
   - Create `fru-core/docker/` with docker-compose for local dev
   - Create `fru-core/.env.example` (application settings only)
   - Write `fru-core/README.md`
3. Test core application locally (docker-compose)
4. Verify no deployment-specific code remains

**Success Criteria**:
- Core app runs locally without any AWS/cloud dependencies
- Docker images build successfully
- All tests pass

---

### Phase 2: AWS EKS Deployment Project (Week 2-3)

**Objective**: Create production-ready EKS deployment following best practices

**Tasks**:
1. Create `fru-deploy-aws-eks/` project structure
2. Design Terraform modules (based on current `module_infra_*` but refactored):
   - `modules/vpc/`: VPC, subnets, NAT, VPC endpoints
   - `modules/aurora/`: Aurora PostgreSQL + pgvector
   - `modules/eks/`: EKS cluster, node groups, OIDC
   - `modules/k8s-app/`: Helm charts, Kubernetes manifests
   - `modules/frontend/`: CloudFront + S3
3. Create Terragrunt "live" structure:
   - `infra/_global/`: ECR, S3 state bucket
   - `infra/us-east-1/dev/`: Development environment
   - `infra/us-east-1/prod/`: Production environment
4. Implement dependency management:
   - All layers use `dependency` blocks
   - All layers use `mock_outputs` + `try()` pattern
   - Test partial teardown scenarios
5. Create Python automation:
   - `scripts/deploy.py`: Orchestrates deployment
   - `scripts/import_state.py`: State reconciliation
   - `scripts/lib/`: Shared utilities
6. Documentation:
   - `README.md`: Deployment guide
   - `.env.example`: Configuration template
7. **Preserve War Stories**:
   - Review `README_WAR_STORIES.md`
   - Implement lessons learned:
     - Bidirectional lock detection (War Story #33)
     - Mock outputs for all commands (War Story #34)
     - Fail-fast behavior
     - State reconciliation before destroy

**Success Criteria**:
- Deploy to dev environment from scratch
- Teardown works cleanly (including partial teardown)
- State import works after manual changes
- No shell scripts (except minimal wrappers)

---

### Phase 3: AWS ECS Deployment Project (Week 4)

**Objective**: Create ECS deployment reusing modules from EKS

**Tasks**:
1. Create `fru-deploy-aws-ecs/` project
2. Reuse modules from EKS:
   - Copy `vpc/`, `aurora/`, `frontend/` modules
   - Create new `ecs/` module (ECS + ALB)
3. Create Terragrunt "live" structure (same as EKS)
4. Implement Python automation (reuse from EKS)
5. Test deployment and teardown

**Success Criteria**:
- Deploy to dev environment
- Teardown works cleanly
- Module reuse validated

---

### Phase 4: Multi-Region Support (Week 5)

**Objective**: Validate multi-region design

**Tasks**:
1. Add `us-west-2/` to EKS deployment
2. Test cross-region deployment
3. Document multi-region patterns

**Success Criteria**:
- Deploy to multiple regions
- Region-specific configuration works

---

### Phase 5: Documentation & Knowledge Transfer (Week 6)

**Objective**: Comprehensive documentation

**Tasks**:
1. Migrate `README_WAR_STORIES.md` to workspace
2. Create `docs/ARCHITECTURE.md`
3. Create `docs/MULTI_CLOUD_GUIDE.md`
4. Update all READMEs
5. Create migration guide from old structure

**Success Criteria**:
- All war stories preserved
- Clear migration path documented
- Multi-cloud extension guide complete

---

## 📊 Comparison: Current vs Proposed

| Aspect | Current | Proposed |
|--------|---------|----------|
| **Structure** | Monolithic | Workspace with independent projects |
| **Entry Point** | Single `run.sh` for all targets | Per-project deployment |
| **Orchestration** | Heavy shell scripting (~108 files) | Terragrunt + minimal Python |
| **IaC Pattern** | Custom module structure | Industry-standard "infra/live" |
| **Dependency Mgmt** | Manual in shell scripts | Terragrunt automatic |
| **State Reconciliation** | Shell + AWS CLI | Python + boto3 |
| **Multi-Cloud** | Difficult to extend | Natural extension point |
| **Testing** | Hard to test shell scripts | Python scripts are testable |
| **Maintainability** | Complex coupling | Clear separation |

---

## 🎓 Lessons Learned (Preserved)

### From Current Implementation

**War Stories to Preserve**:
1. **State Lock Handling** (War Story #33):
   - Detect both "acquiring" and "releasing" errors
   - Handle S3 PreconditionFailed (412) gracefully
   - Fail-fast on unrecoverable errors
   - **Implementation**: `scripts/lib/terraform_helpers.py`

2. **Mock Outputs** (War Story #34):
   - All layers use `mock_outputs` + `try()` pattern
   - Whitelist `import`, `destroy`, `state` commands
   - Enable partial teardown scenarios
   - **Implementation**: All `terragrunt.hcl` files

3. **Dependency Resolution**:
   - Terragrunt handles layer dependencies
   - No manual ordering in scripts
   - **Implementation**: `dependency` blocks in Terragrunt

4. **Fail-Fast Behavior**:
   - Exit immediately on errors
   - No silent failures
   - **Implementation**: Python scripts with proper error handling

5. **Centralized Configuration**:
   - `.env` file for all settings
   - Clear separation: application vs deployment config
   - **Implementation**: `.env.example` in each project

### From Industry Best Practices

**Terragrunt "infra/live" Pattern**:
- Used by Gruntwork, HashiCorp, and major IaC projects
- Clear hierarchy: global → region → environment → layer
- DRY configuration with inheritance
- **Reference**: https://terragrunt.gruntwork.io/docs/getting-started/quick-start/

**Python Over Shell**:
- Testable, maintainable, cross-platform
- Rich ecosystem (boto3, click, pytest)
- Better error handling and logging
- **Reference**: Industry consensus for infrastructure automation

---

## 🚀 Quick Start (Proposed)

### Deploy to AWS EKS (Dev)

```bash
# 1. Build core application
cd fru-core
docker build -t fru-api:latest .

# 2. Deploy to AWS EKS
cd ../fru-deploy-aws-eks
cp .env.example .env
# Edit .env with your AWS credentials and settings

# Deploy all layers
python scripts/deploy.py --env dev --region us-east-1

# Or deploy layer-by-layer
cd infra/us-east-1/dev
terragrunt run-all apply
```

### Teardown

```bash
cd fru-deploy-aws-eks/infra/us-east-1/dev
terragrunt run-all destroy
```

**No complex orchestration scripts needed!**

---

## ❓ Open Questions & Decisions

### 1. Module Sharing Between EKS and ECS

**Question**: Should EKS and ECS projects share Terraform modules?

**Options**:
- **A**: Separate modules (easier to maintain, no coupling)
- **B**: Shared modules in workspace root (DRY, but coupling)
- **C**: Shared modules via Git submodule (versioned sharing)

**Recommendation**: **Option A** initially, **Option C** if significant duplication emerges

**Rationale**: Premature abstraction is worse than duplication. Start separate, refactor if needed.

---

### 2. Global Resources (_global/)

**Question**: Should ECR and S3 state bucket be in each deployment project or shared?

**Options**:
- **A**: Each project has own ECR and state bucket
- **B**: Shared `fru-global-aws/` project for global resources

**Recommendation**: **Option A** for now

**Rationale**: 
- Simpler to start
- Each deployment is truly independent
- Can refactor to shared later if needed

---

### 3. Local Development

**Question**: Should local development be in `fru-core/` or separate project?

**Options**:
- **A**: `fru-core/docker/` (current proposal)
- **B**: Separate `fru-deploy-local-native/` project

**Recommendation**: **Option A**

**Rationale**: Local dev is tightly coupled to core app, not infrastructure

---

### 4. Python Script Structure

**Question**: Should Python scripts use a framework (Click, Typer) or plain argparse?

**Recommendation**: **Click** for CLI framework

**Rationale**:
- Industry standard for Python CLIs
- Better UX (help text, validation)
- Composable commands

---

## 📝 Action Items

### Immediate (This Week)
- [ ] Review and approve this plan
- [ ] Create `fru-workspace/` directory
- [ ] Set up `fru-core/` project structure
- [ ] Test core application locally

### Short-Term (Next 2 Weeks)
- [ ] Implement `fru-deploy-aws-eks/` project
- [ ] Migrate Terraform modules
- [ ] Create Python automation scripts
- [ ] Test deployment and teardown

### Medium-Term (Next Month)
- [ ] Implement `fru-deploy-aws-ecs/` project
- [ ] Test multi-region deployment
- [ ] Complete documentation

### Long-Term (Future)
- [ ] Add GCP deployment project
- [ ] Add Oracle Cloud deployment project
- [ ] Implement local Kubernetes deployment

---

## 🎯 Success Metrics

### Technical Metrics
- **Deployment Time**: < 20 minutes for full stack (current: ~30 minutes)
- **Teardown Time**: < 15 minutes for full stack (current: ~20 minutes)
- **Script Lines**: < 500 lines Python (current: ~3000 lines shell)
- **Test Coverage**: > 80% for Python scripts (current: 0%)

### Operational Metrics
- **Time to Add Region**: < 1 hour (current: ~1 day)
- **Time to Add Cloud Provider**: < 1 week (current: ~1 month)
- **Onboarding Time**: < 2 hours (current: ~1 day)

### Quality Metrics
- **Failed Deployments**: < 5% (current: ~15%)
- **State Drift Issues**: < 1 per month (current: ~5 per month)
- **Documentation Coverage**: 100% of components (current: ~60%)

---

## 🔚 Conclusion

This refactor transforms FRU from a **monolithic multi-target deployment** to a **modular workspace architecture** aligned with industry best practices.

**Key Benefits**:
1. **Simpler**: Each deployment project is independent and focused
2. **Maintainable**: Clear separation of concerns, testable Python scripts
3. **Extensible**: Easy to add regions and cloud providers
4. **Robust**: Preserves all lessons learned, implements fail-fast patterns
5. **Professional**: Follows Terragrunt/IaC best practices

**Trade-offs**:
1. **More Projects**: 4+ projects instead of 1 (but each is simpler)
2. **Initial Effort**: ~6 weeks to implement (but long-term savings)
3. **Learning Curve**: Team needs to learn Terragrunt patterns (but industry-standard)

**Recommendation**: **Proceed with refactor**

The benefits significantly outweigh the costs, and the resulting architecture will be easier to maintain, extend, and operate.

---

## 📚 References

- [Terragrunt Quick Start](https://terragrunt.gruntwork.io/docs/getting-started/quick-start/)
- [Terraform Best Practices](https://www.terraform-best-practices.com/)
- [AWS Well-Architected Framework](https://aws.amazon.com/architecture/well-architected/)
- Current `README_WAR_STORIES.md` (33 war stories)
- Current `docs/README_INFRA.md` (723 lines of IaC documentation)
