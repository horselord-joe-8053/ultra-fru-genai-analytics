# Environment Management Best Practices

## Scope and Architecture Overview

**⚠️ IMPORTANT: This document focuses on Kubernetes-based cloud deployments** (EKS, GKE, AKS, OKE), not cloud-native approaches (ECS, Cloud Run, Container Instances).

### Multi-Dimensional Architecture

This project supports deployments across **4 dimensions**:

1. **Dimension 1: Deployment Location**
   - **Local:** Developer machine (Docker Compose, minikube)
   - **Cloud:** Cloud providers (AWS, GCP, Azure, Oracle)

2. **Dimension 2: Cloud Providers** (Cloud Only)
   - AWS, GCP, Azure, Oracle

3. **Dimension 3: Orchestration Approach** (Cloud Only)
   - **Kubernetes-based:** EKS, GKE, AKS, OKE (uses `infra/k8s/` manifests)
   - **Cloud-native:** ECS, Cloud Run, Container Instances (uses cloud provider's native orchestration)

4. **Dimension 4: Building Environment**
   - **Local:** Single environment (no dev/staging/prod distinction)
     - Serves as "pre-dev" of cloud dev
     - Focus: Code logic and function validation
   - **Cloud:** Dev, Staging, Prod environments
     - Dev: Development, integration testing
     - Staging: Pre-production testing
     - Prod: Production, live users

**Building Environment Clarification:**
> Technically, both local and cloud could have dev/staging/prod. However, local uses a single environment (acts as "pre-dev" of cloud dev), while cloud has distinct dev/staging/prod environments. See `TERMINOLOGY_CLARIFICATION.md` for detailed analysis.

---

## Quick Reference

### Environment Terminology

| Environment Type | Building Environment | Purpose | Configuration Source | Authentication |
|-----------------|---------------------|---------|---------------------|----------------|
| **Local** | Single (pre-dev) | Code validation, testing | `.env` file | AWS profiles (`.env`) |
| **Cloud Dev** | Dev | Development, integration testing | Terraform outputs | OIDC/IRSA (Kubernetes) or IAM roles (cloud-native) |
| **Cloud Staging** | Staging | Pre-production testing | Terraform outputs | OIDC/IRSA (Kubernetes) or IAM roles (cloud-native) |
| **Cloud Prod** | Prod | Production, live users | Terraform outputs | OIDC/IRSA (Kubernetes) or IAM roles (cloud-native) |

### Key Principles

1. **Terraform authentication:** `.env` file (AWS_PROFILE) - needed for ALL Terraform operations (local and cloud)
2. **Local development config:** `.env` file - database connection, local secrets
3. **Cloud Kubernetes config:** Terraform outputs - namespace, ingress_host, etc. (NOT from `.env`)
4. **Cloud pod authentication:** OIDC/IRSA or IAM roles - no credentials needed in pods
5. **Clear boundaries:** 
   - `.env` = Authentication (who you are) + Local development config
   - Terraform outputs = Configuration values (what to use) for cloud deployments

---

## Ingress Conflict Resolution

### Problem: NGINX Ingress Global Validation

**Error:**
```
admission webhook "validate.nginx.ingress.kubernetes.io" denied the request: 
host "_" and path "/query" is already defined in ingress default/fru-api-ingress
```

### Root Cause

1. **Host `"_"`**: When no `host` field is specified in ingress.yaml, NGINX treats it as wildcard `"_"` (matches any host)
2. **Namespace `default`**: Production ingress exists in `default` namespace (not best practice)
3. **Global validation**: NGINX validates `host + path` combinations **globally across ALL namespaces**, not per-namespace
4. **Conflict**: Test ingress has same host (`_`) and path (`/query`) as production ingress

### Solution

1. **Use unique hosts per environment:**
   - Dev: `api-dev.internal`
   - Staging: `api-staging.internal`
   - Prod: `api-prod.internal`
   - Test: `test-${TIMESTAMP}.test.local`

2. **Move production to dedicated namespace:**
   - Not `default` namespace
   - Use `fru-api` or `production` namespace

3. **Use Terraform outputs to define ingress hosts:**
   ```hcl
   # Terraform output
   output "ingress_host" {
     value = "api-${var.environment}.internal"
   }
   ```

4. **Convert ingress.yaml to template:**
   ```yaml
   # templates/ingress.template.yaml
   spec:
     rules:
     - host: ${INGRESS_HOST}  # From Terraform output
       http:
         paths:
         - path: /query
   ```

### Implementation

- Add Terraform outputs for `ingress_host`, `ingress_name`, `namespace`
- Update deployment scripts to read Terraform outputs
- Convert `ingress.yaml` to `ingress.template.yaml`
- Generate environment-specific ingress manifests

---

## Configuration Management

### Local: `.env` File

**Usage:**
- All configuration and credentials from `.env`
- AWS profiles for authentication
- Local database connection (localhost)
- Development secrets (local only, never commit)

**Example:**
```bash
# .env (local development only)
AWS_PROFILE=admin
AWS_REGION=us-east-1
PGHOST=localhost
PGPORT=5432
PGUSER=postgres
PGPASSWORD=local-dev-password
```

### Cloud: Terraform Outputs + .env for Authentication

**Usage:**
- **Terraform authentication:** `.env` file (AWS_PROFILE) - still needed to run Terraform
- **Kubernetes configuration:** Terraform outputs (namespace, ingress_host, etc.) - NOT from `.env`
- Environment-specific values from `environments/{env}/`
- Single source of truth: Terraform (for configuration values)

**Important:** `.env` file is still needed for Terraform authentication (AWS_PROFILE), but Kubernetes configuration values should come from Terraform outputs, not from `.env`.

**Example:**
```bash
# Deployment script reads from Terraform
NAMESPACE=$(terragrunt output -raw namespace)
INGRESS_HOST=$(terragrunt output -raw ingress_host)
INGRESS_NAME=$(terragrunt output -raw ingress_name)
CORS_ORIGIN=$(terragrunt output -raw cors_origin)

# Export for template generation
export NAMESPACE INGRESS_HOST INGRESS_NAME CORS_ORIGIN
```

**Terraform Outputs Needed:**
```hcl
# infra/terraform/providers/aws/modules/eks/outputs.tf
output "namespace" {
  value = "fru-api-${var.environment}"
}

output "ingress_name" {
  value = "fru-api-ingress-${var.environment}"
}

output "ingress_host" {
  value = "api-${var.environment}.internal"
}

output "cors_origin" {
  value = module.frontend.cloudfront_domain_name
}
```

### Why: Single Source of Truth

**Problem with dual source:**
- `.env` + Terraform for same **configuration values** = confusion
- Which source is authoritative?
- Risk of inconsistency
- Hard to maintain

**Solution:**
- **Terraform authentication:** `.env` file (AWS_PROFILE) - needed for ALL Terraform operations
- **Kubernetes configuration:** Terraform outputs (namespace, ingress_host, etc.) - single source of truth
- **Local development config:** `.env` file - single source of truth
- **Clear boundaries:** 
  - `.env` for authentication + local config
  - Terraform outputs for cloud configuration values

---

## Authentication Management

### Local: AWS Profiles

**Method:**
- AWS credentials stored in `~/.aws/credentials`
- Selected via `AWS_PROFILE` environment variable (from `.env`)
- No credentials in project files

**Example:**
```bash
# .env
AWS_PROFILE=admin

# Usage
aws s3 ls  # Uses admin profile automatically
```

### Cloud: OIDC/IRSA (Kubernetes) or IAM Roles (Cloud-Native)

**Kubernetes-based (EKS, GKE, AKS):**
- **OIDC/IRSA:** IAM Roles for Service Accounts
- No credentials in pods
- Automatic credential rotation
- Fine-grained permissions per service account

**Cloud-native (ECS, Cloud Run):**
- **IAM Roles:** Task execution role + runtime role
- No credentials in containers
- Automatic credential rotation
- Role-based access control

**Detailed Explanation:**
See [`cursor_gen/OIDC_IRSA_EXPLAINED_EASY.md`](cursor_gen/OIDC_IRSA_EXPLAINED_EASY.md) for complete OIDC/IRSA implementation guide.

### Why: Security and Best Practices

**Benefits:**
1. **No credentials in containers:** Eliminates credential leakage risk
2. **Automatic rotation:** Credentials rotated automatically
3. **Least privilege:** Fine-grained permissions per workload
4. **Auditability:** All access logged in CloudTrail
5. **Industry standard:** Recommended by AWS, GCP, Azure

---

## Multi-Cloud Compatibility

### Standard Protocols

**Use standard protocols for portability:**
- **OIDC (OpenID Connect):** Standard authentication protocol
- **Kubernetes APIs:** Standard container orchestration
- **Kubernetes manifests:** Portable across cloud providers

**Benefits:**
- Works across AWS, GCP, Azure, Oracle
- Same application code and manifests
- Only infrastructure layer changes

### Cloud-Specific Implementations

**Accept cloud-specific implementations for cloud-specific features:**
- **AWS:** IRSA (IAM Roles for Service Accounts)
- **GCP:** Workload Identity
- **Azure:** Azure AD Workload Identity
- **Oracle:** OCI Workload Identity

**Pattern is Universal:**
- No credentials in containers
- OIDC-based authentication
- Role-based access control

**Implementation is Cloud-Specific:**
- Each cloud provider has its own implementation
- Acceptable for cloud-specific features
- Pattern remains consistent

### Portability Considerations

**Portable (100%):**
- Kubernetes manifests (`infra/k8s/`)
- Application code
- Standard protocols (OIDC, Kubernetes APIs)

**Provider-Specific:**
- Infrastructure (Terraform modules)
- Authentication implementations (IRSA, Workload Identity)
- Cloud-specific services (CloudFront, Cloud CDN, Azure CDN)

**Strategy:**
- Keep application layer portable
- Isolate cloud-specific code to infrastructure layer
- Use standard patterns where possible

---

## Implementation Checklist

### ✅ Completed

1. **Multi-dimensional architecture:** 4 dimensions defined and documented
2. **Terraform infrastructure:** VPC, Aurora, IAM, Secrets Manager
3. **Kubernetes manifests:** Portable manifests in `infra/k8s/`
4. **Environment-specific configs:** `dev/`, `prod/` Terraform configs
5. **OIDC provider:** Created for IRSA (infrastructure ready)
6. **IAM roles:** ECS task execution and runtime roles (fully implemented)
7. **Load Balancer Controller:** Using IRSA (fully implemented)
8. **Local deployment:** `.env` file for local development

### ⚠️ Needs Implementation

1. **Terraform outputs for Kubernetes values:**
   - `namespace`
   - `ingress_name`
   - `ingress_host`
   - `cors_origin`
   - Priority: **High**

2. **Update deployment scripts:**
   - Read Terraform outputs instead of `.env` for cloud
   - Export as environment variables
   - Use for template generation
   - Priority: **High**

3. **Convert ingress.yaml to template:**
   - Create `ingress.template.yaml`
   - Use Terraform outputs for environment-specific values
   - Generate `ingress-generated.yaml`
   - Priority: **High**

4. **IRSA for application pods:**
   - Create IAM role for application pods
   - Create service account with IRSA annotation
   - Update deployment to use service account
   - Remove AWS credentials from Secrets
   - Priority: **Medium**

5. **Move infrastructure values to Terraform:**
   - Remove `AWS_REGION` from `.env` (use Terraform only)
   - Move other infrastructure values to Terraform
   - Keep `.env` only for local development
   - Priority: **Medium**

6. **Secrets Manager for production:**
   - Use AWS Secrets Manager for production secrets
   - Kubernetes reads via CSI driver
   - Keep `.env` only for local development
   - Priority: **Low**

### Priority Order

1. **High Priority:**
   - Add Terraform outputs for Kubernetes values
   - Update deployment scripts to use Terraform outputs
   - Convert ingress.yaml to template

2. **Medium Priority:**
   - Implement IRSA for application pods
   - Move infrastructure values to Terraform

3. **Low Priority:**
   - Secrets Manager CSI driver for production

---

## Summary

### Key Takeaways

1. **Ingress conflicts:** Use unique hosts per environment (not just unique namespaces)
2. **Configuration:** Single source of truth - `.env` for local, Terraform outputs for cloud
3. **Authentication:** `.env` (AWS profiles) for local, OIDC/IRSA for cloud
4. **Multi-cloud:** Use standard protocols (OIDC, Kubernetes), accept cloud-specific implementations

### Current Status

**✅ Aligned with Best Practices:**
- Multi-cloud architecture
- Infrastructure as Code (Terraform + kubectl)
- Authentication (IAM roles, OIDC/IRSA)
- Environment management
- Directory structure

**⚠️ Needs Completion:**
- Configuration management (Terraform outputs for cloud)
- IRSA for application pods

**✅ Unique Features:**
- Dual orchestration support (Kubernetes + cloud-native)
- Comprehensive multi-dimensional architecture

### Next Steps

1. Implement Terraform outputs for Kubernetes values
2. Update deployment scripts to use Terraform outputs
3. Convert ingress.yaml to template
4. Implement IRSA for application pods

---

## References

- **Terminology:** [`cursor_gen/TERMINOLOGY_CLARIFICATION.md`](cursor_gen/TERMINOLOGY_CLARIFICATION.md)
- **OIDC/IRSA:** [`cursor_gen/OIDC_IRSA_EXPLAINED_EASY.md`](cursor_gen/OIDC_IRSA_EXPLAINED_EASY.md)
- **Industry Comparison:** [`cursor_gen/INDUSTRY_BEST_PRACTICES_COMPARISON.md`](cursor_gen/INDUSTRY_BEST_PRACTICES_COMPARISON.md)
- **Ingress Conflict Analysis:** [`cursor_gen/INGRESS_CONFLICT_ANALYSIS.md`](cursor_gen/INGRESS_CONFLICT_ANALYSIS.md)
- **Workflow Analysis:** [`cursor_gen/WORKFLOW_ANALYSIS_EKS.md`](cursor_gen/WORKFLOW_ANALYSIS_EKS.md)

