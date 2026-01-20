# ALB Alternatives Analysis for EKS

## Question: Do We Really Need ALB? Is There Something Simpler?

## Current Setup (ALB via Ingress Controller)

**Architecture:**
```
Internet → CloudFront → ALB (via Ingress Controller) → Kubernetes Service (ClusterIP) → Pods
```

**Components Required:**
- AWS Load Balancer Controller (Kubernetes pod)
- Ingress resource with ALB annotations
- IAM role for controller (IRSA)
- CloudFront distribution
- Kubernetes Service (ClusterIP)

**Complexity:** HIGH
- Controller installation
- IAM setup
- Ingress configuration
- CloudFront integration

## Alternative 1: LoadBalancer Service Type (Simplest)

**Architecture:**
```
Internet → CloudFront → ELB/NLB (auto-created) → Kubernetes Service (LoadBalancer) → Pods
```

**Implementation:**
```yaml
# service.yaml
apiVersion: v1
kind: Service
metadata:
  name: fru-api
spec:
  type: LoadBalancer  # ← Changes from ClusterIP
  ports:
  - port: 80
    targetPort: 5000
  selector:
    app: fru-api
```

**Pros:**
- ✅ **Simplest**: No controller needed, no Ingress needed
- ✅ **Automatic**: AWS creates ELB/NLB automatically
- ✅ **Cloud-agnostic**: Works on EKS, GKE, AKS (each creates their own LB)
- ✅ **Less moving parts**: No controller pods, no IAM roles
- ✅ **Direct CloudFront integration**: Point CloudFront directly to LoadBalancer DNS

**Cons:**
- ❌ **No path-based routing**: All traffic goes to same service
- ❌ **Less control**: Limited customization compared to ALB
- ❌ **Cost**: ELB/NLB costs (~$16/month) vs ALB (~$16/month) - similar
- ❌ **No advanced features**: No WAF integration, limited SSL options

**CloudFront Integration:**
```hcl
# Terraform: Point CloudFront directly to LoadBalancer DNS
module "frontend" {
  # ...
  alb_dns_name = kubernetes_service.fru_api.status.load_balancer.ingress[0].hostname
}
```

**Verdict:** ✅ **RECOMMENDED for simplicity** - If you don't need path-based routing or advanced ALB features

## Alternative 2: NodePort + CloudFront (Not Recommended)

**Architecture:**
```
Internet → CloudFront → NodePort (on each node) → Kubernetes Service (NodePort) → Pods
```

**Pros:**
- ✅ No AWS load balancer cost
- ✅ Simple Kubernetes-native

**Cons:**
- ❌ **Security risk**: Exposes nodes directly
- ❌ **Not production-ready**: Requires firewall rules, manual node IP management
- ❌ **No high availability**: If node fails, traffic fails
- ❌ **Complex CloudFront setup**: Need to list all node IPs

**Verdict:** ❌ **NOT RECOMMENDED** - Security and reliability concerns

## Alternative 3: ClusterIP + Port Forward (Development Only)

**Architecture:**
```
Local → kubectl port-forward → Kubernetes Service (ClusterIP) → Pods
```

**Pros:**
- ✅ No external exposure
- ✅ Simple for development

**Cons:**
- ❌ **Not accessible from internet**: Only works locally
- ❌ **Not production-ready**: No CloudFront integration possible

**Verdict:** ❌ **DEVELOPMENT ONLY** - Not suitable for production

## Alternative 4: Direct CloudFront to S3 (Static Only)

**Architecture:**
```
Internet → CloudFront → S3 (static files only)
```

**Pros:**
- ✅ Very simple
- ✅ Low cost

**Cons:**
- ❌ **Static content only**: No dynamic API endpoints
- ❌ **Not applicable**: We need backend API

**Verdict:** ❌ **NOT APPLICABLE** - We need dynamic API

## Comparison Matrix

