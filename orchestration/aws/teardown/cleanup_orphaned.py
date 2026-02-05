#!/usr/bin/env python3
"""
Cleanup orphaned AWS resources: S3 buckets, ECR images, ECS task definitions.

Replaces helpers/cleanup-orphaned-resources.sh and helpers/python/ecr_cleanup.py.
Uses boto3 for all AWS operations. Safe by default (dry-run); use --force to delete.
"""

import argparse
import logging
import sys
from datetime import datetime, timezone, timedelta
from typing import List, Dict, Any, Optional, Tuple

try:
    import boto3
    from botocore.exceptions import ClientError
except ImportError:
    print("boto3 is required. Install with: pip install boto3", file=sys.stderr)
    sys.exit(1)

PROJECT_NAME = "fru"
ECR_REPO_NAME = "fru-api"
LOG = logging.getLogger(__name__)


def setup_logging(verbose: bool = False) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(message)s",
        stream=sys.stdout,
    )
    # Silence boto3/botocore noise unless verbose
    if not verbose:
        logging.getLogger("boto3").setLevel(logging.WARNING)
        logging.getLogger("botocore").setLevel(logging.WARNING)


def log_step(msg: str) -> None:
    LOG.info("")
    LOG.info("== %s ==", msg)


def log_info(msg: str) -> None:
    LOG.info("  %s", msg)


def log_success(msg: str) -> None:
    LOG.info("  ✓ %s", msg)


def log_warning(msg: str) -> None:
    LOG.warning("  ⚠ %s", msg)


def log_error(msg: str) -> None:
    LOG.error("  ✗ %s", msg)


# ---------------------------------------------------------------------------
# S3 bucket cleanup
# ---------------------------------------------------------------------------

def get_expected_buckets(account_id: str, environment: str) -> List[str]:
    return [
        f"fru-terraform-state-{account_id}",
        f"{PROJECT_NAME}-{environment}-analytics-data-{account_id}",
        f"{PROJECT_NAME}-{environment}-frontend-{account_id}",
        f"{PROJECT_NAME}-{environment}-frontend-eks-{account_id}",
        f"{PROJECT_NAME}-{environment}-frontend-ecs-{account_id}",
    ]


def is_bucket_cloudfront_origin(cloudfront_client, bucket: str) -> bool:
    """Check if bucket is used as CloudFront origin (domain is bucket.s3.*.amazonaws.com)."""
    try:
        paginator = cloudfront_client.get_paginator("list_distributions")
        for page in paginator.paginate():
            for dist in page.get("DistributionList", {}).get("Items", []) or []:
                for origin in dist.get("Origins", {}).get("Items", []) or []:
                    domain = origin.get("DomainName", "")
                    # Domain is bucket.s3.region.amazonaws.com or bucket.s3.amazonaws.com
                    if domain.startswith(f"{bucket}.") or domain == f"{bucket}.s3.amazonaws.com":
                        return True
    except ClientError as e:
        log_warning(f"Could not list CloudFront distributions: {e}")
    return False


def empty_bucket(s3_client, bucket: str, region: str, dry_run: bool) -> bool:
    """Empty bucket (objects and versions). Returns True on success."""
    try:
        delete_list = []
        paginator = s3_client.get_paginator("list_object_versions")
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
        # Non-versioned: list_objects_v2
        for page in s3_client.get_paginator("list_objects_v2").paginate(Bucket=bucket):
            for obj in page.get("Contents", []) or []:
                key = obj["Key"]
                if not any(d["Key"] == key for d in delete_list):
                    delete_list.append({"Key": key})
        if not delete_list:
            return True
        if dry_run:
            log_info(f"[DRY-RUN] Would delete {len(delete_list)} object(s) from {bucket}")
            return True
        for i in range(0, len(delete_list), 1000):
            chunk = delete_list[i : i + 1000]
            s3_client.delete_objects(Bucket=bucket, Delete={"Objects": chunk, "Quiet": True})
        return True
    except ClientError as e:
        log_error(f"Failed to empty bucket {bucket}: {e}")
        return False


