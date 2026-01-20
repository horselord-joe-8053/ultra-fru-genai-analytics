# Docker Cleanup Script Refactor Plan: Project-Specific Cleanup

## Overview

Enhance the cleanup script to support project-specific resource cleanup, filtering Docker resources by project identifiers instead of cleaning all system-wide resources.

## Current Behavior

- `--all`: Removes ALL unused Docker resources system-wide (`docker system prune -a -f --volumes`)
- Individual flags (`--images`, `--containers`, `--volumes`, `--cache`): Clean system-wide resources
- No project-specific filtering

## Project Resource Identifiers

Based on codebase analysis:

1. **Project Name**: `fru` (consistent across codebase)
2. **Container Names**:
   - `fru_db` (PostgreSQL database)
   - `fru_api` (API service)
   - Pattern: `fru_*`
3. **Image Patterns**:
   - Local: `fru-api:*` (e.g., `fru-api:fru-dev-20260118-abc123-dirty`)
   - ECR: `*.dkr.ecr.*.amazonaws.com/fru-api:*`
   - Tag pattern: `fru-<env>-<date>-<sha>-*`
4. **Docker Compose Project**:
   - Default: Directory name (`fru-genai-analytics-all`)
   - Can be set via `COMPOSE_PROJECT_NAME` env var
   - Creates networks: `<project>_default`
   - Creates volumes: `<project>_<volume_name>` or bind mounts from `./pgdata`
5. **Volumes**:
   - Bind mount: `./pgdata` (local path)
   - Named volumes: Created by docker-compose with project prefix

## Proposed Changes

### 1. Add `--project-only` Flag

**New behavior:**
- `--project-only`: Clean only project-specific resources (default when using individual flags)
- `--all`: System-wide cleanup (backward compatible, existing behavior)
- `--all --project-only`: Project-specific cleanup of all resource types

**Resource filtering logic:**

#### Containers
```bash
# Filter containers by name pattern
docker ps -a --filter "name=fru_" --format "{{.ID}}"
```

#### Images
```bash
# Filter images by repository pattern
docker images --filter "reference=fru-api:*" --format "{{.ID}}"
docker images --filter "reference=*.dkr.ecr.*.amazonaws.com/fru-api:*" --format "{{.ID}}"
```

#### Volumes
```bash
# Filter volumes associated with project containers
# Get volumes from project containers, then filter unused ones
docker volume ls --filter "label=com.docker.compose.project=fru-genai-analytics-all"
# Or filter by name pattern if volumes are named
docker volume ls --filter "name=fru"
```

#### Networks
```bash
# Filter networks by Docker Compose project
docker network ls --filter "label=com.docker.compose.project=fru-genai-analytics-all"
# Or filter by name pattern
docker network ls --filter "name=fru"
```

### 2. Implementation Strategy

#### Option A: Filter-First Approach (Recommended)
- Use Docker filters to identify project resources
- Only remove resources that match project patterns
- More precise, safer

#### Option B: List-Then-Filter Approach
- List all resources
- Filter by patterns in script
- More control, but slower for large systems

**Recommendation: Option A** - Use Docker's native filtering for better performance and safety.

### 3. New Function Structure

```bash
# Project identification
get_project_name() {
    # Try COMPOSE_PROJECT_NAME, fallback to directory name
    echo "${COMPOSE_PROJECT_NAME:-fru-genai-analytics-all}"
}

# Resource filtering functions
get_project_containers() {
    # Return container IDs matching fru_* pattern
}

get_project_images() {
    # Return image IDs matching fru-api:* or ECR patterns
}

get_project_volumes() {
    # Return volume names associated with project containers/networks
}

get_project_networks() {
    # Return network IDs for project Docker Compose networks
}

# Cleanup functions
clean_project_containers() {
    # Remove stopped containers matching project pattern
}

clean_project_images() {
    # Remove unused images matching project patterns
}

clean_project_volumes() {
    # Remove unused volumes associated with project
}

clean_project_networks() {
    # Remove unused networks for project
}
```

### 4. Command-Line Interface

```bash
# Project-specific cleanup (new default for individual flags)
./cleanup-docker.sh --project-only --images
./cleanup-docker.sh --project-only --containers
./cleanup-docker.sh --project-only --volumes
./cleanup-docker.sh --project-only --cache

# Project-specific cleanup of all types
./cleanup-docker.sh --project-only --all

# System-wide cleanup (backward compatible)
./cleanup-docker.sh --all  # Still works as before

# Mixed: project images + system-wide containers
./cleanup-docker.sh --project-only --images --containers
```

