# EKS Deployment Workflow Analysis

## Part 1: Component Roles

### 1. Terraform/Terragrunt
- **Purpose**: Creates AWS infrastructure declaratively
- **Creates**: EKS cluster, CloudFront distribution, S3 bucket
- **Configuration**: `infra/terraform/providers/aws/environments/dev/eks/terragrunt.hcl`
- **Key Issue**: CloudFront origin ALB DNS was hardcoded with wrong value

### 2. Kubernetes Components

```mermaid
graph TB
    subgraph K8S["K8s Cluster"]
        P1[Pod1]
        P2[Pod2]
        SVC[Svc<br/>ClusterIP]
        ING[Ingress<br/>Resource]
        NGINX[NGINX Ingress<br/>Controller]
    end
    NLB[NLB<br/>Network LB]
    CF[CloudFront]
    U[User]
    U -->|HTTPS| CF
    CF -->|HTTP| NLB
    NLB -->|HTTP| NGINX
    NGINX -->|Routes| ING
    ING -->|HTTP| SVC
    SVC -->|HTTP| P1
    SVC -->|HTTP| P2
    style P1 fill:#e1f5ff,font-size:10px
    style P2 fill:#e1f5ff,font-size:10px
    style SVC fill:#fff4e1,font-size:10px
    style ING fill:#ffe1f5,font-size:10px
    style NGINX fill:#ffe1f5,font-size:10px
    style NLB fill:#e1ffe1,font-size:10px
    style CF fill:#f5e1ff,font-size:10px
    style U fill:#ffe1e1,font-size:10px
```

**Component Details:**

1. **Deployment** (`fru-api`)
   - Manages pod replicas (2 pods running)
   - Pods run the Flask backend application
   - **Location**: `infra/k8s/templates/deployment.template.yaml`

2. **Service** (`fru-api`, type: `ClusterIP`)
   - Internal cluster IP only, no external access
   - Routes traffic from Ingress to backend pods
   - **Location**: `infra/k8s/templates/service.template.yaml`

3. **Ingress Resource** (`fru-api-ingress-dev`)
   - Kubernetes Ingress resource that defines routing rules
   - Uses `ingressClassName: fru-nginx-cls` to route through NGINX Ingress Controller
   - Routes paths (`/query`, `/analytics`, `/health`, `/version`) to the `fru-api` Service
   - **Location**: `infra/k8s/templates/ingress.template.yaml`

4. **NGINX Ingress Controller**
   - Cloud-agnostic ingress controller running on dedicated node group
   - Installed via Helm (chart: `ingress-nginx/ingress-nginx`)
   - **How NLB is created on AWS:**
     - NGINX Ingress Controller has a LoadBalancer Service (`ingress-nginx-controller` in `ingress-nginx` namespace)
     - Service has AWS annotations that tell AWS to create an NLB:
       - `service.beta.kubernetes.io/aws-load-balancer-type: nlb`
       - `service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip`
       - `service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing`
     - AWS automatically creates NLB when it sees these annotations
     - NLB DNS appears in the Service status
     - NGINX Ingress Controller copies this DNS to Ingress resource status
   - **Cloud-agnostic**: Same setup works on Azure/GCP (creates their respective load balancers)
   - **Note**: Helm values/annotations may be set during installation (not in codebase) or use default chart values

### 3. Shell Scripts
- **Purpose**: Orchestrate deployment workflow
- **Key Script**: `run_scripts/main_application_scripts/aws/eks/deploy.sh`
- **Critical Step**: Substep 5b - Update CloudFront after Ingress creates NLB

---

## Part 2: Deployment Workflow

```mermaid
flowchart TD
    Start([Start]) --> T1[P5.1: TF]
    T1 -->|Creates| CF1[CF<br/>Wrong ALB]
    T1 -->|Creates| EKS[EKS]
    EKS --> K1[P5.2: K8s]
    K1 --> K2[Deploy]
    K2 --> K3[Svc]
    K3 --> K4[Ingress→NLB]
    K4 --> NLB1[NLB DNS]
    NLB1 --> S1[5b: Update CF]
    S1 -->|FAIL| Error[Script Fails]
    Error --> V1[P7: Verify]
    V1 -->|Test| Direct[NLB Fail]
    V1 -->|Test| Static[Root OK]
    V1 -->|Skip| API[API Not Tested]
    V1 -->|Result| Pass[False PASS]
    Pass --> End([Broken])
    style CF1 fill:#ffcccc,font-size:10px
    style Error fill:#ff9999,font-size:10px
    style Pass fill:#ffcccc,font-size:10px
    style End fill:#ffcccc,font-size:10px
    style NLB1 fill:#ccffcc,font-size:10px
    style K4 fill:#ccffcc,font-size:10px
```

