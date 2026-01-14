#!/bin/bash
# Complete local environment destruction - leaves blank slate for fresh setup
# Usage: ./teardown-resources.sh [--force] [--skip-confirmation] [--dry-run] [--reset-db] [--keep-db] [--clean-volumes] [--clean-images] [--clean-cache]
#
# This script:
# 1. Stops Docker services and frontend dev server (to release resources)
# 2. Removes Delta tables (local filesystem)
# 3. Optionally resets database (or keeps it)
# 4. Cleans up Docker resources (containers, volumes, images, cache)
#
# WARNING: This will DESTROY ALL local resources!

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"

DRY_RUN="false"
FORCE_DELETE="false"
SKIP_CONFIRMATION="false"
RESET_DB="false"
KEEP_DB="false"
CLEAN_VOLUMES="false"
CLEAN_IMAGES="false"
CLEAN_CACHE="false"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE_DELETE="true"
            SKIP_CONFIRMATION="true"
            shift
            ;;
        --skip-confirmation)
            SKIP_CONFIRMATION="true"
            shift
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --reset-db)
            RESET_DB="true"
            shift
            ;;
        --keep-db)
            KEEP_DB="true"
            shift
            ;;
        --clean-volumes)
            CLEAN_VOLUMES="true"
            shift
            ;;
        --clean-images)
            CLEAN_IMAGES="true"
            shift
            ;;
        --clean-cache)
            CLEAN_CACHE="true"
            shift
            ;;
        --clean-all)
            # Full cleanup: reset DB, remove volumes, images, and build cache
            RESET_DB="true"
            CLEAN_VOLUMES="true"
            CLEAN_IMAGES="true"
            CLEAN_CACHE="true"
            shift
            ;;
        --help|-h)
            cat << EOF
Usage: $0 [--force] [--skip-confirmation] [--dry-run] [--reset-db] [--keep-db] [--clean-volumes] [--clean-images] [--clean-cache] [--clean-all]

Complete local environment destruction - leaves blank slate for fresh setup.

WARNING: This will DESTROY ALL local resources!

Options:
  --dry-run             Show what would be destroyed without actually destroying (default: false)
  --force               Skip confirmation prompts and actually destroy (default: requires confirmation)
  --skip-confirmation   Alias for --force
  --reset-db            Fully reset database (drop all data) - default: keep database
  --keep-db             Preserve database (default behavior)
  --clean-volumes       Remove Docker volumes (default: keep unless --reset-db)
  --clean-images        Remove unused Docker images (default: keep)
  --clean-cache         Remove Docker build cache (default: keep)
  --clean-all           Remove database data, Docker volumes, images, and build cache (equivalent to --reset-db --clean-volumes --clean-images --clean-cache)
  --help                Show this help message

Examples:
  $0 --dry-run                              # Preview what would be destroyed
  $0                                        # Destroy with confirmation prompt
  $0 --force                                # Destroy without confirmation
  $0 --force --reset-db                     # Destroy including database reset
  $0 --force --reset-db --clean-volumes     # Destroy with database and volumes

Note: By default, this script requires confirmation before destroying.
      Use --force to skip confirmation prompts.
      Database is preserved by default (use --reset-db to reset it).

EOF
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            log_info "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate conflicting options
if [ "$RESET_DB" = "true" ] && [ "$KEEP_DB" = "true" ]; then
    log_error "Cannot use both --reset-db and --keep-db"
    exit 1
fi

# If --reset-db is set, also clean volumes (database data is in volumes)
if [ "$RESET_DB" = "true" ]; then
    CLEAN_VOLUMES="true"
    log_info "Database reset requested - volumes will also be cleaned"
fi

log_step "Local Environment Destruction"
log_warning "════════════════════════════════════════════════════════════════"
log_warning "WARNING: This will DESTROY ALL local resources"
log_warning "════════════════════════════════════════════════════════════════"
if [ "$DRY_RUN" = "true" ]; then
    log_info "Mode: DRY-RUN (no resources will be destroyed)"
else
    log_warning "Mode: DESTRUCTION (resources will be permanently destroyed!)"