def cleanup_s3_buckets(
    session,
    account_id: str,
    environment: str,
    profile: str,
    region: str,
    dry_run: bool,
    force: bool,
) -> bool:
    log_step("Checking S3 Buckets")
    expected = get_expected_buckets(account_id, environment)
    for b in expected:
        log_info(f"Expected (Terraform-managed - will NOT delete): {b}")
    log_info("")

    s3 = session.client("s3", region_name=region)
    try:
        buckets_resp = s3.list_buckets()
    except ClientError as e:
        log_error(f"Failed to list buckets: {e}")
        return False

    all_buckets = [b["Name"] for b in buckets_resp.get("Buckets", []) if b["Name"].startswith("fru")]
    if not all_buckets:
        log_info("No S3 buckets found with 'fru' prefix")
        return True

    deleted = 0
    skipped = 0
    for bucket in all_buckets:
        if bucket in expected:
            log_info(f"✓ {bucket} (managed by Terraform - skipping)")
            continue

        log_warning(f"? {bucket} (potentially orphaned)")
        try:
            bucket_region = s3.get_bucket_location(Bucket=bucket).get("LocationConstraint") or "us-east-1"
        except ClientError:
            bucket_region = region

        cf = session.client("cloudfront", region_name=region)
        if is_bucket_cloudfront_origin(cf, bucket):
            log_warning("  NOT DELETED - bucket is CloudFront origin. Remove distribution first.")
            skipped += 1
            continue

        # Count objects
        try:
            paginator = s3.get_paginator("list_object_versions")
            total = 0
            for page in paginator.paginate(Bucket=bucket):
                total += len(page.get("Versions", []) or []) + len(page.get("DeleteMarkers", []) or [])
            for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket):
                total += len(page.get("Contents", []) or [])
        except ClientError:
            total = -1

        if not force:
            if total == 0:
                log_info(f"  [DRY-RUN] Would delete empty bucket: {bucket}")
            else:
                log_info(f"  [DRY-RUN] Would delete bucket with ~{total} object(s). Use --force to delete.")
            continue

        if total > 0:
            log_info(f"  Emptying bucket ({total} object(s))...")
            if not empty_bucket(s3, bucket, bucket_region, dry_run=False):
                skipped += 1
                continue
        if dry_run:
            log_info(f"  [DRY-RUN] Would delete bucket: {bucket}")
            continue
        try:
            s3.delete_bucket(Bucket=bucket)
            log_success(f"Deleted bucket: {bucket}")
            deleted += 1
        except ClientError as e:
            log_warning(f"Could not delete bucket {bucket}: {e}")
            skipped += 1

    log_info("")
    log_info(f"S3 Summary: found {len(all_buckets)} fru buckets, deleted {deleted}, skipped {skipped}")
    return True


# ---------------------------------------------------------------------------
# ECR image cleanup (logic from ecr_cleanup.py)
# ---------------------------------------------------------------------------

def filter_images_for_deletion(
    images: List[Dict],
    retention_days: int = 7,
    keep_recent: int = 5,
) -> List[Dict[str, str]]:
    if not images:
        return []
    images_sorted = sorted(
        images,
        key=lambda x: x.get("imagePushedAt", ""),
        reverse=True,
    )
    cutoff = datetime.now(timezone.utc) - timedelta(days=retention_days)
    result = []
    for idx, img in enumerate(images_sorted):
        if idx < keep_recent:
            continue
        tags = img.get("imageTags", []) or []
        pushed_at = img.get("imagePushedAt")
        is_untagged = len(tags) == 0
        is_old = False
        if pushed_at:
            try:
                # boto3 returns imagePushedAt as datetime; CLI/raw API can return string
                if isinstance(pushed_at, datetime):
                    dt = pushed_at if pushed_at.tzinfo else pushed_at.replace(tzinfo=timezone.utc)
                elif isinstance(pushed_at, str):
                    dt = datetime.fromisoformat(pushed_at.replace("Z", "+00:00"))
                else:
                    dt = None
                if dt is not None:
                    is_old = dt < cutoff
            except (ValueError, AttributeError, TypeError):
                pass
        if not (is_untagged or is_old):
            continue
        ident = {}
        if img.get("imageDigest"):
            ident["imageDigest"] = img["imageDigest"]
        if tags:
            ident["imageTag"] = tags[0]
        if ident:
            result.append(ident)
    return result