### Workflow Steps

1. **Phase 5.1: Terraform Creates Infrastructure**
   - Creates EKS cluster
   - Creates CloudFront with hardcoded NLB DNS from `terragrunt.hcl` (❌ wrong value)
   - **Note**: CloudFront origin points to a load balancer (NLB on AWS), but the DNS was hardcoded incorrectly

2. **Phase 5.2: Kubernetes Manifests Applied**
   - Deployment → Pods start running
   - Service (ClusterIP) → Internal IP only, no external access
   - Ingress → NGINX Ingress Controller's LoadBalancer Service creates NLB on AWS
   - NLB DNS appears in Ingress status (populated by NGINX Ingress Controller)

3. **Substep 5b: CloudFront Update (❌ FAILED HERE)**
   - Script should:
     - Get CloudFront distribution ID from Terraform outputs
     - Get NLB DNS from Ingress: `kubectl get ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'`
     - Update CloudFront origin to use that NLB DNS
   - What went wrong:
     - ❌ Couldn't find `cloudfront_distribution_id` (not exposed in EKS outputs)
     - ❌ Script checked `kubectl get svc` instead of `kubectl get ingress`
     - ❌ Service is ClusterIP (no LoadBalancer hostname)
     - ❌ Script exited early with warning
     - ❌ CloudFront kept wrong hardcoded NLB DNS

### Industry Best Practices for CloudFront-ALB Coordination

**Current Approach (Shell Script with `kubectl`):**
- ✅ **Pros**: Simple, works after Kubernetes manifests are applied, can wait for Ingress to be ready
- ❌ **Cons**: Requires manual coordination, timing-dependent, not fully declarative

**Alternative 1: Terraform with `data.kubernetes_ingress`**
```hcl
data "kubernetes_ingress" "api" {
  metadata {
    name      = "fru-api-ingress"
    namespace = "default"
  }
  depends_on = [kubernetes_ingress.api]  # Wait for Ingress to be created
}

# Use ALB DNS from Ingress status
locals {
  alb_dns = data.kubernetes_ingress.api.status[0].load_balancer[0].ingress[0].hostname
}
```
- ✅ **Pros**: Fully declarative, Terraform manages dependencies
- ❌ **Cons**: **Timing issue**: Terraform runs BEFORE Kubernetes manifests are applied (Phase 5.1 vs 5.2)
- ❌ **Cons**: Requires two-phase Terraform apply (create Ingress first, then update CloudFront)
- ❌ **Cons**: Complex dependency management between Terraform and Kubernetes

**Alternative 2: Two-Phase Terraform Deployment**
1. Phase 1: Create EKS + Ingress (without CloudFront ALB origin)
2. Phase 2: Apply Kubernetes manifests, wait for Ingress ALB
3. Phase 3: Terraform apply again with `data.kubernetes_ingress` to update CloudFront
- ✅ **Pros**: Fully declarative, Terraform manages everything
- ❌ **Cons**: Requires multiple Terraform applies, complex workflow

**Alternative 3: AWS Load Balancer Controller + External-DNS**
- Use **AWS Load Balancer Controller** to automatically create ALB from Ingress
- Use **External-DNS** to automatically create Route53 records
- Use **EventBridge + Lambda** to automatically update CloudFront when ALB changes
- ✅ **Pros**: Fully automated, no manual coordination, industry standard for AWS-only deployments
- ❌ **Cons**: Requires additional controllers, more complex initial setup
- ⚠️ **Cloud-Agnostic Concern**: **Contradicts cloud-agnostic goal**
  - Your architecture uses **NGINX Ingress Controller on dedicated node group** to remain cloud-agnostic
  - This allows the same Kubernetes manifests to work on **AWS, Azure, GCP** without changes
  - AWS Load Balancer Controller is **AWS-specific** (creates ALB, not generic LoadBalancer)
  - Would lock you into AWS and prevent easy migration to Azure/GCP
  - **Not recommended** for your use case due to cloud-agnostic requirement
  - **Note**: NGINX Ingress Controller on AWS automatically creates ALB (cloud-agnostic controller, cloud-specific LB)