### 5. Safety Considerations

1. **Dry-run mode**: Add `--dry-run` to preview what would be removed
2. **Confirmation prompts**: For project-specific cleanup, show what will be removed
3. **Active resource protection**: Never remove resources in use (Docker handles this)
4. **Volume safety**: Extra warnings for volumes (may contain database data)

### 6. Implementation Details

#### Container Filtering
```bash
# Get all project containers (running + stopped)
PROJECT_CONTAINERS=$(docker ps -a --filter "name=^fru_" --format "{{.ID}}")

# Get only stopped project containers
STOPPED_PROJECT_CONTAINERS=$(docker ps -a --filter "name=^fru_" --filter "status=exited" --format "{{.ID}}")
```

#### Image Filtering
```bash
# Get project images (local)
PROJECT_IMAGES=$(docker images --filter "reference=fru-api:*" --format "{{.ID}}")

# Get project images (ECR)
ECR_IMAGES=$(docker images --filter "reference=*.dkr.ecr.*.amazonaws.com/fru-api:*" --format "{{.ID}}")

# Combine and deduplicate
ALL_PROJECT_IMAGES=$(echo -e "$PROJECT_IMAGES\n$ECR_IMAGES" | sort -u)
```

#### Volume Filtering
```bash
# Method 1: Filter by Docker Compose labels
PROJECT_VOLUMES=$(docker volume ls --filter "label=com.docker.compose.project=$(get_project_name)" --format "{{.Name}}")

# Method 2: Get volumes from project containers
CONTAINER_VOLUMES=$(docker inspect $(get_project_containers) --format '{{range .Mounts}}{{if .Name}}{{.Name}}{{end}}{{end}}' | sort -u)

# Method 3: Filter by name pattern (if volumes are named)
NAMED_VOLUMES=$(docker volume ls --filter "name=fru" --format "{{.Name}}")
```

#### Network Filtering
```bash
# Filter by Docker Compose project label
PROJECT_NETWORKS=$(docker network ls --filter "label=com.docker.compose.project=$(get_project_name)" --format "{{.ID}}")

# Filter by name pattern
NAMED_NETWORKS=$(docker network ls --filter "name=fru" --format "{{.ID}}")
```

### 7. Backward Compatibility

- `--all` without `--project-only`: System-wide cleanup (existing behavior)
- Individual flags without `--project-only`: Default to project-specific (new behavior)
- Add `--system-wide` flag for explicit system-wide cleanup when using individual flags

### 8. Enhanced Output

Show what will be cleaned:
```bash
[INFO] Project-specific cleanup mode enabled
[INFO] Found 5 project containers (2 stopped)
[INFO] Found 12 project images (8 unused)
[INFO] Found 2 project volumes (1 unused)
[INFO] Found 1 project network
[INFO] 
[INFO] Will remove:
[INFO]   - 2 stopped containers: fru_db, fru_api_old
[INFO]   - 8 unused images: fru-api:fru-dev-20260118-abc123, ...
[INFO]   - 1 unused volume: fru-genai-analytics-all_pgdata
```

## Implementation Checklist

- [ ] Add `--project-only` flag parsing
- [ ] Add `--system-wide` flag for explicit system-wide cleanup
- [ ] Implement `get_project_name()` function
- [ ] Implement project resource filtering functions
- [ ] Implement project-specific cleanup functions
- [ ] Update `--all` logic to respect `--project-only`
- [ ] Update individual flag logic to default to project-specific
- [ ] Add dry-run mode (`--dry-run`)
- [ ] Add resource preview before cleanup
- [ ] Update help text and usage examples
- [ ] Test with actual project resources
- [ ] Test backward compatibility with `--all`
- [ ] Document new behavior in script header

## Testing Scenarios

1. **Project-only cleanup**: Should only remove `fru_*` containers and `fru-api:*` images
2. **System-wide cleanup**: Should remove all unused resources (existing behavior)
3. **Mixed cleanup**: Project images + system-wide containers
4. **Dry-run**: Should show what would be removed without actually removing
5. **Active resources**: Should not remove running containers or images in use
6. **Volume safety**: Should warn about database volumes

## Benefits

1. **Safety**: Only removes project resources, preserving other Docker resources
2. **Precision**: Targeted cleanup reduces risk of accidental deletion
3. **Flexibility**: Can still do system-wide cleanup when needed
4. **Backward compatible**: Existing workflows continue to work
5. **Better UX**: Clear preview of what will be removed

