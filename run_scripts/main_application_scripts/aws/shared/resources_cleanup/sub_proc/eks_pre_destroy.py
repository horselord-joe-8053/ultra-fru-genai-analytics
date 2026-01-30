#!/usr/bin/env python3
"""
EKS pre-destroy: stop EKS services (scale to 0), empty EKS frontend and analytics S3 buckets.

Called by teardown-resources-all.sh before terraform destroy when --container-type eks.
Uses subprocess to invoke stop-eks-services.sh; uses boto3 to empty S3.
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

try:
    import boto3
    from botocore.exceptions import ClientError
except ImportError:
    print("boto3 is required. Install with: pip install boto3", file=sys.stderr)
    sys.exit(1)

PROJECT_NAME = "fru"
SCRIPT_DIR = Path(__file__).resolve().parent
# resources_cleanup/sub_proc -> 2 levels up to resources_cleanup, then 4 more to run_scripts -> 1 more to repo root
REPO_ROOT = SCRIPT_DIR.parent.parent.parent.parent.parent.parent


def get_account_id(session):
    try:
        sts = session.client("sts")
        return sts.get_caller_identity()["Account"]
    except ClientError:
        return None


def empty_bucket(s3_client, bucket: str, dry_run: bool) -> bool:
    try:
        paginator = s3_client.get_paginator("list_object_versions")
        delete_list = []
        for page in paginator.paginate(Bucket=bucket):
            for obj in page.get("Versions", []) or []:
                o = {"Key": obj["Key"]}
                if obj.get("VersionId"):
                    o["VersionId"] = obj["VersionId"]
                delete_list.append(o)
            for obj in page.get("DeleteMarkers", []) or []:
                o = {"Key": obj["Key"]}
                if obj.get("VersionId"):
                    o["VersionId"] = obj["VersionId"]
                delete_list.append(o)
        for page in s3_client.get_paginator("list_objects_v2").paginate(Bucket=bucket):
            for obj in page.get("Contents", []) or []:
                if not any(d["Key"] == obj["Key"] for d in delete_list):
                    delete_list.append({"Key": obj["Key"]})
        if not delete_list:
            print(f"  Bucket {bucket} already empty")
            return True
        if dry_run:
            print(f"  [DRY-RUN] Would delete {len(delete_list)} object(s) from {bucket}")
            return True
        for i in range(0, len(delete_list), 1000):
            chunk = delete_list[i : i + 1000]
            s3_client.delete_objects(Bucket=bucket, Delete={"Objects": chunk, "Quiet": True})
        print(f"  Emptied bucket: {bucket}")
        return True
    except ClientError as e:
        print(f"  Error emptying {bucket}: {e}", file=sys.stderr)
        return False


def run_stop_eks_services(
    repo_root: Path,
    cluster_name: str,
    profile: str,
    region: str,
    dry_run: bool,
) -> bool:
    env = os.environ.copy()
    env["REPO_ROOT"] = str(repo_root)
    env["AWS_PROFILE"] = profile
    env["AWS_REGION"] = region
    env["DRY_RUN"] = "true" if dry_run else "false"
    stop_script = repo_root / "run_scripts/main_application_scripts/aws/eks/helpers/stop-eks-services.sh"
    logger_sh = repo_root / "run_scripts/shared/logger.sh"
    load_env_sh = repo_root / "run_scripts/shared/load-env.sh"
    if not stop_script.exists():
        print(f"  Warning: {stop_script} not found; skipping stop EKS services", file=sys.stderr)
        return True
    cmd = (
        f'set -e; source "{logger_sh}" 2>/dev/null || true; '
        f'source "{load_env_sh}" 2>/dev/null || true; '
        f'source "{stop_script}"; '
        f'stop_eks_services "{cluster_name}" "{profile}" "{region}" "{str(dry_run).lower()}"'
    )
    r = subprocess.run(["bash", "-c", cmd], env=env, cwd=str(repo_root))
    return r.returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser(description="EKS pre-destroy: stop services, empty S3 buckets.")
    parser.add_argument("--environment", "-e", default="dev")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--profile", default=os.environ.get("AWS_PROFILE", "admin"))
    parser.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    args = parser.parse_args()

    print("== EKS pre-destroy ==")
    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    account_id = get_account_id(session)
    if not account_id:
        print("Error: could not resolve AWS account ID", file=sys.stderr)
        return 1

    cluster_name = f"{PROJECT_NAME}-{args.environment}-cluster"
    buckets = [
        f"{PROJECT_NAME}-{args.environment}-frontend-eks-{account_id}",
        f"{PROJECT_NAME}-{args.environment}-analytics-data-{account_id}",
    ]

    if not run_stop_eks_services(REPO_ROOT, cluster_name, args.profile, args.region, args.dry_run):
        print("Warning: stop EKS services had issues (continuing)", file=sys.stderr)

    s3 = session.client("s3", region_name=args.region)
    for bucket in buckets:
        try:
            s3.head_bucket(Bucket=bucket)
        except ClientError:
            print(f"  Bucket {bucket} does not exist (skip)")
            continue
        empty_bucket(s3, bucket, args.dry_run)

    print("EKS pre-destroy done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
