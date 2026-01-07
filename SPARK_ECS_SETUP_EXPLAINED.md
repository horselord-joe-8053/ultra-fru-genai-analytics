# Where Spark is Configured in ECS Container

## Answer: Spark is Installed in the Docker Image, Terraform Just References It

Spark is **installed during Docker image build**, not in Terraform. Terraform only sets environment variables that point to where Spark is installed.

---

## 1. Spark Installation: `infra/docker/Dockerfile.api`

**Location**: `infra/docker/Dockerfile.api` (lines 5-28)

**What happens**:
```dockerfile
# Install Java 21 (required for Spark 4.0.x)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openjdk-21-jdk-headless \
        curl \
        wget \
        && rm -rf /var/lib/apt/lists/*

# Install Spark
ARG SPARK_VERSION=4.0.1
ARG HADOOP_VERSION=3
ENV SPARK_HOME=/opt/spark
ENV PATH=$SPARK_HOME/bin:$PATH

# Download and extract Spark
RUN curl -fSL https://dlcdn.apache.org/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-hadoop${HADOOP_VERSION}.tgz -o spark.tgz && \
    tar -xzf spark.tgz && \
    mv spark-${SPARK_VERSION}-bin-hadoop${HADOOP_VERSION} ${SPARK_HOME} && \
    rm spark.tgz
```

**Result**: Spark 4.0.1 is installed at `/opt/spark` inside the Docker image.

---

## 2. Docker Image Build Process

**For Local Development**:
- `docker-compose.yml` builds the image using `Dockerfile.api`
- Image is built locally and used by `docker-compose`

**For AWS ECS**:
- Same `Dockerfile.api` is used
- Image is built and pushed to ECR (Elastic Container Registry)
- Process: `run_scripts/aws/shared/build-push-ecr.sh` → builds image → pushes to ECR

**Key Point**: The same Docker image (with Spark pre-installed) is used for both local Docker and AWS ECS.

---

## 3. Terraform ECS Task Definition: Environment Variables

**Location**: `infra/terraform/modules/ecs/main.tf` (lines 137-139, 149-153)

**What Terraform does**:
```hcl
container_definitions = jsonencode([
  {
    name  = var.container_name
    image = var.container_image  # ← Points to ECR image (built from Dockerfile.api)
    
    environment = [
      # ... other env vars ...
      
      {
        name  = "SPARK_HOME"
        # Default to /opt/spark if spark_home is empty
        value = var.spark_home != "" ? var.spark_home : "/opt/spark"
      },
      {
        name  = "DELTA_LAKE_PACKAGE"
        # Delta Lake package (Maven coordinates) - required for Spark jobs
        value = var.delta_lake_package
      },
      {
        name  = "DEPLOYMENT_TYPE"
        # Deployment type (e.g., 'ecs', 'eks') - used by analytics scheduler
        value = var.deployment_type
      }
    ]
  }
])
```

**What Terraform does NOT do**:
- ❌ Does NOT install Spark
- ❌ Does NOT download Spark
- ❌ Does NOT configure Spark

