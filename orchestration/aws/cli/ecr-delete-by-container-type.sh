#!/bin/bash
# Delete ECR images by container-type: only images with tag `eks`, only with tag `ecs`, or all.
# Used by teardown so eks teardown does not delete ecs images and vice versa.
# See docs/learned/REFACTOR_PLAN_ECR_TAGS_AND_TEARDOWN.md.
#
# Usage:
#   ./ecr-delete-by-container-type.sh --container-type <eks|ecs|all> [--repo NAME] [--dry-run] [--profile P] [--region R]
#
# Options:
#   --container-type   Required. eks = delete only images with tag "eks"; ecs = only tag "ecs"; all = delete all images.
#   --repo            ECR repository name (default: fru-api).
#   --dry-run         List what would be deleted; do not delete.
#   --profile         AWS CLI profile (default: admin).
#   --region          AWS region (default: us-east-1).

set -e

REPO_NAME="${ECR_REPO_NAME:-fru-api}"
CONTAINER_TYPE=""
DRY_RUN="false"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --container-type) CONTAINER_TYPE="$2"; shift 2 ;;
        --repo) REPO_NAME="$2"; shift 2 ;;
        --dry-run) DRY_RUN="true"; shift ;;
        --profile) AWS_PROFILE="$2"; shift 2 ;;
        --region) AWS_REGION="$2"; shift 2 ;;
        -h|--help)
            head -20 "$(dirname "$0")/ecr-delete-by-container-type.sh" | grep -E '^#'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ "$CONTAINER_TYPE" != "eks" && "$CONTAINER_TYPE" != "ecs" && "$CONTAINER_TYPE" != "all" ]]; then
    echo "ERROR: --container-type is required and must be eks, ecs, or all" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
# shellcheck source=/dev/null
[ -f "$REPO_ROOT/lib/logger.sh" ] && source "$REPO_ROOT/lib/logger.sh" || {
    log_info() { echo "[INFO] $*"; }
    log_warning() { echo "[WARNING] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
}

if ! command -v aws >/dev/null 2>&1; then
    log_error "aws CLI not found"
    exit 1
fi

if ! aws ecr describe-repositories --repository-names "$REPO_NAME" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
    log_info "ECR repository not found: $REPO_NAME (skipping ECR cleanup)"
    exit 0
fi

# List all images with tags and push date (sorted by imagePushedAt ascending = oldest first in list)
# We delete newest first (reverse order) so manifest list is usually deleted before children
IMAGES_JSON=$(aws ecr describe-images \
    --repository-name "$REPO_NAME" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query 'sort_by(imageDetails,& imagePushedAt)' \
    --output json 2>/dev/null || echo "[]")

TOTAL=$(echo "$IMAGES_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "0")
if [ "$TOTAL" -eq 0 ]; then
    log_info "No images in $REPO_NAME."
    exit 0
fi

# Build list of digests to delete (as imageIds for batch-delete-image)
# For eks: only images that have tag "eks". For ecs: only tag "ecs". For all: all.
# Sort newest first (reverse list) for manifest-list-safe order
TO_DELETE_JSON=$(echo "$IMAGES_JSON" | python3 -c "
import sys, json
images = json.load(sys.stdin)
ct = '$CONTAINER_TYPE'
to_del = []
for img in reversed(images):
    tags = img.get('imageTags') or []
    if ct == 'all':
        to_del.append({'imageDigest': img['imageDigest']})
    elif ct == 'eks' and 'eks' in tags:
        to_del.append({'imageDigest': img['imageDigest']})
    elif ct == 'ecs' and 'ecs' in tags:
        to_del.append({'imageDigest': img['imageDigest']})
print(json.dumps(to_del))
" 2>/dev/null || echo "[]")

DELETE_COUNT=$(echo "$TO_DELETE_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [ "$DELETE_COUNT" -eq 0 ]; then
    log_info "No images to delete for container-type=$CONTAINER_TYPE (repo: $REPO_NAME, total images: $TOTAL)."
    exit 0
fi

log_info "Repository: $REPO_NAME | Container-type: $CONTAINER_TYPE | To delete: $DELETE_COUNT image(s) (dry-run=$DRY_RUN)"
if [ "$DRY_RUN" = "true" ]; then
    log_info "Dry-run: would delete these image(s):"
    echo "$TO_DELETE_JSON" | python3 -c "
import sys, json
for img in json.load(sys.stdin):
    digest = img.get('imageDigest', '')[:24] + '...'
    print('  ', digest)
" 2>/dev/null || true
    exit 0
fi

CHUNK_SIZE=100
OFFSET=0
DELETED=0
while [ "$OFFSET" -lt "$DELETE_COUNT" ]; do
    CHUNK=$(echo "$TO_DELETE_JSON" | python3 -c "
import sys, json
arr = json.load(sys.stdin)
start = $OFFSET
size = $CHUNK_SIZE
print(json.dumps(arr[start:start+size]))
" 2>/dev/null)
    CHUNK_LEN=$(echo "$CHUNK" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
    [ "$CHUNK_LEN" -eq 0 ] && break
    RESP=$(aws ecr batch-delete-image \
        --repository-name "$REPO_NAME" \
        --image-ids "$CHUNK" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" --output json 2>&1) || true
    SUCC=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('imageIds',[])))" 2>/dev/null || echo "0")
    FAILURES=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('failures',[])))" 2>/dev/null || echo "0")
    DELETED=$((DELETED + SUCC))
    if [ "$SUCC" -gt 0 ]; then
        log_info "  Deleted $SUCC image(s) in this batch."
    fi
    if [ "$FAILURES" -gt 0 ]; then
        log_warning "  $FAILURES image(s) could not be deleted (e.g. referenced by manifest list):"
        echo "$RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for f in d.get('failures', []):
    print('    -', f.get('failureCode', ''), (f.get('failureReason', '') or '')[:80])
" 2>/dev/null || true
    fi
    OFFSET=$((OFFSET + CHUNK_SIZE))
done
log_success "ECR cleanup (container-type=$CONTAINER_TYPE): deleted $DELETED image(s) from $REPO_NAME."
