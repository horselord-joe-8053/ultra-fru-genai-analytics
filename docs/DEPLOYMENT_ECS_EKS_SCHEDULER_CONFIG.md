# ECS vs EKS: Analytics Scheduler Configuration

The **analytics scheduler** (batch Spark/Delta job that populates `batch_analytics`) is controlled by the same environment variables and the same container logic for both ECS and EKS. Both deployment paths use **the same env loader**: `orchestration/common/env/load-env.sh` (and `load_env_file`), which already exports scheduler vars with the same defaults.

## What is shared

- **Source of truth:** `.env` (e.g. `ENABLE_ANALYTICS_SCHEDULER`, `ANALYTICS_SCHEDULER_INTERVAL_SECONDS`).
- **Container behavior:** Same image and entrypoint (`docker-entrypoint.sh`); it starts the scheduler only when `ENABLE_ANALYTICS_SCHEDULER=true`. App logic lives in `module_app_core/spark_jobs/scheduler.py` (platform-agnostic).
- **Env var names:** Same names in both environments.
- **Deployment-time env:** **`orchestration/common/env/load-env.sh`** (via `load_env_file`) exports scheduler-related vars with one set of defaults (`ENABLE_ANALYTICS_SCHEDULER=false`, `ANALYTICS_SCHEDULER_INTERVAL_SECONDS=3600`, etc.). Both ECS and EKS paths already source this and call `load_env_file` before the step that injects vars into the container.

## How each platform injects the vars

- **ECS:** `orchestration/terraform/deploy.sh` sources `load-env.sh` at startup and calls `load_env_file` again right before the ECS apply so Terragrunt’s `get_env("ENABLE_ANALYTICS_SCHEDULER", "false")` in `env.hcl` sees the exported vars → Terraform task definition → container.
- **EKS:** `module_infra_kubetypes/kube/aws/helpers/kubernetes-manifests.sh` sources `load-env.sh` and `load_env_file` in the ConfigMap generation block, then exports the same vars (with matching defaults) for **envsubst** on `configmap.template.yaml` → ConfigMap → Deployment envFrom → container.

So the **list of scheduler vars and their defaults** lives in one place (`load-env.sh`). The **mechanism** that gets them into the container is still platform-specific (Terraform task def vs ConfigMap + envFrom).

## Summary

| Aspect                 | ECS                                              | EKS                                                                 |
|------------------------|--------------------------------------------------|---------------------------------------------------------------------|
| Who sets scheduler env | `load-env.sh` / `load_env_file` (in deploy.sh)  | `load-env.sh` / `load_env_file` (in kubernetes-manifests.sh)        |
| Where value is read    | Terragrunt `get_env()` at ECS apply time        | Shell env when generating ConfigMap (after load_env_file)          |
| Final carrier          | Terraform → ECS task definition                  | envsubst → ConfigMap → Deployment envFrom                          |

The **scheduling logic** is unified in `module_app_core`; both paths **already** use the same env loader (`load-env.sh`); the only difference is how that env is injected (Terraform vs script + kubectl).