def cleanup_ecr_images(
    session,
    profile: str,
    region: str,
    dry_run: bool,
    force: bool,
    retention_days: int,
    keep_recent: int,
) -> bool:
    log_step("Checking ECR Repository Images")
    ecr = session.client("ecr", region_name=region)
    try:
        ecr.describe_repositories(repositoryNames=[ECR_REPO_NAME])
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") == "RepositoryNotFoundException":
            log_info(f"ECR repository '{ECR_REPO_NAME}' does not exist")
            return True
        log_error(f"ECR error: {e}")
        return False

    log_info(f"Repository: {ECR_REPO_NAME}")
    try:
        paginator = ecr.get_paginator("describe_images")
        images = []
        for page in paginator.paginate(repositoryName=ECR_REPO_NAME):
            images.extend(page.get("imageDetails", []) or [])
    except ClientError as e:
        log_error(f"Failed to list images: {e}")
        return False

    log_info(f"Total images: {len(images)}")
    to_delete = filter_images_for_deletion(images, retention_days=retention_days, keep_recent=keep_recent)
    log_info(f"Eligible for deletion (retention/keep rules): {len(to_delete)}")

    if not to_delete:
        return True
    if dry_run or not force:
        log_info(f"[DRY-RUN] Would delete {len(to_delete)} image(s). Use --force to delete.")
        return True

    chunk_size = 100
    total_deleted = 0
    for i in range(0, len(to_delete), chunk_size):
        chunk = to_delete[i : i + chunk_size]
        try:
            ecr.batch_delete_image(repositoryName=ECR_REPO_NAME, imageIds=chunk)
            total_deleted += len(chunk)
        except ClientError as e:
            log_warning(f"Batch delete failed: {e}")
    log_success(f"Deleted {total_deleted} ECR image(s)")
    return True


# ---------------------------------------------------------------------------
# ECS task definition cleanup
# ---------------------------------------------------------------------------

def cleanup_ecs_resources(
    session,
    environment: str,
    region: str,
    dry_run: bool,
    force: bool,
) -> bool:
    log_step("Checking ECS Resources")
    cluster_name = f"{PROJECT_NAME}-{environment}-cluster"
    ecs = session.client("ecs", region_name=region)
    try:
        resp = ecs.describe_clusters(clusters=[cluster_name])
        clusters = resp.get("clusters") or []
        if not clusters or clusters[0].get("status") == "INACTIVE":
            log_info(f"ECS cluster '{cluster_name}' does not exist or is inactive")
            return True
    except ClientError as e:
        log_info(f"ECS cluster '{cluster_name}' does not exist or error: {e}")
        return True

    # Active task definitions (in use by services with desiredCount > 0 or runningCount > 0)
    active_task_defs = set()
    try:
        list_svc = ecs.list_services(cluster=cluster_name)
        for arn in list_svc.get("serviceArns", []) or []:
            desc = ecs.describe_services(cluster=cluster_name, services=[arn])
            for svc in desc.get("services", []) or []:
                if (svc.get("desiredCount", 0) or 0) > 0 or (svc.get("runningCount", 0) or 0) > 0:
                    td = svc.get("taskDefinition", "")
                    if td:
                        active_task_defs.add(td.split("/")[-1])  # family:revision
    except ClientError as e:
        log_warning(f"Could not list ECS services: {e}")

    family = f"{PROJECT_NAME}-{environment}-api"
    rollback_keep = 5 if active_task_defs else 0
    list_td_paginator = ecs.get_paginator("list_task_definitions")
    old_arns = []
    kept = 0
    for page in list_td_paginator.paginate(familyPrefix=family, sort="DESC"):
        for arn in page.get("taskDefinitionArns", []) or []:
            rev = arn.split("/")[-1]
            if rev in active_task_defs:
                continue
            kept += 1
            if kept <= rollback_keep:
                continue
            old_arns.append(arn)

    log_info(f"Total task definitions (family {family}): active protected, kept {rollback_keep} for rollback, eligible for deletion: {len(old_arns)}")
    if not old_arns:
        return True
    if dry_run or not force:
        log_info(f"[DRY-RUN] Would deregister {len(old_arns)} task definition(s). Use --force to delete.")
        return True

    for arn in old_arns:
        try:
            ecs.deregister_task_definition(taskDefinition=arn)
            log_success(f"Deregistered: {arn.split('/')[-1]}")
        except ClientError as e:
            log_warning(f"Failed to deregister {arn}: {e}")
    return True


