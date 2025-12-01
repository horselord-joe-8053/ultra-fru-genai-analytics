# Infra Overview

This folder contains basic infra scaffolding for FRU:

- `docker/`:
  - `Dockerfile.api` — container for the Flask API
  - `docker-compose.yml` — local stack: Postgres with pgvector + API

- `terraform/`:
  - `main.tf` — skeleton for:
    - S3 bucket to hold raw / processed data
    - RDS PostgreSQL instance to host pgvector

You still need to:
- install pgvector extension on RDS manually (or via init scripts),
- apply `docs/sql/schema_pgvector.sql`,
- run `backend/etl/load_openai_embeddings_to_pgvector.py` to populate embeddings.
