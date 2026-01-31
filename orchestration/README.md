# orchestration

Unified entrypoint: `run.sh` and `teardown.sh` dispatch to provider/route scripts. Shared helpers live in `orchestration/shared/` (logger, load-env, load-image-identifiers, load-python-env, etc.).

## Usage

From repo root:
- **`./run.sh <local|aws> <kube|nonkube> [env] [options...]`** – delegates to `run_scripts/main_application_scripts/local/run.sh` or `aws/run.sh` (which in turn use module_infra_* for infra)
- **`./teardown.sh <local|aws> <kube|nonkube|all> [env] [options...]`** – delegates to teardown scripts

Run **`./run.sh help`** or **`./teardown.sh help`** for usage.