fi
log_info "Database: $([ "$RESET_DB" = "true" ] && echo "Will be reset" || echo "Will be preserved")"
log_info "Volumes: $([ "$CLEAN_VOLUMES" = "true" ] && echo "Will be removed" || echo "Will be preserved")"
log_info "Images: $([ "$CLEAN_IMAGES" = "true" ] && echo "Will be removed" || echo "Will be preserved")"
log_info "Cache: $([ "$CLEAN_CACHE" = "true" ] && echo "Will be removed" || echo "Will be preserved")"
echo ""

# Confirmation (unless --force or --dry-run)
if [ "$DRY_RUN" = "false" ] && [ "$SKIP_CONFIRMATION" = "false" ]; then
    log_warning "This action cannot be undone!"
    log_warning "All local resources will be destroyed."
    if [ "$RESET_DB" = "true" ]; then
        log_warning "⚠️  Database will be reset (all data will be lost)"
    fi
    if [ "$CLEAN_VOLUMES" = "true" ]; then
        log_warning "⚠️  Docker volumes will be removed (database data will be lost)"
    fi
    echo ""
    read -p "Type 'yes' to confirm destruction: " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Destruction cancelled by user"
        exit 0
    fi
    echo ""
fi

# ============================================================================
# Step 1: Stop Services
# ============================================================================
stop_services() {
    log_step "Substep 1: Stopping Services"
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would stop Docker Compose services"
        log_info "[DRY-RUN] Would kill frontend dev server (if running on port 5173)"
    else
        # Stop Docker Compose services
        DOCKER_DIR="$REPO_ROOT/infra/docker"
        if [ -d "$DOCKER_DIR" ]; then
            log_info "Stopping Docker Compose services..."
            cd "$DOCKER_DIR"
            if docker compose down 2>/dev/null; then
                log_success "  ✓ Docker services stopped"
            else
                log_warning "    Some services may have already been stopped"
            fi
        else
            log_info "Docker directory not found (may already be cleaned)"
        fi
        
        # Kill frontend dev server (if running)
        FRONTEND_PID=$(lsof -Pi :5173 -sTCP:LISTEN -t 2>/dev/null || echo "")
        if [ -n "$FRONTEND_PID" ]; then
            log_info "Stopping frontend dev server (PID: $FRONTEND_PID)..."
            kill "$FRONTEND_PID" 2>/dev/null || true
            sleep 2
            # Force kill if still running
            if kill -0 "$FRONTEND_PID" 2>/dev/null; then
                log_warning "    Process still running, force killing..."
                kill -9 "$FRONTEND_PID" 2>/dev/null || true
                sleep 1
            fi
            log_success "  ✓ Frontend dev server stopped"
        else
            log_info "Frontend dev server not running"
        fi
    fi
    
    echo ""
}

# ============================================================================
# Step 2: Remove Delta Tables
# ============================================================================
remove_delta_tables() {
    log_step "Substep 2: Removing Delta Tables"
    
    local teardown_cmd="$REPO_ROOT/run_scripts/spark_delta-lake_scripts/common/delta-lake/teardown-delta.sh --local"
    if [ "$DRY_RUN" = "true" ]; then
        teardown_cmd="$teardown_cmd --dry-run"
    else
        teardown_cmd="$teardown_cmd --force"
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would run: $teardown_cmd"
    else
        log_info "Removing Delta tables from local filesystem..."
        if $teardown_cmd; then
            log_success "  ✓ Delta tables removed"
        else
            log_warning "    Delta table removal had issues (may have been partially cleaned)"
        fi
    fi
    
    echo ""
}