**Alternative 4: Terraform `null_resource` with `local-exec` (Hybrid)**
```hcl
resource "null_resource" "update_cloudfront" {
  depends_on = [kubernetes_ingress.api]
  
  triggers = {
    ingress_uid = kubernetes_ingress.api.metadata[0].uid
  }
  
  provisioner "local-exec" {
    command = <<-EOT
      kubectl get ingress fru-api-ingress -n default -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' > /tmp/alb_dns.txt
      # Update CloudFront using AWS CLI
    EOT
  }
}
```
- ✅ **Pros**: Terraform-managed, can wait for Ingress
- ❌ **Cons**: Still requires `kubectl`, not fully declarative

**Recommended Approach for This Project:**
**Keep the current shell script approach** but improve it:
1. ✅ Fix the script to check `kubectl get ingress` (not Service) - **DONE**
2. ✅ Expose `cloudfront_distribution_id` in Terraform outputs - **DONE** (added to EKS module outputs)
3. ✅ Add proper retry logic with timeout - **Already has this**
4. ✅ Make it fail-fast with clear error messages - **Already improved**
5. ⚠️ Consider moving to Terraform `null_resource` for better integration - **Optional future improvement**

**Why Shell Script is Acceptable:**
- Kubernetes Ingress NLB creation is **asynchronous** (AWS creates it after NGINX Ingress Controller Service is created)
- Terraform runs **before** Kubernetes manifests (Phase 5.1 vs 5.2)
- Shell script can **wait and retry** until Ingress NLB DNS is ready
- This is a **common pattern** for coordinating Terraform and Kubernetes resources
- ✅ **Maintains cloud-agnostic architecture**: Uses standard Kubernetes Ingress (works on any cloud)

**Cloud-Agnostic Architecture Note:**
- Your setup uses **NGINX Ingress Controller on a dedicated node group** (not Fargate)
- This allows the same Kubernetes manifests to work on **AWS, Azure, GCP** without changes
- The Ingress resource is **cloud-agnostic** - AWS Load Balancer Controller creates ALB automatically
- Shell script approach **preserves this cloud-agnostic design** (no AWS-specific controllers required)

4. **Phase 7: Verification (❌ False Positive)**
   - Tested direct ALB (failed - HTTPS/HTTP mismatch)
   - Tested frontend root (passed - S3 static files)
   - ❌ Did NOT test CloudFront API endpoints
   - Marked as "PASSED" despite CloudFront misconfiguration

---

## Part 3: The Problem Location

```mermaid
graph LR
    subgraph Expected["Expected"]
        A1[Ingress] -->|DNS| B1[Get DNS]
        B1 -->|Update| C1[CF Origin]
        C1 -->|Route| D1[Works]
    end
    subgraph Actual["Actual"]
        A2[Ingress] -->|DNS| B2[Script Fails]
        B2 -->|Missing| E1[CF ID<br/>Not Found]
        B2 -->|Wrong| E2[Checked Svc<br/>Not Ingress]
        E1 -->|Exit| F1[CF Not Updated]
        E2 -->|Exit| F1
        F1 -->|Keep| G1[Wrong ALB]
        G1 -->|502| H1[Broken]
    end
    style B2 fill:#ff9999,font-size:10px
    style E1 fill:#ffcccc,font-size:10px
    style E2 fill:#ffcccc,font-size:10px
    style F1 fill:#ff9999,font-size:10px
    style G1 fill:#ffcccc,font-size:10px
    style H1 fill:#ff9999,font-size:10px
    style D1 fill:#ccffcc,font-size:10px
```

### Root Causes

1. **Missing Terraform Output**
   - `cloudfront_distribution_id` not exposed in EKS module outputs
   - Script couldn't find CloudFront distribution to update

2. **Wrong Resource Check**
   - Script checked: `kubectl get svc` (Service)
   - Should check: `kubectl get ingress` (Ingress)
   - Service is ClusterIP → no LoadBalancer hostname
   - Ingress has NLB hostname in status

3. **Hardcoded Fallback**
   - `terragrunt.hcl` had wrong NLB DNS as fallback
   - CloudFront created with wrong origin from start

### Result
- CloudFront kept pointing to non-existent NLB → **502 Bad Gateway errors**
- Frontend couldn't reach backend through CloudFront

---

## Part 4: Component Interaction Details

```mermaid
sequenceDiagram
    participant T as TF
    participant K as K8s
    participant S as Script
    participant A as ALB
    participant C as CF
    participant U as User
    Note over T: P5.1
    T->>C: Create CF<br/>(Wrong ALB)
    Note over K: P5.2
    S->>K: Apply Ingress
    K->>A: Create ALB
    A-->>K: ALB DNS
    Note over S: 5b FAILED
    S->>T: Get CF ID<br/>(NOT FOUND)
    S->>K: Get ALB from Svc<br/>(WRONG)
    S->>S: Exit
    Note over C: Wrong ALB
    Note over U: User
    U->>C: /analytics
    C->>A: Wrong ALB
    A-->>C: 502
    C-->>U: 502
```