# ---------------------------------------------------------------------------
# EKS (informational only)
# ---------------------------------------------------------------------------

def cleanup_eks_resources(session, environment: str, region: str) -> bool:
    log_step("Checking EKS Resources")
    cluster_name = f"{PROJECT_NAME}-{environment}-cluster"
    eks = session.client("eks", region_name=region)
    try:
        eks.describe_cluster(name=cluster_name)
        log_info(f"Cluster {cluster_name} exists. EKS resources (pods, services) are managed by Kubernetes; use kubectl to manage.")
    except ClientError:
        log_info(f"EKS cluster '{cluster_name}' does not exist")
    return True


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def get_account_id(session) -> Optional[str]:
    try:
        sts = session.client("sts")
        return sts.get_caller_identity()["Account"]
    except ClientError:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Cleanup orphaned AWS resources (S3, ECR, ECS task definitions).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--container-type", "--cont-sys", dest="container_type", choices=["ecs", "eks"], help="Container system (ecs or eks)")
    parser.add_argument("--environment", "-e", default="dev", help="Environment (dev, staging, prod)")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be deleted")
    parser.add_argument("--force", action="store_true", help="Actually delete resources")
    parser.add_argument("--ecr-retention-days", type=int, default=7, help="Keep ECR images newer than N days")
    parser.add_argument("--keep-images", type=int, default=5, help="Always keep N most recent ECR images")
    parser.add_argument("--profile", default="admin", help="AWS profile")
    parser.add_argument("--region", default="us-east-1", help="AWS region")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose logging")
    args = parser.parse_args()

    setup_logging(verbose=args.verbose)

    try:
        session = boto3.Session(profile_name=args.profile, region_name=args.region)
    except Exception as e:
        log_error(f"Failed to create AWS session: {e}")
        return 1

    account_id = get_account_id(session)
    if not account_id:
        log_error("Could not resolve AWS account ID (check credentials)")
        return 1

    log_step("AWS Resource Cleanup Utility")
    log_info(f"Account ID: {account_id}")
    log_info(f"Region: {args.region}")
    log_info(f"Environment: {args.environment}")
    if args.container_type:
        log_info(f"Container System: {args.container_type}")
    log_info(f"ECR retention: {args.ecr_retention_days} days, keep {args.keep_images} most recent")
    log_info("Mode: DRY-RUN (no deletes)" if (args.dry_run or not args.force) else "Mode: FORCE DELETE")
    log_info("")

    failed = False
    if not cleanup_s3_buckets(
        session, account_id, args.environment, args.profile, args.region, args.dry_run, args.force
    ):
        failed = True
    if not cleanup_ecr_images(
        session, args.profile, args.region, args.dry_run, args.force,
        args.ecr_retention_days, args.keep_images,
    ):
        failed = True
    if args.container_type == "ecs":
        if not cleanup_ecs_resources(session, args.environment, args.region, args.dry_run, args.force):
            failed = True
    elif args.container_type == "eks":
        if not cleanup_eks_resources(session, args.environment, args.region):
            failed = True

    log_step("Final Summary")
    if args.dry_run or not args.force:
        log_info("DRY-RUN - no resources were deleted. Use --force to delete.")
    else:
        log_info("Cleanup completed.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
