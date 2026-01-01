# Docker Compose Idempotency for Local Testing

## Problem

Unlike Terraform/Terragrunt which have built-in idempotency, `docker-compose up -d` will always attempt to start services, even if they're already running. While `docker-compose up -d` is technically idempotent (won't restart running containers), it still:
- Checks container status
- May rebuild images if Dockerfile changed
- Adds unnecessary overhead to test runs

## Solution

We've implemented a multi-layer idempotency approach:

### 1. Service Check in `start-services.sh`

The `run_scripts/local/start-services.sh` script now checks if services are already running before attempting to start them:

```bash
./run_scripts/local/start-services.sh          # Idempotent: skips if already running
./run_scripts/local/start-services.sh --force  # Forces restart even if running
./run_scripts/local/start-services.sh --build-api  # Rebuilds API image and starts
```

**Behavior:**
- Checks if `fru_db` and `fru_api` containers are running
- If both are running → skips startup (logs message and returns)
- If not running → starts services normally
- `--force` flag bypasses the check and always starts
- `--build-api` flag rebuilds the API image before starting

### 2. Test Script Integration

Test scripts now support `--ensure-services` and `--rebuild-api` flags:

```bash
# Default: Assumes services are already running (fastest)
./test/test_query_1_AVG.sh --test-env local

# Ensure services are running (idempotent check)
./test/test_query_1_AVG.sh --test-env local --ensure-services

# Rebuild API and ensure services are running
./test/test_query_1_AVG.sh --test-env local --rebuild-api
```

**Behavior:**
- Without `--ensure-services`: Assumes services are running, only checks health
- With `--ensure-services`: Checks if services are running, starts them if needed (idempotent)
- With `--rebuild-api`: Rebuilds API image and ensures services are running

### 3. Implementation Details

#### `start-services.sh` Changes:
- Added `check_services_running()` function
- Checks both `fru_db` and `fru_api` containers
- Skips startup if both are running (unless `--force`)
- Still performs health checks to ensure services are ready

#### `test_environment.sh` Changes:
- `setup_local_environment()` now respects `ENSURE_SERVICES` and `REBUILD_API` environment variables
- Checks Docker container status before attempting to start
- Calls `start-services.sh` only if services are not running
- Performs health check with retries after starting services

#### `run_test_suite.sh` Changes:
- Added `--ensure-services` flag parsing
- Added `--rebuild-api` flag parsing (implies `--ensure-services`)
- Exports `ENSURE_SERVICES` and `REBUILD_API` environment variables for use by `setup_local_environment()`

## Usage Examples

### Fast Test Run (Services Already Running)
```bash
# Start services once (if not already running)
./run_scripts/local/start-services.sh

# Run tests multiple times (no Docker overhead)
./test/test_query_1_AVG.sh --test-env local
./test/test_query_1_AVG.sh --test-env local  # Fast - no Docker check
```

### Test Run with Service Check
```bash
# Test will check and start services if needed
./test/test_query_1_AVG.sh --test-env local --ensure-services
```

### Test Run with API Rebuild
```bash
# Rebuild API image and ensure services are running
./test/test_query_1_AVG.sh --test-env local --rebuild-api
```

### Manual Service Management
```bash
# Start services (idempotent)
./run_scripts/local/start-services.sh

# Force restart (even if running)
./run_scripts/local/start-services.sh --force

# Rebuild API and start
./run_scripts/local/start-services.sh --build-api

# Stop services
./run_scripts/local/stop-services.sh
```

## Image Management & Cleanup

### Automatic Cleanup After Build

When you rebuild the API image (using `--build-api` or `--rebuild-api`), the old image becomes a "dangling image" (`<none>:<none>`). These accumulate over time and consume disk space.

**Solution:** Automatic cleanup after build is now enabled:
- After `docker compose build`, dangling images are automatically removed
- Prevents disk space accumulation
- See `DOCKER_IMAGE_MANAGEMENT.md` for details

### Manual Cleanup

Use the cleanup script for periodic maintenance:

```bash
# Show current disk usage
./run_scripts/local/cleanup-docker.sh

# Remove dangling images only
./run_scripts/local/cleanup-docker.sh --images

# Remove all unused resources (careful!)
./run_scripts/local/cleanup-docker.sh --all
```

## Benefits

1. **Faster Test Runs**: No Docker overhead when services are already running
2. **Idempotent**: Safe to run multiple times
3. **Flexible**: Choose when to check/start services vs. assume they're running
4. **Terraform-like**: Similar to Terraform's `plan`/`apply` pattern where you can check state before making changes
5. **Disk Space Management**: Automatic cleanup prevents image accumulation

## Comparison with Terraform

| Feature | Terraform/Terragrunt | Docker Compose (Before) | Docker Compose (After) |
|---------|---------------------|------------------------|----------------------|
| Idempotency | Built-in | Partial (won't restart, but checks) | ✅ Full (checks before starting) |
| State Check | `terraform plan` | Manual `docker ps` | ✅ Automatic check |
| Force Apply | `terraform apply -force` | `docker-compose up -d --force-recreate` | ✅ `--force` flag |
| Rebuild | `terraform apply` (if code changed) | `docker-compose build` | ✅ `--build-api` flag |

## Migration Guide

**Old behavior (still works):**
```bash
# Manually start services
./run_scripts/local/start-services.sh

# Run tests (assumes services running)
./test/test_query_1_AVG.sh --test-env local
```

**New behavior (recommended):**
```bash
# Option 1: Let test script handle it
./test/test_query_1_AVG.sh --test-env local --ensure-services

# Option 2: Manual control (faster for multiple test runs)
./run_scripts/local/start-services.sh  # Once
./test/test_query_1_AVG.sh --test-env local  # Multiple times
```

