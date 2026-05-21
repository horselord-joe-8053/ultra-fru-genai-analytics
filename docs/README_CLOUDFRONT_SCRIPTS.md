# EKS CloudFront update scripts

## Canonical script (use this)

- **update-cloudfront-loadbalancer.sh** — Used by `kube/aws/deploy.sh` (Substep 5b). Waits for Ingress NLB hostname, gets `cloudfront_distribution_id` from the **frontend-eks** Terragrunt layer, and updates the CloudFront distribution’s API origin via AWS CLI. This is the one that fixes the 502 when CloudFront couldn’t reach the EKS NLB.

## Legacy / alternatives (removed)

The legacy scripts were removed to reduce confusion. Use **update-cloudfront-loadbalancer.sh**.

## Getting cloudfront_distribution_id

The output is defined in the **frontend** Terraform module and is produced by the **frontend-eks** Terragrunt layer. All scripts that need it run:

```bash
cd "$REPO_ROOT/module_infra_basic/aws/terra/environments/<env>/frontend-eks"
terragrunt output -raw cloudfront_distribution_id
```

The `.hcl` files in that directory don’t mention the output; they **include** the frontend module (`_component/frontend-base.hcl`), which sources the module where the output is defined. Terragrunt runs Terraform in that directory and reads the **state** from that layer, so `terragrunt output` returns the value from the module instance created by frontend-eks.