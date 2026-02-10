#!/bin/bash
# List local Docker images that would be deleted by cleanup (e.g. util_sh/delete-docker-images.sh).
# Use this to preview what delete-docker-images.sh would remove without deleting.
#
# Usage:
#   ./util_sh/list-docker-images-to-delete.sh [--repo REPO_NAME] [-q] [--help]
#   If no --repo specified, lists ALL local Docker images.
#
# Options:
#   --repo REPO_NAME  Filter to specific repo (e.g., fru-api). If omitted, lists all images.
#   -q               Quiet: print only image lines (ID REPO:TAG), no headers.
#   --help           Show this help.

set -e

REPO_NAME=""
QUIET=false

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)
            REPO_NAME="$2"
            shift 2
            ;;
        -q)
            QUIET=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--repo REPO_NAME] [-q] [--help]"
            echo "  --repo REPO_NAME  Filter to specific repo (e.g., fru-api)"
            echo "                   If omitted, lists ALL local Docker images"
            echo "  -q               Quiet: only print image lines (ID REPO:TAG)"
            echo "  --help           Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                    # List all local images"
            echo "  $0 --repo fru-api     # List only fru-api images"
            echo "  $0 -q                 # List all images (quiet mode)"
            echo "  $0 --repo fru-api -q  # List fru-api images (quiet mode)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not running." >&2
    exit 1
fi

list_images() {
    if [ -z "$REPO_NAME" ]; then
        # List ALL docker images
        docker images --format "{{.ID}} {{.Repository}}:{{.Tag}}" 2>/dev/null || true
    else
        # Same patterns as cleanup_local_images_by_pattern in orchestration/common/deploy/cleanup-local-docker-images.sh
        # 1) Repo name pattern (e.g. fru-api:*)
        docker images "${REPO_NAME}" --format "{{.ID}} {{.Repository}}:{{.Tag}}" 2>/dev/null || true
        # 2) ECR URI pattern (*.dkr.ecr.*.amazonaws.com/REPO_NAME:*)
        docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" 2>/dev/null | grep -E "\.dkr\.ecr\..*\.amazonaws\.com/${REPO_NAME}:" || true
    fi
}

if [ "$QUIET" = "true" ]; then
    list_images
else
    if [ -z "$REPO_NAME" ]; then
        echo "All local Docker images:"
    else
        echo "Local Docker images that would be deleted (repo pattern: ${REPO_NAME}:* and ECR *.../${REPO_NAME}:*):"
    fi
    echo "---"
    list_images | sed 's/^/  /'
    echo "---"
    if [ -z "$REPO_NAME" ]; then
        echo "To remove all these images, run: ./util_sh/delete-docker-images.sh"
    else
        echo "To remove these images, run: ./util_sh/delete-docker-images.sh --repo '$REPO_NAME'"
    fi
fi
