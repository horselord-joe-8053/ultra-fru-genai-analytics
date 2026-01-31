# module_infra_spark

Spark/Delta Lake setup and verification: local (Docker) and AWS (S3). References `module_app_core/spark_jobs` and `module_app_core/data`.

## Layout

- **common/delta-lake/** – Shared: setup-delta-lake.sh, teardown-delta.sh, create-delta-table.sh, verify-delta-lake.sh, helpers/
- **local/delta-lake/** – Local setup-and-verify.sh
- **aws/delta-lake/** – AWS setup-and-verify.sh

## Usage

Invoked by orchestration:

- **Local:** `./run.sh local nonkube` (with ENABLE_ANALYTICS_SCHEDULER or --skip-data-lake) uses `module_infra_spark/local/delta-lake/setup-and-verify.sh`
- **AWS:** container-deploy-common runs `module_infra_spark/aws/delta-lake/setup-and-verify.sh`
- **Teardown local:** teardown-resources-all.sh calls `module_infra_spark/common/delta-lake/teardown-delta.sh --local`
