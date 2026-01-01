# Docker Image Management & Cleanup

## Current Behavior Analysis

### 1. When Images Are Built

**Test Script Behavior:**
- `./test/test_query_1_AVG.sh --test-env local` → **NO build** (assumes services running)
- `./test/test_query_1_AVG.sh --test-env local --ensure-services` → **NO build** (only starts if not running)
- `./test/test_query_1_AVG.sh --test-env local --rebuild-api` → **BUILDS** new image

**Manual Script Behavior:**
- `./run_scripts/local/start-services.sh` → **NO build** (uses existing image)
- `./run_scripts/local/start-services.sh --build-api` → **BUILDS** new image

**Docker Compose Behavior:**
- `docker compose up -d` → **NO build** (uses existing image if available)
- `docker compose build` → **BUILDS** new image
- `docker compose up --build` → **BUILDS** then starts

### 2. What Happens to Old Images

When you rebuild an image:

1. **New image is created** with the same tag (or no tag)
2. **Old image becomes `<none>:<none>`** (dangling image)
3. **Old image is NOT automatically deleted**
4. **Disk space accumulates** over time

**Example:**
```bash
# First build
docker compose build api
# Creates: fru-genai-analytics-all_api:latest (500MB)

# Second build (after code change)
docker compose build api
# Creates: fru-genai-analytics-all_api:latest (500MB) ← new
# Old becomes: <none>:<none> (500MB) ← still exists!

# Total disk usage: 1GB (500MB + 500MB)
```

### 3. Docker Image Layers & Caching

Docker uses **layer caching** to speed up builds:

- **Unchanged layers** are reused (e.g., `pip install` if `requirements.txt` unchanged)
- **Changed layers** are rebuilt (e.g., `COPY backend` if code changed)
- **Cache is stored** in Docker's build cache

**Problem:** Even with caching, old images accumulate as dangling images.

## Solutions

### Solution 1: Automatic Cleanup After Build (Recommended)

Add cleanup of dangling images after building:

```bash
# After docker compose build, remove dangling images
docker image prune -f
```

**Pros:**
- Prevents accumulation
- Simple to implement
- Minimal disk usage

**Cons:**
- Slightly slower (cleanup step)
- Removes ALL dangling images (not just ours)

### Solution 2: Tagged Images with Timestamps

Tag images with timestamps to track versions:

```bash
# Build with timestamp tag
IMAGE_TAG=$(date +%Y%m%d-%H%M%S)
docker compose build --tag api:$IMAGE_TAG api
```

**Pros:**
- Can keep multiple versions
- Easy to rollback
- Clear version history

**Cons:**
- More complex
- Still accumulates (unless cleaned)

### Solution 3: Build Cache Optimization

Use Docker's build cache more effectively:

```dockerfile
# Order matters: put frequently changing layers last
COPY requirements.txt /app/requirements.txt  # ← Changes rarely
RUN pip install -r requirements.txt           # ← Cached if requirements.txt unchanged
COPY backend /app/backend                     # ← Changes frequently
```

**Current Dockerfile is already optimized!** ✅

### Solution 4: Periodic Cleanup Script

Create a cleanup script to run periodically:

```bash
# Remove dangling images older than 1 day
docker image prune -a -f --filter "until=24h"
```

## Recommended Implementation

Combine **Solution 1** (automatic cleanup) with **Solution 4** (periodic cleanup):

1. **After each build**: Remove dangling images
2. **Periodic cleanup**: Remove old unused images

This gives us:
- ✅ No accumulation during development
- ✅ Clean disk space
- ✅ Fast builds (layer caching still works)
- ✅ Simple implementation

## Implementation Plan

1. Add cleanup to `start-services.sh` after build
2. Add cleanup script for periodic maintenance
3. Document cleanup commands