# ============================================================================
# Step 3: Reset Database (Optional)
# ============================================================================
reset_database() {
    log_step "Substep 3: Resetting Database"
    
    if [ "$RESET_DB" != "true" ]; then
        log_info "Database reset skipped (use --reset-db to reset)"
        echo ""
        return 0
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would reset database (drop all tables and data)"
        log_info "[DRY-RUN] Would remove database volume/data directory"
    else
        log_warning "⚠️  Resetting database (all data will be lost)"
        
        # Option 1: Remove database data directory (bind mount)
        DOCKER_DIR="$REPO_ROOT/infra/docker"
        DB_DATA_DIR="$DOCKER_DIR/pgdata"
        
        if [ -d "$DB_DATA_DIR" ]; then
            log_info "Removing database data directory: $DB_DATA_DIR"
            if rm -rf "$DB_DATA_DIR"; then
                log_success "  ✓ Database data directory removed"
            else
                log_warning "    Failed to remove database data directory (may require manual cleanup)"
            fi
        else
            log_info "Database data directory not found (may already be cleaned)"
        fi
        
        # Option 2: Also try to drop tables if container is still accessible
        # (This is a fallback if volume removal didn't work)
        if docker ps --filter "name=fru_db" --format "{{.Names}}" | grep -q "fru_db"; then
            log_info "Database container still running, attempting to drop tables..."
            load_env_file || true
            if docker exec fru_db psql -U "${PGUSER:-postgres}" -d "${PGDATABASE:-fru_db}" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" 2>/dev/null; then
                log_success "  ✓ Database tables dropped"
            else
                log_warning "    Failed to drop tables (container may be stopping)"
            fi
        fi
    fi
    
    echo ""
}

