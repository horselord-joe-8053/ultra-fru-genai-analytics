# Infra Overview

This folder contains infrastructure code for FRU:

- `docker/`:
  - `Dockerfile.api` — container for the Flask API
  - `docker-compose.yml` — local stack: Postgres with pgvector + API

- `terraform/`:
  - **Complete Infrastructure as Code (IaC) implementation** using Terraform + Terragrunt
  - **Modular architecture**: 7 reusable modules (VPC, Aurora, IAM, Secrets Manager, ECS, ALB, Frontend)
  - **Environment management**: Terragrunt configurations for dev/prod with infrastructure/application layers
  - **Security best practices**: IAM role separation, Secrets Manager integration, IAM database authentication
  - **Production-ready**: Automated deployments, version-controlled infrastructure, disaster recovery support
  
  See **[`terraform/README.md`](terraform/README.md)** for:
  - Complete necessity and benefits explanation
  - Detailed deployment instructions
  - Security best practices
  - Module documentation

**After deploying infrastructure:**
- Install pgvector extension: `CREATE EXTENSION IF NOT EXISTS vector;`
- Apply `docs/sql/schema_pgvector.sql`
- Run `backend/etl/load_openai_embeddings_to_pgvector.py` to populate embeddings
