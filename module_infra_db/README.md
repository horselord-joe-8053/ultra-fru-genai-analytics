# module_infra_db

Database setup and schema scripts: pgvector extension, schema init, and data load. References `module_app_core/sql/` for schema SQL and `module_infra_basic` for Terraform infrastructure outputs (Aurora).

## Layout

- **common/database/** – Init schema and load data (local and AWS): `init_schema.sh`, `init_schema_local.sh`, `init_schema_aws.sh`, `load_data.sh`, `load_data_local.sh`, `load_data_aws.sh`, `parse_sql_statements.py`
- **aws/** – AWS-specific: `ensure-pgvector.sh`, `setup-database.sh`, `validate-infra-outputs.sh`, `wait-for-pgvector-ready.sh`

## Usage

Invoked by orchestration and AWS deploy:

- **Local:** `./run.sh local nonkube` runs schema init and load via `module_infra_db/common/database/init_schema.sh local` and `load_data.sh local`
- **AWS:** `container-deploy-common.sh` calls `module_infra_db/aws/setup-database.sh` and `validate-infra-outputs.sh`

Local DB = Docker Postgres (Compose in `module_infra_nonkube` when Phase 8 is done).
