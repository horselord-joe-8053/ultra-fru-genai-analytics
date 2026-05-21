# App container image (API)

This directory holds the **deployment-agnostic** definition of the FRU API container image. It is shared by:

- **Local:** Docker Compose (`module_infra_kubetypes/nonkube/local/docker-compose.yml`) and `./run.sh local nonkube`
- **AWS ECS:** `module_infra_basic/aws/build-push-ecr.sh` → ECR → ECS tasks
- **AWS EKS:** Same ECR image used by Kubernetes deployments

The image contains the app (backend + spark_jobs from module_app_core), Spark, Java, and the entrypoint that runs Flask and optionally the analytics scheduler.

**Build context:** Always the repo root (`REPO_ROOT`). Example:

```bash
docker build -f module_app_core/pack_with_docker/Dockerfile.api .
```
