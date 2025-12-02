# Infra Overview

This folder contains infrastructure code for FRU:

- `docker/`:
  - `Dockerfile.api` — container for the Flask API
  - `docker-compose.yml` — local stack: Postgres with pgvector + API

- `terraform/`:
  - `modules/` — Reusable Terraform modules:
    - `vpc/` — VPC, subnets, NAT gateways, VPC endpoints
    - `aurora/` — Aurora PostgreSQL cluster with pgvector support
    - `iam/` — IAM roles (execution + runtime separation)
    - `secrets-manager/` — Secrets Manager for sensitive data
    - `ecs/` — ECS cluster, service, task definition
    - `alb/` — Application Load Balancer
    - `frontend/` — S3 + CloudFront for frontend
    - `infrastructure/` — Wrapper module (VPC + Aurora + IAM + Secrets)
    - `application/` — Wrapper module (ECS + ALB + Frontend)
  - `environments/` — Terragrunt configurations for dev/prod environments

See `infra/terraform/README.md` for detailed deployment instructions.

**After deploying infrastructure:**
- Install pgvector extension: `CREATE EXTENSION IF NOT EXISTS vector;`
- Apply `docs/sql/schema_pgvector.sql`
- Run `backend/etl/load_openai_embeddings_to_pgvector.py` to populate embeddings
