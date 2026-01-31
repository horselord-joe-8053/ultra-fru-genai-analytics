#!/bin/bash
# Cleanup Docker images, containers, and volumes
# Usage: ./cleanup-docker.sh [--all] [--images] [--containers] [--volumes] [--cache]
#
# This script helps clean up Docker resources for local development:
# - Stopped containers
# - Dangling images
# - Unused volumes
# - Build cache
#
# Safety: By default, shows current usage and prompts for confirmation
#         Use --all to clean everything (with confirmation prompt)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
source "$REPO_ROOT/orchestration/common/logger.sh"

log_info "[DEBUG] Starting Docker cleanup script"
log_info "[DEBUG] Script directory: $SCRIPT_DIR"
log_info "[DEBUG] Repo root: $REPO_ROOT"

CLEAN_ALL=false
CLEAN_IMAGES=false
CLEAN_CONTAINERS=false
CLEAN_VOLUMES=false
CLEAN_CACHE=false

log_info "[DEBUG] Parsing command-line arguments..."
while [[ $# -gt 0 ]]; do
    log_info "[DEBUG] Processing argument: $1"
    case "$1" in
        --all)
            CLEAN_ALL=true
            log_info "[DEBUG] Set CLEAN_ALL=true"
            shift
            ;;
        --images)
            CLEAN_IMAGES=true
            log_info "[DEBUG] Set CLEAN_IMAGES=true"
            shift
            ;;
        --containers)
            CLEAN_CONTAINERS=true
            log_info "[DEBUG] Set CLEAN_CONTAINERS=true"
            shift
            ;;
        --volumes)
            CLEAN_VOLUMES=true
            log_info "[DEBUG] Set CLEAN_VOLUMES=true"
            shift
            ;;
        --cache)
            CLEAN_CACHE=true
            log_info "[DEBUG] Set CLEAN_CACHE=true"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--all] [--images] [--containers] [--volumes] [--cache]"
            exit 1
            ;;
    esac
done
log_info "[DEBUG] Argument parsing complete"
log_info "[DEBUG] CLEAN_ALL=$CLEAN_ALL, CLEAN_IMAGES=$CLEAN_IMAGES, CLEAN_CONTAINERS=$CLEAN_CONTAINERS, CLEAN_VOLUMES=$CLEAN_VOLUMES, CLEAN_CACHE=$CLEAN_CACHE"

# If no specific option, show current usage and prompt
if [ "$CLEAN_ALL" = false ] && [ "$CLEAN_IMAGES" = false ] && [ "$CLEAN_CONTAINERS" = false ] && [ "$CLEAN_VOLUMES" = false ] && [ "$CLEAN_CACHE" = false ]; then
    log_info "[DEBUG] No cleanup options specified, showing usage"
    log_info "Current Docker disk usage:"
    docker system df
    echo ""
    log_info "Usage: $0 [--all] [--images] [--containers] [--volumes] [--cache]"
    log_info "  --all       : Clean everything (images, containers, volumes, cache)"
    log_info "  --images    : Remove dangling images"
    log_info "  --containers: Remove stopped containers"
    log_info "  --volumes   : Remove unused volumes"
    log_info "  --cache     : Remove build cache"
    exit 0
fi

# Ensure Docker is running
log_info "[DEBUG] Checking if Docker daemon is running..."
log_info "[DEBUG] Running: docker info (with timeout to prevent hanging)"

# Ensure command_exists is available
if ! type command_exists >/dev/null 2>&1; then
    command_exists() {
        command -v "$1" >/dev/null 2>&1
    }
fi

# Use timeout to prevent hanging if Docker daemon is not responsive
docker_check_timeout=10
docker_daemon_ok=false

if command_exists timeout; then
    log_info "[DEBUG] Using 'timeout' command (timeout: ${docker_check_timeout}s)"
    if timeout "$docker_check_timeout" docker info >/dev/null 2>&1; then
        docker_daemon_ok=true
        log_info "[DEBUG] Docker daemon check passed (via timeout command)"
    else
        log_info "[DEBUG] Docker daemon check failed or timed out (via timeout command)"
    fi
