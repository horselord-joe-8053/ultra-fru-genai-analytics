#!/bin/bash
# Prune old images from the fru-api ECR repository.
# Keeps the most recent K images (or images pushed in the last N days); deletes the rest.
#
# Usage:
#   ./ecr-prune-old-images.sh [--keep N] [--older-than-days N] [--dry-run] [--profile PROFILE] [--region REGION]
#
# Options:
#   --keep N              Keep the N most recently pushed images (default: 10).
#   --older-than-days N   Alternative: delete only images older than N days (keep recent ones).
#   --dry-run             List what would be deleted; do not delete.
#   --profile PROFILE     AWS CLI profile (default: admin).
#   --region REGION       AWS region (default: us-east-1).
#
# Examples:
#   ./ecr-prune-old-images.sh --keep 5 --dry-run
#   ./ecr-prune-old-images.sh --older-than-days 14
#   ./ecr-prune-old-images.sh --keep 10

set -e

REPO_NAME="${ECR_REPO_NAME:-fru-api}"
KEEP="${KEEP:-10}"
OLDER_THAN_DAYS=""
DRY_RUN="false"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) KEEP="$2"; shift 2 ;;
        --older-than-days) OLDER_THAN_DAYS="$2"; shift 2 ;;
        --dry-run) DRY_RUN="true"; shift ;;
        --profile) AWS_PROFILE="$2"; shift 2 ;;
        --region) AWS_REGION="$2"; shift 2 ;;
        -h|--help)
            head -25 "$(dirname "$0")/ecr-prune-old-images.sh" | grep -E '^#'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

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
    log_error "ECR repository not found: $REPO_NAME (profile=$AWS_PROFILE region=$AWS_REGION)"
    exit 1
fi

# List all images with push date (imageId + imagePushedAt)
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

# Build list of imageIds to DELETE (old ones)
if [ -n "$OLDER_THAN_DAYS" ]; then
    CUTOFF_EPOCH=$(($(date +%s) - (OLDER_THAN_DAYS * 86400)))
    TO_DELETE_JSON=$(echo "$IMAGES_JSON" | python3 -c "
import sys, json
from datetime import datetime, timezone
images = json.load(sys.stdin)
cutoff = $CUTOFF_EPOCH
to_del = []
for img in images:
    pushed = img.get('imagePushedAt')
    if not pushed:
        continue
    s = pushed.replace('Z', '+00:00')[:22]
    try:
        ts = datetime.fromisoformat(s).timestamp()
    except Exception:
        continue
    if ts < cutoff:
        to_del.append({'imageDigest': img['imageDigest']})
print(json.dumps(to_del))
" 2>/dev/null || echo "[]")
else
    # Keep last K; delete the rest (older first, so delete indices 0 .. -(K+1))
    TO_DELETE_JSON=$(echo "$IMAGES_JSON" | python3 -c "
import sys, json
images = json.load(sys.stdin)
k = $KEEP
to_del = [{'imageDigest': img['imageDigest']} for img in (images[:-k] if k > 0 else images)]
print(json.dumps(to_del))
" 2>/dev/null || echo "[]")
fi

DELETE_COUNT=$(echo "$TO_DELETE_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [ "$DELETE_COUNT" -eq 0 ]; then
    log_info "Nothing to prune: would keep all $TOTAL image(s) (keep=$KEEP or older-than-days=$OLDER_THAN_DAYS)."
    exit 0
fi

log_info "Repository: $REPO_NAME | Total images: $TOTAL | To delete: $DELETE_COUNT (dry-run=$DRY_RUN)"
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

# Delete in chunks of 100 (AWS limit)
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
    print('    -', f.get('failureCode', ''), f.get('failureReason', '')[:80])
" 2>/dev/null || true
    fi
    OFFSET=$((OFFSET + CHUNK_SIZE))
done
log_success "Pruned $DELETED old image(s) from $REPO_NAME (kept most recent)."
