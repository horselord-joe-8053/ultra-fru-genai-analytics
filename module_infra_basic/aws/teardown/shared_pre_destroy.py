#!/usr/bin/env python3
"""
Shared pre-destroy: empty analytics S3 bucket only.

Called when tearing down shared infrastructure (after container layers are destroyed).
Uses boto3 to empty the analytics bucket so Terraform can destroy it.
"""

import argparse
import os
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
REPO_ROOT = SCRIPT_DIR.parent.parent.parent  # teardown -> aws -> module_infra_basic -> repo


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


def main() -> int:
    parser = argparse.ArgumentParser(description="Shared pre-destroy: empty analytics S3 bucket.")
    parser.add_argument("--environment", "-e", default="dev")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--profile", default=os.environ.get("AWS_PROFILE", "admin"))
    parser.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    args = parser.parse_args()

    print("== Shared pre-destroy (analytics bucket) ==")
    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    account_id = get_account_id(session)
    if not account_id:
        print("Error: could not resolve AWS account ID", file=sys.stderr)
        return 1

    bucket = f"{PROJECT_NAME}-{args.environment}-analytics-data-{account_id}"
    s3 = session.client("s3", region_name=args.region)
    try:
        s3.head_bucket(Bucket=bucket)
    except ClientError:
        print(f"  Bucket {bucket} does not exist (skip)")
        return 0
    empty_bucket(s3, bucket, args.dry_run)
    print("Shared pre-destroy done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