### Traffic Flow (When Working)

```mermaid
graph LR
    U[User] -->|1| CF[CF]
    CF -->|2| ALB[ALB]
    ALB -->|3| ING[Ingress]
    ING -->|4| SVC[Svc]
    SVC -->|5| P1[Pod1]
    SVC -->|5| P2[Pod2]
    style U fill:#ffe1e1,font-size:10px
    style CF fill:#f5e1ff,font-size:10px
    style ALB fill:#e1ffe1,font-size:10px
    style ING fill:#ffe1f5,font-size:10px
    style SVC fill:#fff4e1,font-size:10px
    style P1 fill:#e1f5ff,font-size:10px
    style P2 fill:#e1f5ff,font-size:10px
```

---

## Part 5: The Fix

### What Was Fixed

1. **Manual Fix**
   - Updated `terragrunt.hcl` with correct ALB DNS
   - Re-applied Terraform to update CloudFront

2. **Code Fixes**
   - Added CloudFront API endpoint validation (`/analytics`, `/query/stream`)
   - Made verification fail-fast on critical failures
   - Would catch this issue in future deployments

### Fixed Workflow

```mermaid
flowchart TD
    Start([Deploy]) --> T1[P5.1: TF Creates CF<br/>Placeholder ALB]
    T1 --> K1[P5.2: K8s Applies Ingress]
    K1 --> K2[NGINX Ingress Controller<br/>LoadBalancer Svc Creates NLB]
    K2 --> K3[NLB DNS in<br/>Ingress Status]
    K3 --> S1[5b: Script Gets<br/>NLB DNS from Ingress]
    S1 --> S2[Script Gets CF ID<br/>from Terraform Output]
    S2 --> S3[Script Updates<br/>CloudFront Origin]
    S3 -->|Success| V1[P7: Verify]
    S3 -->|Fail| Fail[Verify Fails<br/>Clear Error]
    V1 -->|Test| API1[CF /analytics<br/>200 OK]
    V1 -->|Test| API2[CF /query/stream<br/>200 OK]
    V1 -->|Test| API3[CF /version<br/>200 OK]
    API1 --> Pass[All Pass]
    API2 --> Pass
    API3 --> Pass
    Pass --> End([Success])
    Fail -->|Error| Fix[Fix CF Config]
    style Pass fill:#ccffcc,font-size:10px
    style End fill:#ccffcc,font-size:10px
    style API1 fill:#ccffcc,font-size:10px
    style API2 fill:#ccffcc,font-size:10px
    style API3 fill:#ccffcc,font-size:10px
    style S1 fill:#e1ffe1,font-size:10px
    style S2 fill:#e1ffe1,font-size:10px
    style S3 fill:#e1ffe1,font-size:10px
    style K3 fill:#e1ffe1,font-size:10px
    style Fail fill:#ffcccc,font-size:10px
```

---

## Summary

**Problem Location**: Substep 5b - CloudFront update script failed silently

**Root Causes**:
1. Missing Terraform output (`cloudfront_distribution_id`)
2. Wrong resource check (Service instead of Ingress)
3. Hardcoded wrong ALB DNS in config

**Impact**: CloudFront pointed to wrong ALB → 502 errors on frontend

**Solution**: 
- Fixed CloudFront origin manually
- Added CloudFront API validation
- Made verification fail-fast
- Exposed `cloudfront_distribution_id` in Terraform outputs
- Fixed script to check Ingress (not Service) for ALB DNS

### Approach Comparison

| Approach | Declarative | Timing | Complexity | Cloud-Agnostic | Recommendation |
|----------|-------------|--------|------------|----------------|----------------|
| **Shell Script** (current) | ❌ | ✅ | ✅ Low | ✅ **Yes** | ✅ **Keep & improve** |
| **Terraform `data.kubernetes_ingress`** | ✅ | ❌ Needs 2-phase | ⚠️ Medium | ✅ Yes | ⚠️ Possible but complex |
| **Terraform `null_resource`** | ⚠️ Partial | ✅ | ⚠️ Medium | ✅ Yes | ⚠️ Alternative |
| **AWS Controllers** | ✅ | ✅ | ❌ High | ❌ **No (AWS-only)** | ❌ **Not recommended** |

**Key Insight**: Your architecture prioritizes **cloud-agnostic design** (NGINX Ingress on node group), so AWS-specific controllers would contradict this goal. The shell script approach maintains cloud portability while solving the coordination problem.
