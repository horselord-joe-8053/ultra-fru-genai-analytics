#!/bin/bash
# Re-initialize Terragrunt layers so provider plugins match the lock file.
# Use when you see: "the cached package ... does not match any of the checksums recorded in the dependency lock file"
#
# Usage: ./init-all-layers.sh [dev|prod]
# From repo root: ./orchestration/terraform/init-all-layers.sh dev

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

ENV="${1:-dev}"
if [[ ! "$ENV" =~ ^(dev|prod)$ ]]; then
    echo "Usage: $0 [dev|prod]"
    exit 1
fi

echo "Re-initializing Terragrunt layers for environment: $ENV"
echo "This re-downloads providers to match .terraform.lock.hcl in each layer."
echo ""

# Infrastructure (EKS depends on its outputs)
INFRA_DIR="$REPO_ROOT/module_infra_basic/aws/terra/environments/$ENV/infrastructure"
if [ -d "$INFRA_DIR" ]; then
    echo ">>> infrastructure"
    (cd "$INFRA_DIR" && terragrunt init -reconfigure) || { echo "infrastructure init failed"; exit 1; }
    echo ""
fi

# EKS layer
EKS_DIR="$REPO_ROOT/module_infra_kubetypes/kube/aws/terra/environments/$ENV/eks"
if [ -d "$EKS_DIR" ]; then
    echo ">>> eks"
    (cd "$EKS_DIR" && terragrunt init -reconfigure) || { echo "eks init failed"; exit 1; }
    echo ""
fi

# ECS layer (optional, for non-EKS deploys)
ECS_DIR="$REPO_ROOT/module_infra_kubetypes/nonkube/aws/terra/environments/$ENV/ecs"
if [ -d "$ECS_DIR" ]; then
    echo ">>> ecs"
    (cd "$ECS_DIR" && terragrunt init -reconfigure) || { echo "ecs init failed"; exit 1; }
    echo ""
fi

echo "Done. Re-run your deploy (e.g. ./run.sh aws kube dev --skip-build)."