| Feature | ALB (Ingress) | LoadBalancer Service | NodePort | ClusterIP |
|---------|---------------|---------------------|----------|-----------|
| **Complexity** | High | Low | Medium | Low |
| **Path Routing** | ✅ Yes | ❌ No | ❌ No | ❌ No |
| **SSL Termination** | ✅ Yes | ✅ Yes | ❌ Manual | ❌ No |
| **Health Checks** | ✅ Advanced | ✅ Basic | ❌ No | ❌ No |
| **WAF Integration** | ✅ Yes | ❌ No | ❌ No | ❌ No |
| **Cloud-Agnostic** | ❌ AWS-only | ✅ Yes | ✅ Yes | ✅ Yes |
| **Cost** | ~$16/month | ~$16/month | $0 | $0 |
| **Controller Needed** | ✅ Yes | ❌ No | ❌ No | ❌ No |
| **Production Ready** | ✅ Yes | ✅ Yes | ❌ No | ❌ No |

## Recommendation

### For Your Use Case (EKS with CloudFront)

**Option A: LoadBalancer Service Type (Simplest)** ✅ **RECOMMENDED**

**Why:**
- Simplest setup (no controller, no Ingress)
- Cloud-agnostic (works on EKS, GKE, AKS)
- Automatic load balancer creation
- Direct CloudFront integration
- Production-ready

**Trade-off:**
- No path-based routing (but you can handle this in CloudFront cache behaviors)
- Less advanced features than ALB

**Implementation:**
1. Change `service.yaml` from `ClusterIP` to `LoadBalancer`
2. Remove `ingress.yaml` (not needed)
3. Remove AWS Load Balancer Controller (not needed)
4. Point CloudFront directly to LoadBalancer DNS

**Option B: Keep ALB (Current Setup)** ✅ **IF YOU NEED PATH ROUTING**

**Why:**
- Path-based routing (`/query`, `/analytics`)
- Advanced features (WAF, advanced health checks)
- Better for complex routing needs

**Trade-off:**
- More complex (controller, IAM, Ingress)
- AWS-specific (not cloud-agnostic)

## Path-Based Routing Without ALB

If you use LoadBalancer service type, you can still do path-based routing:

**Option 1: CloudFront Cache Behaviors** (Recommended)
```hcl
# CloudFront routes:
# /query → LoadBalancer (no cache)
# /analytics → LoadBalancer (no cache)
# /* → S3 (static frontend, cached)
```

**Option 2: Application-Level Routing**
- Flask handles all routes (`/query`, `/analytics`, `/`)
- Single LoadBalancer endpoint
- Simpler, but less flexible

## Cost Comparison

| Component | ALB Setup | LoadBalancer Setup |
|-----------|-----------|-------------------|
| Load Balancer | ALB: ~$16/month | ELB/NLB: ~$16/month |
| Controller Pods | Fargate: ~$10/month | None: $0 |
| **Total** | **~$26/month** | **~$16/month** |

**Savings:** ~$10/month with LoadBalancer (no controller pods)

## Migration Path

### From ALB to LoadBalancer Service

1. **Change Service Type:**
   ```yaml
   # service.yaml
   spec:
     type: LoadBalancer  # Changed from ClusterIP
   ```

2. **Remove Ingress:**
   ```bash
   kubectl delete ingress fru-api-ingress
   ```

3. **Remove Controller (optional):**
   ```bash
   helm uninstall aws-load-balancer-controller -n kube-system
   ```

4. **Update CloudFront:**
   - Get LoadBalancer DNS: `kubectl get svc fru-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'`
   - Update CloudFront origin with LoadBalancer DNS

5. **Update Terraform:**
   - Remove Ingress-related config
   - Add data source to get LoadBalancer DNS from Kubernetes

## Final Recommendation

**For simplicity and cloud-agnostic approach:** Use **LoadBalancer Service Type**

**Benefits:**
- ✅ Simpler (no controller, no Ingress)
- ✅ Cloud-agnostic (works on EKS, GKE, AKS)
- ✅ Lower cost (~$10/month savings)
- ✅ Production-ready
- ✅ Direct CloudFront integration

**Keep ALB if:**
- You need advanced path-based routing
- You need WAF integration
- You need advanced health checks
- You're committed to AWS-only

