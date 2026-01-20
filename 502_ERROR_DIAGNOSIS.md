# 502 Error Diagnosis

## Problem
- `/analytics` → 502 Bad Gateway
- `/query/stream` → 502 Bad Gateway
- LoadBalancer DNS: `ae9b974e7aaee4904ac677a7e86c9b32-1021998622.us-east-1.elb.amazonaws.com`
- Direct curl to LoadBalancer: "Empty reply from server"

## Root Cause Analysis

### 1. LoadBalancer Type
The DNS format `ae9b974e7aaee4904ac677a7e86c9b32-1021998622.us-east-1.elb.amazonaws.com` suggests:
- **Classic ELB** (not ALB/NLB)
- Classic ELB uses different API (`aws elb` not `aws elbv2`)

### 2. Security Groups
- LoadBalancer security group might not allow CloudFront IPs
- CloudFront needs to reach LoadBalancer on port 80/443

### 3. Target Health
- Target group might not have healthy targets
- Pods might not be registered correctly

## Solutions

### Option 1: Use ALB Instead (Recommended)
Classic ELB doesn't work well with CloudFront. Use ALB via annotations:

```yaml
# service.yaml
apiVersion: v1
kind: Service
metadata:
  name: fru-api
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"  # Use NLB (simpler than ALB)
    # OR
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 5000
```

### Option 2: Fix Security Groups
Add CloudFront IP ranges to LoadBalancer security group.

### Option 3: Use Ingress with ALB Controller (Current ALB approach)
This is what we tried before but had DNS issues.

## Recommendation
Use **NLB (Network Load Balancer)** via annotations - simpler than ALB, works with CloudFront.

