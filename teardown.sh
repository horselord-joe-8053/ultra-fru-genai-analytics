#!/usr/bin/env bash
# =============================================================================
# Root teardown entrypoint: ./teardown.sh <local|aws> <kube|nonkube|all> [env] [options...]
# =============================================================================
# Delegates to orchestration/teardown.sh. Supports:
#   local nonkube   → Teardown local Docker Compose
#   local kube      → Teardown local Kubernetes
#   aws nonkube [env] → Teardown AWS ECS only
#   aws kube [env]    → Teardown AWS EKS only
#   aws all [env]     → Teardown AWS EKS + ECS + shared infra (VPC, Aurora, IAM)
#
# For problem-free ./run.sh aws kube dev --preempt: preempt runs teardown with
# --container-type all (so shared infra is destroyed), then deploy. Teardown
# imports existing infra into state before destroy so orphaned resources (e.g.
# DB subnet group) are removed; see docs/learned/VPC_LEARNED.md and README_WAR_STORIES.md.
#
# Options: --force, --dry-run, etc. forwarded to target script.
# Usage:   ./teardown.sh [local|aws] [kube|nonkube|all] [dev|prod] [options...]
# =============================================================================
set -e
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT
exec "$REPO_ROOT/orchestration/teardown.sh" "$@"
