# Docker Troubleshooting Guide

## Issue
Docker is experiencing I/O errors due to:
1. **Disk space**: Only 4.2GB free (98% full)
2. **Corrupted Docker state**: Filesystem errors in Docker's internal storage

## Error Messages
- `OSError: [Errno 5] Input/output error`
- `write /var/lib/docker/buildkit/containerd-overlayfs/metadata_v2.db: input/output error`
- `read-only file system` errors

## Solutions (in order of preference)

### Option 1: Free Up Disk Space (RECOMMENDED)
1. Free up at least 10-20GB of disk space
2. Restart Docker Desktop
3. Run: `docker system prune -a -f --volumes` to clean up Docker
4. Rebuild: `docker-compose -f infra/docker/docker-compose.yml build api`
5. Start: `docker-compose -f infra/docker/docker-compose.yml up -d`

### Option 2: Reset Docker Desktop
1. Quit Docker Desktop completely
2. Delete Docker's data (WARNING: This removes all containers/images):
   ```bash
   rm -rf ~/Library/Containers/com.docker.docker/Data
   ```
3. Restart Docker Desktop
4. Rebuild and start services

### Option 3: Use Docker's Reset to Factory Defaults
1. Open Docker Desktop
2. Go to Settings → Troubleshoot
3. Click "Reset to factory defaults"
4. Restart Docker Desktop
5. Rebuild and start services

## Quick Test (Once Docker is Fixed)
```bash
# Rebuild API with new code
docker-compose -f infra/docker/docker-compose.yml build api

# Start services
docker-compose -f infra/docker/docker-compose.yml up -d

# Wait for services to be ready
sleep 10

# Run test
./test/test_query_1_AVG.sh --test-env local
```

## Expected Test Result
The test should now **FAIL** with:
```
AssertionError: [Average feedback rating] CRITICAL: No data was successfully retrieved from the database...
```

This confirms the anti-hallucination validation is working correctly.