**What Terraform DOES do**:
- ✅ Sets `SPARK_HOME=/opt/spark` environment variable (points to where Spark is in the image)
- ✅ Sets `DELTA_LAKE_PACKAGE` (Maven coordinates for Spark packages)
- ✅ Sets `DEPLOYMENT_TYPE` (so scheduler knows it's ECS and needs S3A config)

---

## 4. Complete Flow: From Dockerfile to ECS

```
┌─────────────────────────────────────────────────────────────┐
│ Step 1: Build Docker Image (Local or CI/CD)                │
│                                                             │
│  Dockerfile.api                                             │
│  ├── Install Java 21                                       │
│  ├── Download Spark 4.0.1                                   │
│  ├── Extract to /opt/spark                                 │
│  ├── Set SPARK_HOME=/opt/spark                             │
│  └── Copy application code                                  │
│                                                             │
│  Result: Image with Spark pre-installed at /opt/spark      │
└─────────────────────────────────────────────────────────────┘
                          │
                          │ docker build / docker push
                          ▼
┌─────────────────────────────────────────────────────────────┐
│ Step 2: Push to ECR (AWS Container Registry)               │
│                                                             │
│  ECR Repository: fru-api                                    │
│  Image Tag: latest (or git SHA)                             │
│  Image URI: 123456789012.dkr.ecr.us-east-1.amazonaws.com/  │
│             fru-api:latest                                  │
└─────────────────────────────────────────────────────────────┘
                          │
                          │ Terraform references this image
                          ▼
┌─────────────────────────────────────────────────────────────┐
│ Step 3: Terraform Creates ECS Task Definition              │
│                                                             │
│  infra/terraform/modules/ecs/main.tf                        │
│  ├── container_image = "ECR_URI:latest"                    │
│  ├── environment: SPARK_HOME=/opt/spark                    │
│  ├── environment: DELTA_LAKE_PACKAGE=...                   │
│  └── environment: DEPLOYMENT_TYPE=ecs                      │
│                                                             │
│  Result: ECS task definition that uses the image            │
└─────────────────────────────────────────────────────────────┘
                          │
                          │ ECS Service runs tasks
                          ▼
┌─────────────────────────────────────────────────────────────┐
│ Step 4: ECS Container Runs                                 │
│                                                             │
│  Container (from ECR image)                                 │
│  ├── Spark installed at /opt/spark (from Dockerfile)       │
│  ├── SPARK_HOME=/opt/spark (from Terraform env var)        │
│  ├── Python app runs                                        │
│  └── scheduler.py can call spark-submit                     │
│                                                             │
│  Result: Container with Spark ready to use                  │
└─────────────────────────────────────────────────────────────┘
```

---

## 5. Why AWS Doesn't Need Step 3.5 (Spark Setup)

**Local `run.sh` Step 3.5**:
- Purpose: Optionally install Spark locally on host machine
- Why needed: For developers who want to run Spark jobs outside Docker
- Location: `run_scripts/common/spark/setup-spark-local.sh`

**AWS `run.sh` (no Step 3.5)**:
- **No local Spark setup needed** because:
  1. Spark is already in the Docker image (installed during build)
  2. ECS runs containers, not host machines
  3. All Spark execution happens inside the container

**AWS Step 3.7** (Delta Lake setup):
- Purpose: Create Delta table in S3 (not install Spark)
- Uses: Spark that's already in the container
- Location: `run_scripts/aws/delta-lake/setup-and-verify.sh`

---

## 6. Key Files Summary

| File | Purpose | What It Does |
|------|---------|--------------|
| `infra/docker/Dockerfile.api` | **Installs Spark** | Downloads and installs Spark 4.0.1 to `/opt/spark` |
| `infra/terraform/modules/ecs/main.tf` | **References Spark** | Sets `SPARK_HOME=/opt/spark` env var (points to where Spark is in image) |
| `run_scripts/aws/shared/build-push-ecr.sh` | **Builds & pushes image** | Builds Docker image (with Spark) and pushes to ECR |
| `backend/services/analytics/scheduler.py` | **Uses Spark** | Calls `spark-submit` (which is at `/opt/spark/bin/spark-submit` in container) |

---

## 7. Verification: How to Confirm Spark is in Container

**In Local Docker**:
```bash
docker exec fru_api ls -la /opt/spark/bin/spark-submit
# Should show: /opt/spark/bin/spark-submit exists

docker exec fru_api /opt/spark/bin/spark-submit --version
# Should show: version 4.0.1
```

**In AWS ECS** (using ECS Exec):
```bash
aws ecs execute-command \
  --cluster fru-dev-cluster \
  --task <task-id> \
  --container fru-api \
  --command "/opt/spark/bin/spark-submit --version" \
  --interactive
```

---

## Conclusion

**Spark is installed in the Docker image** (`Dockerfile.api`), not in Terraform. Terraform only:
1. References the Docker image (which has Spark pre-installed)
2. Sets environment variables (`SPARK_HOME`, `DELTA_LAKE_PACKAGE`, `DEPLOYMENT_TYPE`)

This is why AWS doesn't need a "Step 3.5" to install Spark - it's already in the container image that ECS runs.

