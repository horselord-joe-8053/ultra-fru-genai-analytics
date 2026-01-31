#!/bin/bash
# List local Docker images that would be deleted by cleanup (e.g. orchestration/common/deploy/cleanup-local-docker-images.sh).
# Use this to preview what `cleanup_local_images_by_pattern` would remove without deleting.
#
# Usage:
#   ./util_sh/list-docker-images-to-delete.sh [REPO_NAME]
#   REPO_NAME defaults to fru-api (same as cleanup-local-docker-images.sh).
#
# Options:
#   -q    Quiet: print only image lines (ID REPO:TAG), no headers.
#   --help  Show this help.

set -e

REPO_NAME="fru-api"
QUIET=false

while [ $# -gt 0 ]; do
    case "$1" in
        -q) QUIET=true; shift ;;
        --help|-h)
            echo "Usage: $0 [REPO_NAME] [-q]"
            echo "  REPO_NAME  ECR/local repo name (default: fru-api)"
            echo "  -q        Quiet: only print image lines (ID REPO:TAG)"
            exit 0
            ;;
        *) REPO_NAME="$1"; shift ;;
    esac
done

if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not running." >&2
    exit 1
fi

list_images() {
    # Same patterns as cleanup_local_images_by_pattern in orchestration/common/deploy/cleanup-local-docker-images.sh
    # 1) Repo name pattern (e.g. fru-api:*)
    docker images "${REPO_NAME}" --format "{{.ID}} {{.Repository}}:{{.Tag}}" 2>/dev/null || true
    # 2) ECR URI pattern (*.dkr.ecr.*.amazonaws.com/REPO_NAME:*)
    docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" 2>/dev/null | grep -E "\.dkr\.ecr\..*\.amazonaws\.com/${REPO_NAME}:" || true
}

if [ "$QUIET" = "true" ]; then
    list_images
else
    echo "Local Docker images that would be deleted (repo pattern: ${REPO_NAME}:* and ECR *.../${REPO_NAME}:*):"
    echo "---"
    list_images | sed 's/^/  /'
    echo "---"
    echo "To remove these, source orchestration/common/deploy/cleanup-local-docker-images.sh and call cleanup_local_images_by_pattern '$REPO_NAME'."
fi