# ============================================================================
# Verification Helper Functions
# ============================================================================
verify_containers_removed() {
    # Check if there are any stopped containers remaining
    local stopped_count=$(docker ps -a --filter "status=exited" --format "{{.ID}}" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$stopped_count" -gt 0 ]; then
        log_error "  ✗ Verification failed: $stopped_count stopped container(s) still exist"
        return 1
    fi
    return 0
}

verify_volumes_removed() {
    # Check if there are any volumes remaining
    # After docker volume prune, all unused volumes should be removed
    # Since services are stopped, there should be no volumes in use
    local volume_count=$(docker volume ls -q 2>/dev/null | wc -l | tr -d ' ')
    if [ "$volume_count" -gt 0 ]; then
        log_error "  ✗ Verification failed: $volume_count volume(s) still exist"
        log_info "    Remaining volumes:"
        docker volume ls --format "    - {{.Name}}" 2>/dev/null | head -5
        [ "$volume_count" -gt 5 ] && log_info "    ... and $((volume_count - 5)) more"
        return 1
    fi
    return 0
}

verify_images_removed() {
    # Check if there are any images remaining (excluding base images that might be in use)
    # For --clean-all, we expect all images to be removed
    local image_count=$(docker images --format "{{.ID}}" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$image_count" -gt 0 ]; then
        log_error "  ✗ Verification failed: $image_count image(s) still exist"
        log_info "    Remaining images:"
        docker images --format "    - {{.Repository}}:{{.Tag}} ({{.Size}})" 2>/dev/null | head -5
        [ "$image_count" -gt 5 ] && log_info "    ... and $((image_count - 5)) more"
        return 1
    fi
    return 0
}

verify_cache_removed() {
    # Check build cache size (should be minimal after prune)
    local cache_size=$(docker system df --format "{{.Type}}\t{{.Size}}" 2>/dev/null | grep "Build Cache" | awk '{print $2}' || echo "0B")
    # If cache size is significant (>1MB), verification failed
    # Note: Some minimal cache may remain, so we check for reasonable threshold
    log_info "  Build cache size after cleanup: $cache_size"
    # For now, we just log the size - Docker's cache can have some overhead
    return 0
}

# ============================================================================
# Step 4: Clean Up Docker Resources
# ============================================================================
cleanup_docker_resources() {
    log_step "Substep 4: Cleaning Up Docker Resources"
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would clean up Docker resources:"
        [ "$CLEAN_VOLUMES" = "true" ] && log_info "[DRY-RUN]   - Remove unused volumes"
        [ "$CLEAN_IMAGES" = "true" ] && log_info "[DRY-RUN]   - Remove unused images"
        [ "$CLEAN_CACHE" = "true" ] && log_info "[DRY-RUN]   - Remove build cache"
        [ "$CLEAN_VOLUMES" != "true" ] && [ "$CLEAN_IMAGES" != "true" ] && [ "$CLEAN_CACHE" != "true" ] && log_info "[DRY-RUN]   - No cleanup requested (all resources preserved)"
    else
        # Ensure Docker is running
        if ! docker info >/dev/null 2>&1; then
            log_warning "Docker daemon is not running (skipping Docker cleanup)"
            echo ""
            return 0
        fi
        
        # Remove stopped containers (always do this)
        log_info "Removing stopped containers..."
        if docker container prune -f >/dev/null 2>&1; then
            sleep 1  # Brief wait for Docker to process
            if verify_containers_removed; then
                log_success "  ✓ Stopped containers removed and verified"
            else
                log_error "  ✗ Failed to verify container removal"
                return 1
            fi
        else
            log_error "  ✗ Failed to remove stopped containers"
            return 1
        fi
        
        # Remove volumes (if requested)
        if [ "$CLEAN_VOLUMES" = "true" ]; then
            log_warning "Removing unused volumes (this will delete database data if volumes are not in use)..."
            if docker volume prune -f >/dev/null 2>&1; then
                sleep 2  # Volumes may take a moment to fully delete
                if verify_volumes_removed; then
                    log_success "  ✓ Unused volumes removed and verified"
                else
                    log_error "  ✗ Failed to verify volume removal"
                    return 1
                fi
            else
                log_error "  ✗ Failed to remove unused volumes"
                return 1
            fi
        else
            log_info "Volumes preserved (use --clean-volumes to remove)"
        fi
        
        # Remove images (if requested)
        if [ "$CLEAN_IMAGES" = "true" ]; then
            log_info "Removing unused images (this may take a moment)..."
            if docker image prune -a -f >/dev/null 2>&1; then
                sleep 3  # Images can take time to delete, especially large ones
                if verify_images_removed; then
                    log_success "  ✓ Unused images removed and verified"
                else
                    log_error "  ✗ Failed to verify image removal"
                    return 1
                fi
            else
                log_error "  ✗ Failed to remove unused images"
                return 1
            fi
        else
            log_info "Images preserved (use --clean-images to remove)"
        fi
        
        # Remove build cache (if requested)
        if [ "$CLEAN_CACHE" = "true" ]; then
            log_info "Removing build cache..."
            if docker builder prune -f >/dev/null 2>&1; then
                sleep 1  # Brief wait for cache cleanup
                verify_cache_removed  # Log cache size (non-fatal)
                log_success "  ✓ Build cache removed"
            else
                log_error "  ✗ Failed to remove build cache"
                return 1
            fi
        else
            log_info "Build cache preserved (use --clean-cache to remove)"
        fi
    fi
    
    echo ""
}

# ============================================================================
# Main Execution
# ============================================================================
main() {
    # Fail-fast: exit immediately on any failure
    # (Confirmation and warnings are handled at script level before main() is called)
    
    # Step 1: Stop services (fail-fast)
    if ! stop_services; then
        log_error "Failed to stop services - aborting"
        exit 1
    fi
    
    # Step 2: Remove Delta tables (fail-fast)
    if ! remove_delta_tables; then
        log_error "Failed to remove Delta tables - aborting"
        exit 1
    fi
    
    # Step 3: Reset database (fail-fast)
    if ! reset_database; then
        log_error "Failed to reset database - aborting"
        exit 1
    fi
    
    # Step 4: Clean up Docker resources (fail-fast)
    if ! cleanup_docker_resources; then
        log_error "Failed to clean up Docker resources - aborting"
        exit 1
    fi
    
    echo ""
    log_step "Destruction Summary"
    log_info "════════════════════════════════════════════════════════════════"
    
    if [ "$DRY_RUN" = "true" ]; then
        log_warning "DRY-RUN MODE - No resources were actually destroyed"
        log_info ""
        log_info "Review the output above to see what would be destroyed"
        log_info ""
        log_info "To actually destroy local resources, run:"
        log_info "  $0 --force"
    else
        log_success "Local environment destruction completed!"
        log_info ""
        log_info "All local resources have been destroyed and verified"
        log_info "You can now run a fresh setup with: ./run_scripts/main_application_scripts/local/run.sh"
    fi
    log_info "════════════════════════════════════════════════════════════════"
}

main "$@"

