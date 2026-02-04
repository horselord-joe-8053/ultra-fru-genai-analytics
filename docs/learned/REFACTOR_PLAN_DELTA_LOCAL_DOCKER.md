# Refactor plan: Delta table creation via local Docker (ECR image)

**Status: Implemented.** Delta creation now uses `EXECUTION_METHOD=docker_ecr` (local Docker + ECR image) for AWS; works for both ECS and EKS.

**Goal:** Run the one-off Delta table creation using **local Docker** with the **same ECR image** used for EKS/ECS. One code path for both deployment types; no dependency on ECS or EKS for this step.

**Previous state:** `module_infra_spark/aws/delta-lake/setup-and-verify.sh` set `EXECUTION_METHOD=ecs_task` and called `run-spark-job-aws.sh` (ECS Run Task), which failed when deploying EKS-only.

---

## 1. High-level change

- **Before:** AWS Delta creation → ECS Run Task (same ECR image, Spark job as overridden command).
- **After:** AWS Delta creation → **local** `docker run <ECR_IMAGE> /bin/sh -c "spark-submit ..."` with AWS creds and S3 paths. Runner must have Docker and ECR login.

---

## 2. Files to touch (no code yet — plan only)

| File | Change |
|------|--------|
| **module_infra_spark/aws/delta-lake/setup-and-verify.sh** | For Substep 2/3: set `EXECUTION_METHOD=docker_ecr` (or `docker_local_ecr`); pass `CONTAINER_IMAGE` (from env, already set by run.sh). Remove `CLUSTER_NAME` / `SERVICE_NAME` for this path. Ensure `CONTAINER_IMAGE` is set or fail fast with a clear message. |
| **module_infra_spark/common/delta-lake/create-delta-table.sh** | Add a new case for `EXECUTION_METHOD=docker_ecr`: call a new helper that runs `docker run ... $CONTAINER_IMAGE spark-submit ...`. Require env: `CONTAINER_IMAGE`, `SPARK_PACKAGES`, `PATH_CHECK_METHOD=s3`. Optional: after Delta creation with `docker_ecr`, skip or adapt “trigger analytics” (today ECS-only); for EKS the scheduler in the app pod will run periodically anyway. |
| **New: module_infra_spark/common/delta-lake/helpers/aws/run-spark-job-docker-ecr.sh** (or **helpers/local/run-spark-job-docker-ecr.sh**) | **Inputs:** `INPUT_PATH` (s3a), `OUTPUT_PATH` (s3a), `SPARK_PACKAGES`, `CONTAINER_IMAGE`. **Steps:** (1) Ensure Docker and `CONTAINER_IMAGE` set. (2) Get S3A config from existing Python helper (`get_s3a_spark_config`) — run Python on **host** with `REPO_ROOT` so `spark_jobs.utils.spark_config` resolves. (3) `docker run --rm` with AWS creds (e.g. `-e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN -e AWS_REGION`, or mount `~/.aws` and `-e AWS_PROFILE`). (4) Override command: `/bin/sh -c "spark-submit --packages $SPARK_PACKAGES $S3A_CONFIG /app/spark_jobs/ingest_delta.py $INPUT_PATH $OUTPUT_PATH"`. (5) Wait for container exit; propagate exit code. **Prerequisite:** Runner must be logged into ECR (`aws ecr get-login-password \| docker login ...`); can be done in this script or documented and done by run.sh before data-lake phase. |

---

## 3. Flow after refactor

1. **run.sh** (e.g. `./run.sh aws kube dev`) → loads `CONTAINER_IMAGE` via `load-image-identifiers.sh`; exports it.
2. **deploy_phase_setup_data_lake** → runs `module_infra_spark/aws/delta-lake/setup-and-verify.sh` (with `--preempt` / `--force-refresh-data` as today).
3. **setup-and-verify.sh** → Substep 1 unchanged (S3 + IAM via Terraform). Substep 2: set `EXECUTION_METHOD=docker_ecr`, `CONTAINER_IMAGE` from env; call `create-delta-table.sh` with S3 paths and packages (from existing Python helper).
4. **create-delta-table.sh** → branch `docker_ecr`: call `run-spark-job-docker-ecr.sh` with `INPUT_PATH`, `OUTPUT_PATH`, `SPARK_PACKAGES`, `CONTAINER_IMAGE`.
5. **run-spark-job-docker-ecr.sh** → ECR login if needed; `docker run ... $CONTAINER_IMAGE spark-submit ...`; exit with job status.

No ECS, no EKS in this path; same for `aws kube` and `aws nonkube`.

---

## 4. Prerequisites and assumptions

- **Runner:** Has Docker, AWS CLI, and (for ECR) already logged in or script runs `aws ecr get-login-password | docker login ...` for the repo’s ECR registry.
- **CONTAINER_IMAGE:** Set by run.sh before the data-lake phase (already true when deploying app).
- **S3 paths:** Same as today (s3a://bucket/raw/..., s3a://bucket/delta/...); Python helper `get_spark_packages(is_aws_deployment=True)` and `to_spark_path` unchanged.
- **S3A config:** Same Python helper `get_s3a_spark_config()`; must run on host with AWS env so S3A creds work inside the container when passed via `-e`.

---

## 5. Optional improvements (later)

- **Error visibility:** In `setup-and-verify.sh`, when `create_cmd` fails, capture and log stderr/stdout so “Delta table creation failed” shows the underlying error (e.g. ECR login, Spark, S3).
- **ECR login:** In run.sh or at the start of setup-and-verify.sh, ensure ECR login before Substep 2 so `docker run` can pull the image if missing locally.

---

## 6. What to remove or keep

- **Keep:** `run-spark-job-aws.sh` and the `ecs_task` branch in `create-delta-table.sh` can remain for backward compatibility or be removed later if we fully switch to `docker_ecr` for AWS.
- **Recommendation:** Use only `docker_ecr` for AWS (both ECS and EKS); remove or deprecate `ecs_task` in a follow-up to simplify code.

---

*Refactor plan only; no code changes in this document. See `temp_delta_oneoff_fix.sh` for a one-off script to create the Delta table via local Docker until this refactor is implemented.*

---

## 7. What to do next (concise)

1. **Unblock EKS deploy now:** After `./run.sh aws kube dev --preempt --skip-data-lake` (or with data-lake failing), run `./temp_delta_oneoff_fix.sh dev` from repo root. Ensures CONTAINER_IMAGE and AWS creds are set (e.g. from a prior deploy or load-image-identifiers + .env). Creates the Delta table in S3 via local Docker.
2. **Implement refactor:** Follow §2–3: add `run-spark-job-docker-ecr.sh`, add `docker_ecr` branch in `create-delta-table.sh`, switch `setup-and-verify.sh` (AWS) to `EXECUTION_METHOD=docker_ecr` and `CONTAINER_IMAGE`. Optionally ensure ECR login before data-lake phase in run.sh.
3. **Remove one-off:** After the refactor is in place and tested for both ECS and EKS, delete `temp_delta_oneoff_fix.sh`.
