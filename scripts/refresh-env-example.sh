#!/usr/bin/env bash
# Copy .env → .env.example and redact sensitive values.
# Run from repo root after updating .env. Do not commit .env.
# Usage: ./scripts/refresh-env-example.sh

set -e
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$REPO_ROOT"

ENV_SRC="$REPO_ROOT/.env"
ENV_DST="$REPO_ROOT/.env.example"

if [ ! -f "$ENV_SRC" ]; then
    echo "Error: .env not found at $ENV_SRC. Create it first (e.g. cp .env.example .env)." >&2
    exit 1
fi

# Redact: replace values for known sensitive keys with placeholders
# Keep comments and section headers; only replace VAR=value lines for sensitive vars
SENSITIVE_KEYS="PGPASSWORD|DB_PASSWORD|OPENAI_API_KEY|CLAUDE_API_KEY|AWS_ADMIN_ACCESS_KEY_ID|AWS_ADMIN_SECRET_ACCESS_KEY|AWS_BEDROCK_ACCESS_KEY_ID|AWS_BEDROCK_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|AZURE_CLIENT_SECRET|OCI_*_KEY"

awk -v keys="$SENSITIVE_KEYS" '
BEGIN { split(keys, a, "|"); for (i in a) sensitive[a[i]] = 1 }
/^#/ { print; next }
/^[A-Za-z_][A-Za-z0-9_]*=/ {
    key = $0; sub(/=.*/, "", key)
    if (key in sensitive) { print key "=<redacted>"; next }
}
{ print }
' "$ENV_SRC" > "$ENV_DST"

echo "Wrote redacted .env.example from .env. Review diff before committing."
echo "  git diff .env.example"
