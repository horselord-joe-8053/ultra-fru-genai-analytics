# ALB vs LoadBalancer Service: Recommendation

## Summary

**Recommendation: Switch to LoadBalancer Service Type** ✅

**Why:**
1. **Simpler**: No controller, no Ingress, no IAM setup
2. **Cloud-agnostic**: Works on EKS, GKE, AKS
3. **Lower cost**: ~$10/month savings (no controller pods)
4. **Production-ready**: AWS creates ELB/NLB automatically
5. **Direct CloudFront integration**: Point CloudFront directly to LoadBalancer DNS

## Current Problem

ALB via Ingress Controller is:
- ❌ Complex (controller, IAM, Ingress)
- ❌ Taking too long to provision (10+ minutes, still not ready)
- ❌ AWS-specific (not cloud-agnostic)
- ❌ Higher operational overhead

## Solution: LoadBalancer Service Type

### Implementation

**1. Change Service Type:**
```yaml
# infra/k8s/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: fru-api
spec:
  type: LoadBalancer  # ← Change from ClusterIP
  ports:
  - port: 80
    targetPort: 5000
  selector:
    app: fru-api
```

**2. Remove Ingress (not needed):**
```bash
kubectl delete ingress fru-api-ingress
```

**3. Remove Controller (optional, saves cost):**
```bash
helm uninstall aws-load-balancer-controller -n kube-system
```

**4. Update CloudFront:**
- Get LoadBalancer DNS: `kubectl get svc fru-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'`
- Update CloudFront origin with LoadBalancer DNS

**5. Path-Based Routing via CloudFront:**
```hcl
# CloudFront cache behaviors handle routing:
# /query → LoadBalancer (no cache)
# /analytics → LoadBalancer (no cache)  
# /* → S3 (static frontend, cached)
```

## Migration Steps

1. **Apply LoadBalancer Service:**
   ```bash
   kubectl apply -f infra/k8s/service.yaml  # (after changing to LoadBalancer)
   ```

2. **Wait for LoadBalancer (~2-3 minutes):**
   ```bash
   kubectl get svc fru-api -w
   ```

3. **Get LoadBalancer DNS:**
   ```bash
   ALB_DNS=$(kubectl get svc fru-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   ```

4. **Update CloudFront:**
   ```bash
   ./run_scripts/main_application_scripts/aws/shared/helpers/update-cloudfront-alb.sh "" "" "" "$ALB_DNS"
   ```

5. **Clean up:**
   ```bash
   kubectl delete ingress fru-api-ingress
   # Optional: helm uninstall aws-load-balancer-controller -n kube-system
   ```

## Benefits

| Aspect | ALB (Current) | LoadBalancer (Proposed) |
|--------|---------------|------------------------|
| **Setup Time** | 10+ minutes | 2-3 minutes |
| **Components** | Controller + Ingress + Service | Service only |
| **Cloud-Agnostic** | ❌ AWS-only | ✅ Yes |
| **Cost** | ~$26/month | ~$16/month |
| **Complexity** | High | Low |
| **Path Routing** | ✅ Ingress | ✅ CloudFront |

## Answer to Your Questions

### 1. Script Already Has Timeout ✅
- ✅ Yes, `update-cloudfront-alb.sh` waits 10 minutes with fail-fast
- ✅ Already ran it, but ALB still not ready (controller issue)

### 2. ALB via Terraform?
- **ALB itself**: Created by Kubernetes controller (not Terraform)
- **Controller**: Could be installed via Terraform/Helm (but adds complexity)
- **Better approach**: Use LoadBalancer service (auto-created by AWS, no Terraform needed)

### 3. Do We Really Need ALB?
- **No!** LoadBalancer service type is simpler and sufficient
- **Path routing**: Handle via CloudFront cache behaviors
- **SSL**: LoadBalancer supports SSL termination
- **Health checks**: LoadBalancer has basic health checks

## Recommendation

**Switch to LoadBalancer Service Type** - Simpler, faster, cloud-agnostic, lower cost.