elif command_exists gtimeout; then
    log_info "[DEBUG] Using 'gtimeout' command (macOS coreutils, timeout: ${docker_check_timeout}s)"
    if gtimeout "$docker_check_timeout" docker info >/dev/null 2>&1; then
        docker_daemon_ok=true
        log_info "[DEBUG] Docker daemon check passed (via gtimeout command)"
    else
        log_info "[DEBUG] Docker daemon check failed or timed out (via gtimeout command)"
    fi
else
    log_info "[DEBUG] No timeout command available, using fallback method"
    log_info "[DEBUG] Running docker info in background with manual timeout..."
    docker info >/dev/null 2>&1 &
    docker_pid=$!
    log_info "[DEBUG] Docker info process PID: $docker_pid"
    sleep "$docker_check_timeout"
    if kill -0 "$docker_pid" 2>/dev/null; then
        log_info "[DEBUG] Docker info still running after timeout, killing process..."
        kill "$docker_pid" 2>/dev/null || true
        wait "$docker_pid" 2>/dev/null || true
        log_info "[DEBUG] Docker daemon check timed out (fallback method)"
    else
        if wait "$docker_pid" 2>/dev/null; then
            docker_daemon_ok=true
            log_info "[DEBUG] Docker daemon check passed (fallback method)"
        else
            log_info "[DEBUG] Docker daemon check failed (fallback method)"
        fi
    fi
fi

# If Docker is already running, skip all start/kill logic and proceed directly to cleanup
if [ "$docker_daemon_ok" = "true" ]; then
    log_success "Docker daemon is already running and responsive"
    log_info "[DEBUG] Skipping Docker start/kill logic - proceeding directly to cleanup"
