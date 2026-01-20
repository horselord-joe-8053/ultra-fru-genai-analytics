# Answers to Your Questions

## 0. Frontend Panel 502 Errors

**Problem**: `/analytics` and `/query/stream` returning 502 Bad Gateway

**Root Cause**: 
- Kubernetes created a **Classic ELB** (not ALB/NLB)
- Classic ELB doesn't work well with CloudFront
- Security groups might not allow CloudFront traffic

**Fix**: Changed service annotations to use **NLB (Network Load Balancer)** instead:
```yaml
annotations:
  service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
  service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
```

**Status**: Service recreated with NLB annotations. Waiting for NLB to provision (~2-3 minutes).

---

## 1. Does CloudFront Update Affect ECS?

**Answer**: ✅ **NO - Separate Frontend Instances**

ECS and EKS have **separate CloudFront distributions**:

### ECS CloudFront Distribution
- **Origin ID**: `ALB-fru-dev-ecs`
- **S3 Bucket**: `fru-dev-frontend-ecs-744139897900`
- **ALB DNS**: ECS ALB (from Terraform-managed ALB)
- **Config**: `infra/terraform/providers/aws/environments/dev/ecs/terragrunt.hcl`

### EKS CloudFront Distribution  
- **Origin ID**: `ALB-fru-dev-eks`
- **S3 Bucket**: `fru-dev-frontend-eks-744139897900`
- **LoadBalancer DNS**: EKS LoadBalancer (from Kubernetes Service)
- **Config**: `infra/terraform/providers/aws/environments/dev/eks/terragrunt.hcl`

**Why Separate?**
- Different `container_type` values (`ecs` vs `eks`)
- Frontend module creates unique resources per container type
- Allows both ECS and EKS to run simultaneously with different URLs

**Verification**:
```bash
# ECS frontend
aws cloudfront list-distributions --query 'DistributionList.Items[?Comment==`fru-dev-frontend-ecs`]'

# EKS frontend  
aws cloudfront list-distributions --query 'DistributionList.Items[?Comment==`fru-dev-frontend-eks`]'
```

---

## 2. Is LoadBalancer Cloud-Provider Agnostic?

**Answer**: ⚠️ **Partially - Concept Yes, Implementation No**

### Concept Level: ✅ Cloud-Agnostic
- **Kubernetes `LoadBalancer` service type** is a standard Kubernetes concept
- Works on **EKS (AWS)**, **GKE (GCP)**, **AKS (Azure)**
- Same Kubernetes manifest works across clouds

### Implementation Level: ❌ Cloud-Specific
- **AWS**: Creates ELB/NLB/ALB (depends on annotations)
- **GCP**: Creates GCP Load Balancer
- **Azure**: Creates Azure Load Balancer

**What Makes It Cloud-Agnostic:**
- ✅ Same Kubernetes manifest (`type: LoadBalancer`)
- ✅ Same service definition
- ✅ Same port configuration
- ✅ No cloud-specific code needed

**What's Cloud-Specific:**
- ❌ Load balancer type (ELB vs GCP LB vs Azure LB)
- ❌ Annotations (AWS-specific annotations don't work on GCP/Azure)
- ❌ DNS format (different per cloud)

**For True Cloud-Agnostic:**
- Use **Ingress** with cloud-agnostic Ingress controller (e.g., NGINX Ingress)
- Or use **Service Mesh** (Istio, Linkerd)
- Or use **Cloud Load Balancer** abstraction layer

**Current Approach**:
- Uses AWS-specific annotations (`service.beta.kubernetes.io/aws-load-balancer-type: "nlb"`)
- **Not fully cloud-agnostic** but works on AWS
- For GCP/Azure, would need different annotations or Ingress

---

## 3. How Does CloudFront Connect to LoadBalancer?

**Answer**: **Via DNS Name**

### Connection Flow

```
Internet → CloudFront Distribution
         ↓
    CloudFront Origin (ALB-fru-dev-eks)
         ↓
    DNS Resolution: ae9b974e7aaee4904ac677a7e86c9b32-1021998622.us-east-1.elb.amazonaws.com
         ↓
    AWS Load Balancer (NLB/ALB/ELB)
         ↓
    Target Group → Kubernetes Service (fru-api)
         ↓
    Pods (10.0.11.89:5000, 10.0.10.85:5000)
```

### Configuration

**1. CloudFront Origin** (in Terraform):
```hcl
origin {
  domain_name = var.alb_dns_name  # LoadBalancer DNS
  origin_id   = "ALB-fru-dev-eks"
  custom_origin_config {
    http_port  = 80
    https_port = 443
    origin_protocol_policy = "http-only"
  }
}
```

**2. CloudFront Cache Behaviors** (route API paths):
```hcl
ordered_cache_behavior {
  path_pattern     = "/query"
  target_origin_id = "ALB-fru-dev-eks"  # Routes to LoadBalancer
  # ...
}

ordered_cache_behavior {
  path_pattern     = "/analytics"
  target_origin_id = "ALB-fru-dev-eks"  # Routes to LoadBalancer
  # ...
}
```

**3. LoadBalancer DNS** (from Kubernetes):
```bash
kubectl get svc fru-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# Returns: ae9b974e7aaee4904ac677a7e86c9b32-1021998622.us-east-1.elb.amazonaws.com
```

**4. DNS Resolution**:
- CloudFront resolves LoadBalancer DNS name to IP addresses
- AWS manages DNS → IP mapping automatically
- LoadBalancer distributes traffic to healthy targets

### Security Groups

**LoadBalancer Security Group** must allow:
- **Inbound**: Port 80/443 from CloudFront IP ranges (or 0.0.0.0/0 for internet-facing)
- **Outbound**: Port 5000 to pod IPs (handled by Kubernetes)

**CloudFront IP Ranges**:
- AWS publishes CloudFront IP ranges: https://d7uri8nf7uskq.cloudfront.net/tools/list-cloudfront-ips
- Can restrict LoadBalancer SG to CloudFront IPs only (more secure)

### Health Checks

**LoadBalancer Target Group**:
- Health check path: `/health` (configured in Kubernetes Service)
- Healthy threshold: 2 consecutive successes
- Unhealthy threshold: 3 consecutive failures
- Interval: 30 seconds

---

## Summary

1. **502 Errors**: Fixed by switching to NLB (Network Load Balancer) instead of Classic ELB
2. **ECS Impact**: No - Separate CloudFront distributions per container type
3. **Cloud-Agnostic**: Concept yes, implementation partially (AWS-specific annotations)
4. **CloudFront Connection**: Via DNS name → AWS Load Balancer → Kubernetes Service → Pods

