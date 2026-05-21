# Database Setup Explanation: Local vs AWS

This document explains how database configuration works in local development versus AWS deployment, and why certain variables behave differently in each environment.

---

## Table of Contents

1. [Overview: Two Different Database Systems](#1-overview-two-different-database-systems)
2. [Local Environment: Direct Database Connection](#2-local-environment-direct-database-connection)
3. [AWS Environment: Managed Database with Terraform](#3-aws-environment-managed-database-with-terraform)
4. [Why PGHOST=localhost is Not Used in AWS](#4-why-pghostlocalhost-is-not-used-in-aws)
5. [Why PGPASSWORD vs DB_PASSWORD Variable Name Mismatch](#5-why-pgpassword-vs-db_password-variable-name-mismatch)
6. [Runtime Behavior: How Containers Get Database Information](#6-runtime-behavior-how-containers-get-database-information)
7. [Summary: Variable Usage Comparison](#7-summary-variable-usage-comparison)

---

## 1. Overview: Two Different Database Systems

### Local Development
- **Database Type**: PostgreSQL running in Docker container
- **Location**: Your local machine (`localhost`)
- **Configuration**: Direct connection using values from `.env` file
- **Connection**: Simple hostname `localhost` or Docker service name `db`

### AWS Deployment
- **Database Type**: Amazon Aurora PostgreSQL (managed service)
- **Location**: AWS cloud infrastructure
- **Configuration**: Created and managed by Terraform
- **Connection**: Aurora cluster endpoint (e.g., `fru-dev-aurora-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com`)

**Key Difference**: In AWS, the database doesn't exist until Terraform creates it. The connection details are only known after Terraform deployment completes.

---

## 2. Local Environment: Direct Database Connection

### How It Works

In local development, your `.env` file contains:

```bash
PGHOST=localhost
PGPORT=5432
PGUSER=postgres
PGPASSWORD=postgres
PGDATABASE=fru_db
```

These values are used **directly** by:

1. **Docker Compose** (`infra/docker/docker-compose.yml`):
   - Creates PostgreSQL container with these credentials
   - Sets environment variables for the API container

2. **Database Initialization Scripts** (`run_scripts/local/init-db.sh`):
   - Uses `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` to connect via `psql`

3. **ETL Scripts** (`run_scripts/local/load-data.sh`):
   - Uses all database variables to connect and load data

4. **API Container**:
   - Reads database connection from environment variables set by Docker Compose

### Flow Diagram

```
.env file
    ↓
Docker Compose reads variables
    ↓
PostgreSQL container created with PGPASSWORD, PGDATABASE, etc.
    ↓
API container gets environment variables
    ↓
API connects to database using PGHOST=db (Docker service name)
```

**Note**: Inside Docker containers, `PGHOST=db` (the Docker service name), not `localhost`. This is because containers communicate via Docker's internal network.

---

## 3. AWS Environment: Managed Database with Terraform

### How It Works

In AWS deployment, the database is **created by Terraform** using values from your `.env` file. The process is:

1. **Terraform reads from `.env`**:
   - `DB_PASSWORD=postgres` → Used to create Aurora database password
   - `PGDATABASE=fru_db` → Used to create database name
   - `OPENAI_API_KEY` → Stored in Secrets Manager

2. **Terraform creates resources**:
   - Aurora PostgreSQL cluster
   - Secrets Manager secrets (for passwords)
   - VPC, subnets, security groups

3. **Terraform outputs connection information**:
   - Aurora endpoint (e.g., `fru-dev-aurora-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com`)
   - Database port (usually `5432`)
   - Database name

4. **Terraform passes information to ECS**:
   - ECS task definition gets Aurora endpoint as `PGHOST`
   - ECS task definition gets password from Secrets Manager ARN

### Flow Diagram

```
.env file (DB_PASSWORD, PGDATABASE)
    ↓
Terraform reads variables
    ↓
Terraform creates Aurora cluster
    ↓
Terraform creates Secrets Manager secrets
    ↓
Terraform outputs: aurora_endpoint, db_password_secret_arn
    ↓
ECS task definition uses:
  - PGHOST = aurora_endpoint (from Terraform output)
  - PGPASSWORD = from Secrets Manager (via secret ARN)
```

---

## 4. Why PGHOST=localhost is Not Used in AWS

### The Problem

Your `.env` file has:
```bash
PGHOST=localhost
```

But in AWS, this value is **completely ignored** and replaced by the Aurora endpoint.

### Why This Happens

1. **Aurora is a Managed Service**:
   - Aurora PostgreSQL runs on AWS infrastructure, not on your local machine
   - It has a unique endpoint URL assigned by AWS (e.g., `fru-dev-aurora-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com`)
   - This endpoint is only known **after** Terraform creates the Aurora cluster

2. **Terraform Creates the Database**:
   - When you run `run_scripts/aws/run.sh`, Terraform creates the Aurora cluster
   - Terraform outputs the cluster endpoint (see `infra/terraform/modules/infrastructure/outputs.tf` line 18-20)
   - This endpoint is passed to the ECS module

3. **ECS Task Definition Uses Terraform Output**:
   - In `infra/terraform/modules/ecs/main.tf` (lines 91-92), the ECS task definition sets:
     ```hcl
     environment = [
       {
         name  = "PGHOST"
         value = var.aurora_endpoint  # ← From Terraform output, not .env
       }
     ]
     ```

4. **Runtime Containers Get Aurora Endpoint**:
   - When your ECS task starts, it gets `PGHOST` from the task definition
   - The value is the Aurora endpoint, not `localhost`
   - Your application connects to Aurora, not a local database

### Visual Comparison

**Local**:
```
Application → PGHOST=localhost → PostgreSQL on your machine
```

**AWS**:
```
Application → PGHOST=fru-dev-aurora-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com → Aurora in AWS
```

### Summary

- **Local**: `PGHOST=localhost` is used because the database is on your machine
- **AWS**: `PGHOST=localhost` is ignored because:
  1. The database is in AWS, not localhost
  2. Terraform creates the database and knows the endpoint
  3. ECS task definition uses Terraform's output (Aurora endpoint) instead

---

## 5. Why PGPASSWORD vs DB_PASSWORD Variable Name Mismatch

### The Problem

Your `.env` file has:
```bash
PGPASSWORD=postgres
```

But Terraform expects:
```bash
DB_PASSWORD=postgres
```

### Why This Happens

1. **Different Naming Conventions**:
   - **PostgreSQL standard**: Uses `PGPASSWORD` (the `PG` prefix is standard for PostgreSQL environment variables)
   - **Terraform convention**: Uses `DB_PASSWORD` (more generic, works for any database type)

2. **Where Each is Used**:

   **`PGPASSWORD`** (PostgreSQL standard):
   - Used by PostgreSQL client tools (`psql`, `pg_dump`, etc.)
   - Used by application code that connects to PostgreSQL
   - Used in local development (Docker Compose, scripts)

   **`DB_PASSWORD`** (Terraform convention):
   - Used by Terraform to create the Aurora database
   - Terraform reads `DB_PASSWORD` from environment variables
   - See `infra/terraform/environments/dev/terragrunt.hcl` line 32:
     ```hcl
     db_password = get_env("DB_PASSWORD", "ChangeMe123!")
     ```

3. **The Flow**:

   **Local Development**:
   ```
   .env: PGPASSWORD=postgres
        ↓
   Docker Compose uses PGPASSWORD
        ↓
   PostgreSQL container created with password "postgres"
   ```

   **AWS Deployment**:
   ```
   .env: DB_PASSWORD=postgres
        ↓
   Terraform reads DB_PASSWORD
        ↓
   Terraform creates Aurora with master password "postgres"
        ↓
   Terraform stores password in Secrets Manager
        ↓
   ECS task definition references Secrets Manager
        ↓
   Container gets PGPASSWORD from Secrets Manager at runtime
   ```

4. **Why Both Exist**:
   - **`PGPASSWORD`**: For application runtime (what your code uses)
   - **`DB_PASSWORD`**: For Terraform deployment (what Terraform uses to create the database)

### The Solution

Your `.env` file should have **both**:
```bash
PGPASSWORD=postgres    # For local development and application runtime
DB_PASSWORD=postgres   # For Terraform to create Aurora database
```

This way:
- Local scripts use `PGPASSWORD`
- Terraform uses `DB_PASSWORD` to create the database
- At runtime, containers get `PGPASSWORD` from Secrets Manager (created by Terraform using `DB_PASSWORD`)

### What Happens Without DB_PASSWORD

If `DB_PASSWORD` is not set, Terraform will use the default value:
```hcl
db_password = get_env("DB_PASSWORD", "ChangeMe123!")  # Default: "ChangeMe123!"
```

This means:
- Your Aurora database will be created with password `"ChangeMe123!"` instead of `"postgres"`
- Your application might fail to connect if it expects `"postgres"`
- You'll need to manually update the password or use the default

---

## 6. Runtime Behavior: How Containers Get Database Information

### Overview

In AWS, your ECS containers **do not read from `.env` directly**. Instead, they get database connection information from:

1. **Terraform outputs** (for non-sensitive values)
2. **Secrets Manager** (for sensitive values like passwords)
3. **IAM roles** (for AWS service access)

### Detailed Flow

#### Step 1: Terraform Creates Resources

When you run `run_scripts/aws/run.sh`, Terraform:

1. **Creates Aurora cluster**:
   - Uses `DB_PASSWORD` from `.env` to set the master password
   - Creates database with name from `PGDATABASE` (or Terraform variable)
   - AWS assigns an endpoint URL

2. **Creates Secrets Manager secrets**:
   - Stores `DB_PASSWORD` in Secrets Manager
   - Stores `OPENAI_API_KEY` in Secrets Manager
   - See `infra/terraform/modules/secrets-manager/main.tf` lines 33-51

3. **Outputs connection information**:
   - `aurora_endpoint` → The Aurora cluster endpoint
   - `aurora_port` → Usually `5432`
   - `aurora_database_name` → Database name
   - `db_password_secret_arn` → ARN of the Secrets Manager secret containing the password
   - See `infra/terraform/modules/infrastructure/outputs.tf`

#### Step 2: Terraform Passes Information to ECS

The application layer Terraform configuration:

1. **Receives outputs from infrastructure layer**:
   ```hcl
   aurora_endpoint = dependency.infrastructure.outputs.aurora_endpoint
   db_password_secret_arn = dependency.infrastructure.outputs.db_password_secret_arn
   ```
   See `infra/terraform/environments/dev/application/terragrunt.hcl` lines 56-62

2. **Passes to ECS module**:
   - ECS module receives `aurora_endpoint` and `db_password_secret_arn`
   - See `infra/terraform/modules/ecs/variables.tf`

#### Step 3: ECS Task Definition Configuration

The ECS task definition (`infra/terraform/modules/ecs/main.tf`) sets environment variables:

**Non-sensitive values** (from Terraform outputs):
```hcl
environment = [
  {
    name  = "PGHOST"
    value = var.aurora_endpoint  # ← From Terraform output
  },
  {
    name  = "PGPORT"
    value = tostring(var.aurora_port)  # ← From Terraform output
  },
  {
    name  = "PGDATABASE"
    value = var.aurora_database_name  # ← From Terraform output
  }
]
```

**Sensitive values** (from Secrets Manager):
```hcl
secrets = [
  {
    name      = "PGPASSWORD"
    valueFrom = var.db_password_secret_arn  # ← Reference to Secrets Manager
  },
  {
    name      = "OPENAI_API_KEY"
    valueFrom = var.openai_secret_arn  # ← Reference to Secrets Manager
  }
]
```

#### Step 4: Container Runtime

When your ECS task starts:

1. **ECS retrieves secrets from Secrets Manager**:
   - ECS task execution role has permission to read Secrets Manager
   - ECS retrieves the actual password value from Secrets Manager using the ARN
   - ECS injects the password as `PGPASSWORD` environment variable

2. **Container receives environment variables**:
   - `PGHOST` = Aurora endpoint (e.g., `fru-dev-aurora-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com`)
   - `PGPORT` = `5432`
   - `PGDATABASE` = `fru_db`
   - `PGPASSWORD` = Actual password from Secrets Manager (originally from `DB_PASSWORD` in `.env`)
   - `PGUSER` = Database username (may also come from Secrets Manager)

3. **Application connects to database**:
   - Your application code reads `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`
   - Connects to Aurora using these values
   - **No `.env` file is used at runtime**

### Visual Flow Diagram

```
┌─────────────────────────────────────────────────────────────┐
│ Deployment Time (run_scripts/aws/run.sh)                     │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ .env file                                                    │
│   DB_PASSWORD=postgres                                       │
│   PGDATABASE=fru_db                                          │
│   OPENAI_API_KEY=sk-...                                      │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Terraform Infrastructure Layer                               │
│   1. Creates Aurora cluster                                  │
│      - Uses DB_PASSWORD to set master password              │
│      - Creates database with name from PGDATABASE            │
│   2. Creates Secrets Manager secrets                        │
│      - Stores DB_PASSWORD as secret                         │
│      - Stores OPENAI_API_KEY as secret                      │
│   3. Outputs:                                                │
│      - aurora_endpoint                                       │
│      - db_password_secret_arn                                │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Terraform Application Layer                                  │
│   Receives outputs from infrastructure layer                │
│   Passes to ECS module                                       │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ ECS Task Definition                                          │
│   environment:                                               │
│     - PGHOST = aurora_endpoint                               │
│     - PGPORT = 5432                                          │
│     - PGDATABASE = fru_db                                    │
│   secrets:                                                   │
│     - PGPASSWORD = db_password_secret_arn                   │
│     - OPENAI_API_KEY = openai_secret_arn                    │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Runtime (ECS Task Starts)                                    │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ ECS retrieves secrets from Secrets Manager                   │
│   - Reads actual password value using ARN                    │
│   - Injects as PGPASSWORD environment variable               │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Container Environment Variables                               │
│   PGHOST=fru-dev-aurora-cluster.cluster-xxxxx...            │
│   PGPORT=5432                                                │
│   PGDATABASE=fru_db                                          │
│   PGPASSWORD=postgres  ← From Secrets Manager                │
│   OPENAI_API_KEY=sk-...  ← From Secrets Manager              │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Application Code                                             │
│   Reads environment variables                                 │
│   Connects to Aurora database                                │
└─────────────────────────────────────────────────────────────┘
```

### Key Points

1. **`.env` is only used during deployment**, not at runtime
2. **Terraform creates the database** and knows the endpoint
3. **Secrets Manager stores sensitive values** securely
4. **ECS task definition references Secrets Manager** using ARNs
5. **At runtime, ECS retrieves secrets** and injects them as environment variables
6. **Containers never see `.env` file** - they only see environment variables set by ECS

### Why This Design?

1. **Security**: Passwords are stored in Secrets Manager, not in code or task definitions
2. **Flexibility**: Database endpoint is only known after Terraform creates it
3. **Best Practices**: Follows AWS recommended patterns for secrets management
4. **Separation of Concerns**: Deployment configuration (`.env`) is separate from runtime configuration (Terraform outputs + Secrets Manager)

---

## 7. Summary: Variable Usage Comparison

### Local Environment

| Variable | Used By | Purpose |
|----------|---------|---------|
| `PGHOST=localhost` | ✅ init-db.sh, load-data.sh | Connect to local PostgreSQL |
| `PGPORT=5432` | ✅ init-db.sh, load-data.sh | PostgreSQL port |
| `PGUSER=postgres` | ✅ docker-compose, init-db.sh, API | Database username |
| `PGPASSWORD=postgres` | ✅ docker-compose, init-db.sh, API | Database password |
| `PGDATABASE=fru_db` | ✅ docker-compose, init-db.sh, API | Database name |
| `DB_PASSWORD` | ❌ Not used | Not needed for local |

**Flow**: `.env` → Docker Compose → Containers

---

### AWS Environment

| Variable | Used By | Purpose |
|----------|---------|---------|
| `PGHOST=localhost` | ❌ **Not used** | Replaced by Aurora endpoint |
| `PGPORT=5432` | ⚠️ May be used | Usually standard 5432 |
| `PGUSER=postgres` | ⚠️ May be used | May be set by Terraform |
| `PGPASSWORD=postgres` | ❌ **Not used directly** | Terraform uses `DB_PASSWORD` instead |
| `PGDATABASE=fru_db` | ✅ Terraform | Used to create database |
| `DB_PASSWORD=postgres` | ✅ **Terraform** | Used to create Aurora password |

**Flow**: `.env` → Terraform → Aurora + Secrets Manager → ECS Task Definition → Containers

**Runtime Values** (what containers actually see):
- `PGHOST` = Aurora endpoint (from Terraform output)
- `PGPORT` = `5432` (from Terraform output)
- `PGDATABASE` = `fru_db` (from Terraform output)
- `PGPASSWORD` = Value from Secrets Manager (originally from `DB_PASSWORD` in `.env`)
- `PGUSER` = May come from Secrets Manager or Terraform variable

---

## Conclusion

### Key Takeaways

1. **Local**: `.env` values are used directly at runtime
2. **AWS**: `.env` values are used during Terraform deployment to **create** resources
3. **AWS Runtime**: Containers get values from Terraform outputs and Secrets Manager, not from `.env`
4. **Variable Names**: Use `PGPASSWORD` for local, `DB_PASSWORD` for Terraform (both should be in `.env`)
5. **PGHOST**: `localhost` works locally, but is replaced by Aurora endpoint in AWS

### Recommended `.env` Configuration

For both local and AWS to work correctly, your `.env` should have:

```bash
# Database Configuration (for local development)
PGHOST=localhost
PGPORT=5432
PGUSER=postgres
PGPASSWORD=postgres
PGDATABASE=fru_db

# Database Configuration (for Terraform/AWS)
DB_PASSWORD=postgres  # ← Required for Terraform to create Aurora
```

This ensures:
- ✅ Local scripts work (use `PGPASSWORD`, `PGHOST`, etc.)
- ✅ Terraform works (uses `DB_PASSWORD` to create Aurora)
- ✅ Runtime containers work (get values from Terraform outputs and Secrets Manager)

