# module_infra_kubetypes/nonkube

Non-Kubernetes route: ECS (AWS) and local Docker Compose.

## Layout

- **aws/** – ECS: environments/dev|prod/ecs, modules (ecs, alb, frontend), deploy/helpers/verification scripts
- **local/** – Docker Compose for local dev: docker-compose.yml only. The API image is defined in **module_app_core/pack_with_docker/** (Dockerfile.api, docker-entrypoint.sh), shared by local, ECS, and EKS.

## Usage

- **Local nonkube:** `./run.sh local nonkube` → start-services.sh uses `module_infra_kubetypes/nonkube/local` (docker-compose); image build uses `module_app_core/pack_with_docker/Dockerfile.api`
- **AWS ECS:** Terraform deploy/teardown use `module_infra_kubetypes/nonkube/aws/terra/environments/<env>/ecs`; ECR image built from `module_app_core/pack_with_docker/Dockerfile.api`
