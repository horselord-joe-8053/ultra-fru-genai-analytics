# Frontend Module

Creates S3 bucket and CloudFront distribution for hosting the React frontend.

## Features

- S3 bucket for static files
- CloudFront distribution with HTTPS
- Origin Access Identity (OAI) for secure S3 access
- SPA routing support (404/403 → index.html)
- Custom cache behavior for API calls (/query)

## Usage

```hcl
module "frontend" {
  source = "../../modules/frontend"

  project_name = "fru"
  environment  = "prod"

  certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/xxx" # Optional
  api_origin_id   = "alb-origin" # Optional, for /query path

  tags = {
    Project = "FRU-GenAI"
  }
}
```

## Deployment

After creating the infrastructure, deploy the frontend:

```bash
cd frontend
npm run build
aws s3 sync dist/ s3://${module.frontend.s3_bucket_id}/
aws cloudfront create-invalidation --distribution-id ${module.frontend.cloudfront_distribution_id} --paths "/*"
```

## Outputs

- `cloudfront_domain_name` - Use this as your frontend URL
- `s3_bucket_id` - Use for deployment

