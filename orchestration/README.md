# orchestration

Unified entrypoint: `run.sh` and `teardown.sh` dispatch to provider/route scripts. Shared helpers live in `orchestration/common/` (subdirs: `env/`, `deploy/`, `feedback/`; root: logger, git_helpers, check-dependencies, docker_run, verify-endpoints, wait-for-service).

## Usage

From repo root:
- **`./run.sh <local|aws> <kube|nonkube> [env] [options...]`** – delegates to `orchestration/local/run.sh` or `orchestration/aws/run.sh` (which use module_infra_* for infra)
- **`./teardown.sh <local|aws> <kube|nonkube|all> [env] [options...]`** – delegates to teardown scripts

Run **`./run.sh help`** or **`./teardown.sh help`** for usage.
