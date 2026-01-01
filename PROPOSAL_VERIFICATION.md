# Proposal Verification: Simplified Local Test Environment Setup

## Your Proposal

### 1. `--test-env local` (Implicit Service Management)

**Behavior:**
- **1.1** If services are up → Just run tests (no Docker overhead)
- **1.2** If services are down:
  - **1.2.1** If all images exist → Start services (no build)
  - **1.2.2** If any image missing → Build missing images, then start services

### 2. `--force-rebuild-local-img` (Force Rebuild)

**Behavior:**
- Always rebuild all images using docker-compose
- Then start/bring up all services

## Verification

### ✅ Proposal is Correct and Complete

**Advantages:**
1. **Simpler UX**: No need for `--ensure-services` flag (it's implicit for local)
2. **Efficient**: Only builds what's needed
3. **Intuitive**: "Local testing needs services" is obvious
4. **Terraform-like**: Check state, do minimal work

### Implementation Details

#### Service Detection
- Check if `fru_db` and `fru_api` containers are running
- Use: `docker ps --format '{{.Names}}' | grep -E '^fru_db$|^fru_api$'`

#### Image Detection
- **db service**: Uses `image: ankane/pgvector:latest` (pulled from Docker Hub)
  - Check: `docker image inspect ankane/pgvector:latest >/dev/null 2>&1`
- **api service**: Uses `build:` (built locally)
  - Check: `docker compose images api` or check if image exists by name
  - Image name format: `<project>_<service>` (e.g., `fru-genai-analytics-all_api` or `docker_api`)
  - Better: Use `docker compose config --images` to get exact image names

#### Build Strategy
- Use `docker compose build <service>` to build specific service
- Use `docker compose build` to build all services that need building
- Use `docker compose up -d` to start services (will pull/build as needed, but we want explicit control)

### Edge Cases Considered

1. **Dockerfile changed but image exists**: 
   - Current proposal: Won't rebuild (image exists)
   - **Question**: Should we detect Dockerfile changes? (Probably not - use `--force-rebuild-local-img` for that)

2. **Partial service failure**: 
   - If one service is running but other isn't → Treated as "services down"
   - Will check images and start missing service
   - ✅ Handled correctly

3. **Image exists but outdated**:
   - Current proposal: Won't rebuild (image exists)
   - **Question**: Should we check image age or Dockerfile hash? (Probably not - use `--force-rebuild-local-img` for that)

4. **Docker daemon not running**:
   - Should fail gracefully with clear error message
   - ✅ Should be handled

### Missing Considerations

1. **Health checks after starting**: 
   - Should wait for services to be healthy before proceeding
   - ✅ Already handled in current code

2. **Cleanup of dangling images**:
   - After building, should clean up old images
   - ✅ Already implemented in `start-services.sh`

3. **Error handling**:
   - What if build fails?
   - What if service start fails?
   - ✅ Should fail fast with clear errors

## Recommended Implementation

### Function: `ensure_local_services()`

```bash
ensure_local_services() {
    local force_rebuild="${FORCE_REBUILD_LOCAL_IMG:-false}"
    
    # Check if services are running
    if services_are_running; then
        echo "INFO: Services already running"
        return 0
    fi
    
    # Services are down - need to start them
    if [[ "$force_rebuild" == "true" ]]; then
        # Force rebuild all images
        docker compose build
        docker compose up -d
    else
        # Check if images exist
        if all_images_exist; then
            # Images exist - just start
            docker compose up -d
        else
            # Build missing images, then start
            docker compose build
            docker compose up -d
        fi
    fi
    
    # Wait for health checks
    wait_for_services_healthy
}
```

### Image Existence Check

```bash
all_images_exist() {
    # Check db image (pulled)
    if ! docker image inspect ankane/pgvector:latest >/dev/null 2>&1; then
        return 1  # Missing
    fi
    
    # Check api image (built)
    # Get project name from docker-compose
    local project_name=$(docker compose config --project-name 2>/dev/null || echo "docker")
    local api_image="${project_name}_api"
    
    if ! docker image inspect "$api_image" >/dev/null 2>&1; then
        return 1  # Missing
    fi
    
    return 0  # All exist
}
```

## Conclusion

✅ **Your proposal is correct and complete!**

The simplified approach is:
- More intuitive
- More efficient
- Easier to maintain
- Better UX

**Implementation steps:**
1. Remove `--ensure-services` flag (make it implicit for local)
2. Rename `--rebuild-api` to `--force-rebuild-local-img`
3. Implement image existence checking
4. Update `setup_local_environment()` to use new logic
5. Update documentation

