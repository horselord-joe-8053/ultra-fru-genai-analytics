# module_infra_kubetypes/nonkube

Non-Kubernetes route: ECS (AWS) and local Docker Compose.

## Layout

- **aws/** – ECS: environments/dev|prod/ecs, modules (ecs, alb, frontend), deploy/helpers/verification scripts
- **local/** – Docker Compose: docker-compose.yml, Dockerfile.api, docker-entrypoint.sh

## Usage

- **Local nonkube:** `./run.sh local nonkube` → start-services.sh uses `module_infra_kubetypes/nonkube/local` (docker-compose); build uses `module_infra_kubetypes/nonkube/local/Dockerfile.api`
- **AWS ECS:** Terraform deploy/teardown use `module_infra_kubetypes/nonkube/aws/terra/environments/<env>/ecs`