else
    log_warning "Docker daemon is not running or not responsive"
    
    # Check if there are zombie Docker processes that might be blocking
    if [[ "$OSTYPE" == "darwin"* ]]; then
        docker_backend_count=$(pgrep -f "com.docker.backend" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$docker_backend_count" -gt 0 ]; then
            log_warning "Found $docker_backend_count Docker backend process(es) but daemon is not responding"
            log_info "This indicates Docker Desktop needs to be restarted"
            log_info "[DEBUG] Automatically killing existing Docker processes..."
            killall Docker 2>/dev/null || true
            killall "Docker Desktop" 2>/dev/null || true
            pkill -f "com.docker.backend" 2>/dev/null || true
            pkill -f "com.docker.virtualization" 2>/dev/null || true
            sleep 3
            log_info "[DEBUG] Docker processes killed, will now start Docker Desktop..."
        fi
    fi
    
    # Try to start Docker Desktop on macOS (already checked processes above)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        log_info "[DEBUG] Starting Docker Desktop..."
        
        # Try to start Docker Desktop using direct executable (most reliable)
        docker_app_path="/Applications/Docker.app"
        docker_desktop_executable="/Applications/Docker.app/Contents/MacOS/Docker Desktop.app/Contents/MacOS/Docker Desktop"
        
        docker_started=false
        
        # Method 1: Try direct executable (most reliable, doesn't hang)
        if [ -f "$docker_desktop_executable" ]; then
            log_info "[DEBUG] Found Docker Desktop executable, launching directly in background..."
            log_info "[DEBUG] Running: '$docker_desktop_executable' &"
            # Launch in background - this won't hang
            "$docker_desktop_executable" >/dev/null 2>&1 &
            docker_started=true
            log_info "[DEBUG] Docker Desktop executable launched (PID: $!)"
        # Method 2: Fallback to open command (but in background to prevent hanging)
        elif [ -d "$docker_app_path" ]; then
            log_info "[DEBUG] Found Docker.app, trying open command in background..."
            log_info "[DEBUG] Running: open -a Docker &"
            # Launch in background to prevent hanging
            open -a Docker >/dev/null 2>&1 &
            docker_started=true
            log_info "[DEBUG] Docker Desktop open command executed (PID: $!)"
        else
            log_error "[DEBUG] Docker.app not found at $docker_app_path"
            log_error "Please install Docker Desktop from https://www.docker.com/products/docker-desktop"
            exit 1
        fi
        
        if [ "$docker_started" = "true" ]; then
            log_info "[DEBUG] Waiting 5 seconds for Docker Desktop to initialize..."
            sleep 5  # Give Docker Desktop time to start initializing
        fi
        
        log_info "[DEBUG] Docker Desktop start command executed, waiting for it to start..."
        log_info "Waiting for Docker daemon to start (this may take 30-60 seconds)..."
        
        # Wait for Docker to start (max 90 seconds - Docker Desktop can take longer)
        max_wait=90
        wait_interval=3
        waited=0
        
        # Check if Docker Desktop.app is actually running (not just backend processes)
        log_info "[DEBUG] Checking if Docker Desktop.app is running..."
        docker_desktop_running=false
        if pgrep -f "Docker.app/Contents/MacOS/Docker" >/dev/null 2>&1; then
            docker_desktop_running=true
            log_info "[DEBUG] Docker Desktop.app main process is running"
        elif pgrep -f "com.docker.backend" >/dev/null 2>&1; then
            log_info "[DEBUG] Docker backend processes found but main app may not be running"
            log_info "[DEBUG] This might indicate Docker Desktop needs to be restarted"
        else
            log_info "[DEBUG] Docker Desktop process not yet detected, will keep checking..."
        fi
            
            while [ $waited -lt $max_wait ]; do
                log_info "[DEBUG] Checking Docker daemon status (waited ${waited}s/${max_wait}s)..."
                
                # Check if Docker socket exists (faster check)
                if [ -S /var/run/docker.sock ] 2>/dev/null || [ -S ~/.docker/run/docker.sock ] 2>/dev/null; then
                    log_info "[DEBUG] Docker socket found, testing connection..."
                else
                    log_info "[DEBUG] Docker socket not found yet, waiting..."
                    sleep $wait_interval
                    waited=$((waited + wait_interval))
                    continue
                fi
                
                # Try docker info with explicit timeout using background process
                log_info "[DEBUG] Testing docker info connection..."
                (docker info >/dev/null 2>&1) &
                docker_check_pid=$!
                
                # Wait up to 5 seconds for docker info to complete
                check_timeout=5
                check_waited=0
                docker_check_success=false
                
                while [ $check_waited -lt $check_timeout ]; do
                    if ! kill -0 "$docker_check_pid" 2>/dev/null; then
                        # Process finished, check exit code
                        if wait "$docker_check_pid" 2>/dev/null; then
                            docker_check_success=true
                            log_info "[DEBUG] docker info succeeded!"
                        else
                            log_info "[DEBUG] docker info failed (exit code: $?)"
                        fi
                        break
                    fi
                    sleep 0.5
                    check_waited=$((check_waited + 1))
                done
                
                # If still running, kill it
                if kill -0 "$docker_check_pid" 2>/dev/null; then
                    log_info "[DEBUG] docker info timed out after ${check_timeout}s, killing process..."
                    kill "$docker_check_pid" 2>/dev/null || true
                    wait "$docker_check_pid" 2>/dev/null || true
                fi
                
                if [ "$docker_check_success" = "true" ]; then
                    docker_daemon_ok=true
                    log_success "Docker daemon started successfully!"
                    break
                fi
                
                log_info "[DEBUG] Docker daemon not ready yet, waiting ${wait_interval}s..."
                sleep $wait_interval
                waited=$((waited + wait_interval))
            done
            
            if [ "$docker_daemon_ok" != "true" ]; then
                log_error "[DEBUG] Docker daemon did not start within ${max_wait} seconds"
                log_error "Docker daemon failed to start automatically"
                log_info "Please start Docker Desktop manually and try again"
                exit 1
            fi
    elif command_exists systemctl; then
        log_info "[DEBUG] Detected Linux with systemd, attempting to start Docker service..."
        log_info "Starting Docker service..."
        if sudo systemctl start docker 2>/dev/null; then
            log_info "[DEBUG] Docker service start command executed, waiting for it to start..."
            sleep 3
            if timeout 5 docker info >/dev/null 2>&1; then
                docker_daemon_ok=true
                log_success "Docker daemon started successfully!"
            else
                log_error "[DEBUG] Docker service started but daemon is not responding"
                log_error "Please check Docker service status: sudo systemctl status docker"
                exit 1
            fi
        else
            log_error "[DEBUG] Failed to start Docker service"
            log_error "Please start Docker service manually: sudo systemctl start docker"
            exit 1
        fi
    else
        log_error "[DEBUG] Cannot automatically start Docker on this system"
        log_error "Please start Docker Desktop or Docker daemon manually and try again"
        exit 1
    fi
    # After attempting to start Docker, verify it's now running
    if [ "$docker_daemon_ok" = "true" ]; then
        log_success "Docker daemon started successfully and is now responsive"
    fi
fi

# At this point, Docker should be running (either was already running or we just started it)
if [ "$docker_daemon_ok" != "true" ]; then
    log_error "Docker daemon is not running and could not be started automatically"
    exit 1
fi

log_info "[DEBUG] Docker daemon is running and responsive"

log_step "Docker Cleanup"

cleanup_success=true

if [ "$CLEAN_ALL" = true ]; then
    log_info "[DEBUG] CLEAN_ALL mode enabled"
    log_info "Cleaning all unused Docker resources..."
    log_warning "This will remove:"
    log_warning "  - All stopped containers"
    log_warning "  - All unused images (not just dangling)"
    log_warning "  - All unused volumes"
    log_warning "  - All build cache"
    log_info "[DEBUG] Proceeding with cleanup (non-interactive mode)"
    log_info "Running docker system prune -a -f --volumes..."
    log_info "[DEBUG] Starting docker system prune at $(date)"
    if docker system prune -a -f --volumes; then
        log_info "[DEBUG] docker system prune completed successfully at $(date)"
        log_success "Docker cleanup completed successfully"
    else
        log_error "[DEBUG] docker system prune failed at $(date)"
        log_error "Docker cleanup failed"
        cleanup_success=false
    fi
else
    log_info "[DEBUG] Selective cleanup mode (not --all)"
    if [ "$CLEAN_IMAGES" = true ]; then
        log_info "[DEBUG] Starting image cleanup at $(date)"
        log_info "Removing dangling images..."
        pruned=$(docker image prune -f 2>/dev/null | grep -oE 'Total reclaimed space: [0-9.]+[KMGT]?i?B?' | grep -oE '[0-9.]+[KMGT]?i?B?' || echo "0B")
        log_info "[DEBUG] Image prune completed, reclaimed: $pruned"
        if [ "$pruned" != "0B" ]; then
            log_success "Cleaned up $pruned of dangling images"
        else
            log_info "No dangling images to clean"
        fi
    fi
    
    if [ "$CLEAN_CONTAINERS" = true ]; then
        log_info "[DEBUG] Starting container cleanup at $(date)"
        log_info "Removing stopped containers..."
        if docker container prune -f; then
            log_info "[DEBUG] Container prune completed successfully at $(date)"
            log_success "Stopped containers removed"
        else
            log_warning "[DEBUG] Container prune failed at $(date)"
            log_warning "Failed to remove some stopped containers"
            cleanup_success=false
        fi
    fi
    
    if [ "$CLEAN_VOLUMES" = true ]; then
        log_info "[DEBUG] Starting volume cleanup at $(date)"
        log_warning "Removing unused volumes..."
        log_warning "This may remove database data if volumes are not in use!"
        log_info "[DEBUG] Proceeding with volume cleanup (non-interactive mode)"
        if docker volume prune -f; then
            log_info "[DEBUG] Volume prune completed successfully at $(date)"
            log_success "Unused volumes removed"
        else
            log_warning "[DEBUG] Volume prune failed at $(date)"
            log_warning "Failed to remove some unused volumes"
            cleanup_success=false
        fi
    fi
    
    if [ "$CLEAN_CACHE" = true ]; then
        log_info "[DEBUG] Starting build cache cleanup at $(date)"
        log_info "Removing build cache..."
        if docker builder prune -f; then
            log_info "[DEBUG] Builder prune completed successfully at $(date)"
            log_success "Build cache removed"
        else
            log_warning "[DEBUG] Builder prune failed at $(date)"
            log_warning "Failed to remove some build cache"
            cleanup_success=false
        fi
    fi
fi

echo ""
log_info "[DEBUG] Cleanup operations completed, showing final Docker disk usage"
log_info "Current Docker disk usage after cleanup:"
log_info "[DEBUG] Running: docker system df"
docker system df
log_info "[DEBUG] docker system df completed"

if [ "$cleanup_success" = "true" ]; then
    log_info "[DEBUG] All cleanup operations succeeded, exiting with code 0"
    exit 0
else
    log_warning "[DEBUG] Some cleanup operations had issues, exiting with code 1"
    log_warning "Some cleanup operations had issues"
    exit 1
fi

