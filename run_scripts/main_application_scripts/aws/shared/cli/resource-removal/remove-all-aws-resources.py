#!/usr/bin/env python3
"""
Brutal-force removal of all AWS resources listed in find-all-current-aws-resources
result JSON. Uses boto3. Preserves Secrets Manager; optionally preserves S3 state bucket.
Writes removal results to results/ (deleted, failed, skipped per step).
"""
import json
import os
import sys
import time
from datetime import datetime
from typing import Any, Dict, List, Optional

try:
    import boto3
    from botocore.exceptions import ClientError
except ImportError:
    print("Error: boto3 is required. pip install boto3", file=sys.stderr)
    sys.exit(1)


# ANSI colors (only when stderr is a TTY)
def _color(s: str, code: str) -> str:
    if hasattr(sys.stderr, "isatty") and sys.stderr.isatty():
        return f"\033[{code}m{s}\033[0m"
    return s


def _green(s: str) -> str:
    return _color(s, "32")


def _red(s: str) -> str:
    return _color(s, "31")


def _yellow(s: str) -> str:
    return _color(s, "33")


def _progress(msg: str) -> None:
    """Print a progress line to stderr (visible to user)."""
    print(f"  {msg}", file=sys.stderr, flush=True)


def _print_status(resource_id: str, status: str, detail: Optional[str] = None) -> None:
    """Print per-resource outcome: success (green), failed (red), skipped (yellow)."""
    if status == "success":
        print(f"  {resource_id}: {_green('success')}", file=sys.stderr, flush=True)
    elif status == "failed":
        line = f"  {resource_id}: {_red('failed')}"
        if detail:
            line += f" — {detail}"
        print(line, file=sys.stderr, flush=True)
    else:
        # skipped (already_deleted, dry_run, etc.)
        line = f"  {resource_id}: {_yellow('skipped')}"
        if detail:
            line += f" ({detail})"
        print(line, file=sys.stderr, flush=True)


# Timeouts (minutes) for long-running deletions; shown at start of each component
TIMEOUT_CLOUDFRONT_DEPLOY_MIN = 20
TIMEOUT_EKS_DELETE_MIN = 15
TIMEOUT_ECS_DELETE_MIN = 10
TIMEOUT_RDS_DELETE_MIN = 10

# Error codes that mean "resource already gone" -> idempotent success (skip, not fail)
IDEMPOTENT_ERROR_CODES = frozenset({
    "NoSuchDistribution", "ResourceNotFoundException", "ClusterNotFoundException",
    "DBClusterNotFoundFault", "DBInstanceNotFoundFault", "NoSuchBucket",
    "NoSuchEntity", "InvalidGroup.NotFound", "InvalidVpcID.NotFound",
    "InvalidSubnetID.NotFound", "InvalidSecurityGroupID.NotFound", "InvalidInternetGatewayID.NotFound",
    "InvalidNatGatewayID.NotFound", "InvalidAddress.NotFound", "InvalidParameterValue",
    "LoadBalancerNotFound", "RepositoryNotFoundException", "NoSuchLoadBalancer",
    "InvalidNetworkInterfaceID.NotFound", "InvalidVpcEndpointId.NotFound",
})


def _is_idempotent_success(e: ClientError) -> bool:
    """True if error means resource is already gone (safe to treat as success/skip)."""
    code = (e.response or {}).get("Error", {}).get("Code", "")
    msg = (e.response or {}).get("Error", {}).get("Message", "")
    if code in IDEMPOTENT_ERROR_CODES:
        return True
    if "not found" in (msg or "").lower() or "does not exist" in (msg or "").lower():
        return True
    return False


def _wait_with_heartbeat(
    description: str,
    check_fn,
    timeout_sec: int,
    interval_sec: int = 60,
) -> bool:
    """Wait until check_fn() returns True or timeout. Print heartbeat every interval_sec. Returns True if done."""
    timeout_min = timeout_sec // 60
    print(f"  Waiting for {description} (timeout: {timeout_min} min)...", file=sys.stderr)
    start = time.monotonic()
    last_heartbeat = 0
    while True:
        try:
            if check_fn():
                return True
        except Exception:
            pass
        elapsed = int(time.monotonic() - start)
        if elapsed >= timeout_sec:
            print(f"  Timeout after {timeout_min} min.", file=sys.stderr)
            return False
        if elapsed - last_heartbeat >= interval_sec:
            mins = elapsed // 60
            print(f"  ... have waited for {description} - {mins} min", file=sys.stderr)
            last_heartbeat = elapsed
        time.sleep(min(interval_sec, timeout_sec - elapsed))


def _log_timeout(component: str, resource_id: str, timeout_min: int) -> None:
    """Print timeout at start of deletion for a component (DRY)."""
    print(f"  {component} {resource_id}: timeout {timeout_min} min", file=sys.stderr)


def _get_results(data: dict, *keys: str, default: Optional[list] = None) -> List[dict]:
    """Get nested list from data['results'][key1][key2]...; return [] if missing."""
    default = default if default is not None else []
    try:
        node = data.get("results") or {}
        for k in keys:
            node = node.get(k) or {}
        return node if isinstance(node, list) else default
    except Exception:
        return default


def _step_result() -> Dict[str, List[Any]]:
    return {"deleted": [], "failed": [], "skipped": []}


def _handle_delete_error(e: ClientError, rid: str, out: Dict[str, List[Any]]) -> str:
    """On delete failure: add to skipped if idempotent, else failed. Returns 'skipped' or 'failed'."""
    if _is_idempotent_success(e):
        out["skipped"].append({"id": rid, "reason": "already_deleted"})
        return "skipped"
    out["failed"].append({"id": rid, "error": str(e)})
    return "failed"


def _run_step(
    dry_run: bool,
    step_name: str,
    items: List[Any],
    delete_fn,
    get_id_fn,
    *args,
    **kwargs,
) -> Dict[str, List[Any]]:
    out = _step_result()
    for item in items:
        rid = get_id_fn(item)
        if not rid:
            continue
        if dry_run:
            out["skipped"].append({"id": rid, "reason": "dry_run"})
            continue
        try:
            delete_fn(item, *args, **kwargs)
            out["deleted"].append(rid)
        except ClientError as e:
            out["failed"].append({"id": rid, "error": str(e)})
        except Exception as e:
            out["failed"].append({"id": rid, "error": str(e)})
    return out


# --- Step 1: CloudFront ---
def _delete_cloudfront(data: dict, session: boto3.Session, dry_run: bool) -> Dict:
    out = _step_result()
    dists = _get_results(data, "cloudfront", "distributions")
    cf = session.client("cloudfront", region_name="us-east-1")
    timeout_sec = TIMEOUT_CLOUDFRONT_DEPLOY_MIN * 60
    for d in dists:
        dist_id = d.get("id")
        if not dist_id:
            continue
        if dry_run:
            out["skipped"].append({"id": dist_id, "reason": "dry_run"})
            _print_status(dist_id, "skipped", "dry_run")
            continue
        _progress(f"Deleting CloudFront {dist_id}...")
        _log_timeout("CloudFront", dist_id, TIMEOUT_CLOUDFRONT_DEPLOY_MIN)
        try:
            cfg = cf.get_distribution_config(Id=dist_id)
            etag = cfg["ETag"]
            config = cfg["DistributionConfig"]
            if config.get("Enabled", True):
                _progress("Disabling distribution...")
                config["Enabled"] = False
                cf.update_distribution(Id=dist_id, IfMatch=etag, DistributionConfig=config)
                done = _wait_with_heartbeat(
                    f"CloudFront {dist_id} to deploy (disabled)",
                    lambda c=cf, i=dist_id: c.get_distribution(Id=i)["Distribution"]["Status"] == "Deployed",
                    timeout_sec,
                )
                if not done:
                    out["failed"].append({"id": dist_id, "error": "timeout waiting for disable"})
                    _print_status(dist_id, "failed", "timeout waiting for disable")
                    continue
            _progress("Deleting distribution...")
            etag2 = cf.get_distribution(Id=dist_id)["ETag"]
            cf.delete_distribution(Id=dist_id, IfMatch=etag2)
            out["deleted"].append(dist_id)
            _print_status(dist_id, "success")
        except ClientError as e:
            kind = _handle_delete_error(e, dist_id, out)
            _print_status(dist_id, kind, "already_deleted" if kind == "skipped" else str(e))
    return out


def _check_eks_gone(eks_client, cluster_name: str) -> bool:
    try:
        eks_client.describe_cluster(name=cluster_name)
        return False
    except ClientError as e:
        return _is_idempotent_success(e)

# --- Step 2: EKS ---
def _delete_eks(data: dict, session: boto3.Session, region: str, dry_run: bool) -> Dict:
    out = _step_result()
    clusters = _get_results(data, "eks", "clusters")
    eks = session.client("eks", region_name=region)
    timeout_sec = TIMEOUT_EKS_DELETE_MIN * 60
    for c in clusters:
        name = c.get("name")
        if not name:
            continue
        if dry_run:
            out["skipped"].append({"id": name, "reason": "dry_run"})
            _print_status(name, "skipped", "dry_run")
            continue
        _progress(f"Deleting EKS cluster {name}...")
        _log_timeout("EKS cluster", name, TIMEOUT_EKS_DELETE_MIN)
        try:
            _progress("Removing Fargate profiles and node groups...")
            for fp in (eks.list_fargate_profiles(clusterName=name).get("fargateProfileNames") or []):
                try:
                    eks.delete_fargate_profile(clusterName=name, fargateProfileName=fp)
                except ClientError:
                    pass
            for ng in (eks.list_nodegroups(clusterName=name).get("nodegroups") or []):
                try:
                    eks.delete_nodegroup(clusterName=name, nodegroupName=ng)
                except ClientError:
                    pass
            time.sleep(30)
            _progress("Deleting cluster...")
            eks.delete_cluster(name=name)
            _wait_with_heartbeat(
                f"EKS cluster {name} to be deleted",
                lambda e=eks, n=name: _check_eks_gone(e, n),
                timeout_sec,
            )
            out["deleted"].append(name)
            _print_status(name, "success")
        except ClientError as e:
            kind = _handle_delete_error(e, name, out)
            _print_status(name, kind, "already_deleted" if kind == "skipped" else str(e))
    return out


def _check_ecs_gone(ecs_client, cluster_name: str) -> bool:
    try:
        cs = (ecs_client.describe_clusters(clusters=[cluster_name]).get("clusters") or [])
        if not cs:
            return True
        return cs[0].get("status") == "INACTIVE"
    except ClientError as e:
        return _is_idempotent_success(e)

# --- Step 3: ECS ---
def _delete_ecs(data: dict, session: boto3.Session, region: str, dry_run: bool) -> Dict:
    out = _step_result()
    clusters = _get_results(data, "ecs", "clusters")
    ecs = session.client("ecs", region_name=region)
    timeout_sec = TIMEOUT_ECS_DELETE_MIN * 60
    for c in clusters:
        name = c.get("name")
        if not name:
            continue
        if dry_run:
            out["skipped"].append({"id": name, "reason": "dry_run"})
            _print_status(name, "skipped", "dry_run")
            continue
        _progress(f"Deleting ECS cluster {name}...")
        _log_timeout("ECS cluster", name, TIMEOUT_ECS_DELETE_MIN)
        try:
            _progress("Stopping and deleting services...")
            for arn in (ecs.list_services(cluster=name).get("serviceArns") or []):
                svc = arn.split("/")[-1]
                try:
                    ecs.update_service(cluster=name, service=svc, desiredCount=0)
                    ecs.delete_service(cluster=name, service=svc, force=True)
                except ClientError:
                    pass
            time.sleep(5)
            _progress("Deleting cluster...")
            ecs.delete_cluster(cluster=name)
            _wait_with_heartbeat(
                f"ECS cluster {name} to be deleted",
                lambda e=ecs, n=name: _check_ecs_gone(e, n),
                timeout_sec,
            )
            out["deleted"].append(name)
            _print_status(name, "success")
        except ClientError as e:
            kind = _handle_delete_error(e, name, out)
            _print_status(name, kind, "already_deleted" if kind == "skipped" else str(e))
    return out


def _check_rds_gone(rds_client, cluster_id: str) -> bool:
    try:
        rds_client.describe_db_clusters(DBClusterIdentifier=cluster_id)
        return False
    except ClientError as e:
        return _is_idempotent_success(e)

# --- Step 4: RDS Aurora ---
def _delete_rds(data: dict, session: boto3.Session, region: str, dry_run: bool) -> Dict:
    out = _step_result()
    clusters = _get_results(data, "rds", "aurora_clusters")
    rds = session.client("rds", region_name=region)
    timeout_sec = TIMEOUT_RDS_DELETE_MIN * 60
    for cl in clusters:
        cid = cl.get("id")
        if not cid:
            continue
        if dry_run:
            out["skipped"].append({"id": cid, "reason": "dry_run"})
            _print_status(cid, "skipped", "dry_run")
            continue
        _progress(f"Deleting RDS cluster {cid}...")
        _log_timeout("RDS cluster", cid, TIMEOUT_RDS_DELETE_MIN)
        try:
            _progress("Deleting instances and cluster...")
            inst_resp = rds.describe_db_instances(
                Filters=[{"Name": "db-cluster-id", "Values": [cid]}]
            )
            for inst in (inst_resp.get("DBInstances") or []):
                try:
                    rds.delete_db_instance(
                        DBInstanceIdentifier=inst["DBInstanceIdentifier"],
                        SkipFinalSnapshot=True,
                    )
                except ClientError:
                    pass
            rds.delete_db_cluster(DBClusterIdentifier=cid, SkipFinalSnapshot=True)
            _wait_with_heartbeat(
                f"RDS cluster {cid} to be deleted",
                lambda r=rds, i=cid: _check_rds_gone(r, i),
                timeout_sec,
            )
            out["deleted"].append(cid)
            _print_status(cid, "success")
        except ClientError as e:
            kind = _handle_delete_error(e, cid, out)
            _print_status(cid, kind, "already_deleted" if kind == "skipped" else str(e))
    return out


# --- Step 5: Load balancers ---
def _delete_elb(data: dict, session: boto3.Session, region: str, dry_run: bool) -> Dict:
    out = _step_result()
    lbs = _get_results(data, "elb", "load_balancers")
    elbv2 = session.client("elbv2", region_name=region)
    for lb in lbs:
        name = lb.get("name")
        if not name:
            continue
        if dry_run:
            out["skipped"].append({"id": name, "reason": "dry_run"})
            _print_status(name, "skipped", "dry_run")
            continue
        _progress(f"Deleting load balancer {name}...")
        try:
            resp = elbv2.describe_load_balancers(Names=[name])
            for l in resp.get("LoadBalancers") or []:
                elbv2.delete_load_balancer(LoadBalancerArn=l["LoadBalancerArn"])
            out["deleted"].append(name)
            _print_status(name, "success")
        except ClientError as e:
            kind = _handle_delete_error(e, name, out)
            _print_status(name, kind, "already_deleted" if kind == "skipped" else str(e))
    return out


# --- Step 6: EC2 instances ---
def _delete_ec2_instances(data: dict, session: boto3.Session, region: str, dry_run: bool) -> Dict:
    out = _step_result()
    instances = [i for i in _get_results(data, "ec2", "instances") if i.get("state") != "terminated"]
    ec2 = session.client("ec2", region_name=region)
    for i in instances:
        iid = i.get("id")
        if not iid:
            continue
        if dry_run:
            out["skipped"].append({"id": iid, "reason": "dry_run"})
            _print_status(iid, "skipped", "dry_run")
            continue
        _progress(f"Terminating instance {iid}...")
        try:
            ec2.terminate_instances(InstanceIds=[iid])
            out["deleted"].append(iid)
            _print_status(iid, "success")
        except ClientError as e:
            kind = _handle_delete_error(e, iid, out)
            _print_status(iid, kind, "already_deleted" if kind == "skipped" else str(e))
    return out


# --- Step 7: NAT gateways ---
def _delete_nat(data: dict, session: boto3.Session, region: str, dry_run: bool) -> Dict:
    out = _step_result()
    nats = [n for n in _get_results(data, "ec2", "nat_gateways") if n.get("state") == "available"]
    ec2 = session.client("ec2", region_name=region)
    for n in nats:
        nid = n.get("id")
        if not nid:
            continue
        if dry_run:
            out["skipped"].append({"id": nid, "reason": "dry_run"})
            _print_status(nid, "skipped", "dry_run")
            continue
        _progress(f"Deleting NAT gateway {nid}...")
        try:
            ec2.delete_nat_gateway(NatGatewayId=nid)
            out["deleted"].append(nid)
            _print_status(nid, "success")
        except ClientError as ex:
            kind = _handle_delete_error(ex, nid, out)
            _print_status(nid, kind, "already_deleted" if kind == "skipped" else str(ex))
    if not dry_run and nats:
        time.sleep(30)
    return out


# --- Step 8: Elastic IPs ---
def _delete_eip(data: dict, session: boto3.Session, region: str, dry_run: bool) -> Dict:
    out = _step_result()
    eips = _get_results(data, "ec2", "elastic_ips")
    ec2 = session.client("ec2", region_name=region)
    for e in eips:
        alloc = e.get("allocation_id")
        if not alloc:
            continue
        if dry_run:
            out["skipped"].append({"id": alloc, "reason": "dry_run"})
            _print_status(alloc, "skipped", "dry_run")
            continue
        _progress(f"Releasing Elastic IP {alloc}...")
        try:
            ec2.release_address(AllocationId=alloc)
            out["deleted"].append(alloc)
            _print_status(alloc, "success")
        except ClientError as ex:
            kind = _handle_delete_error(ex, alloc, out)
            _print_status(alloc, kind, "already_deleted" if kind == "skipped" else str(ex))
    return out


# --- Step 9: Internet gateways ---
def _delete_igw(data: dict, session: boto3.Session, region: str, dry_run: bool) -> Dict:
    out = _step_result()
    igws = _get_results(data, "ec2", "internet_gateways")
    ec2 = session.client("ec2", region_name=region)
    for ig in igws:
        igw_id = ig.get("id")
        if not igw_id:
            continue
        if dry_run:
            out["skipped"].append({"id": igw_id, "reason": "dry_run"})
            _print_status(igw_id, "skipped", "dry_run")
            continue
        _progress(f"Deleting internet gateway {igw_id}...")
        try:
            desc = ec2.describe_internet_gateways(InternetGatewayIds=[igw_id])
            for att in (desc.get("InternetGateways") or [{}])[0].get("Attachments") or []:
                ec2.detach_internet_gateway(
                    InternetGatewayId=igw_id,
                    VpcId=att["VpcId"],
                )
            ec2.delete_internet_gateway(InternetGatewayId=igw_id)
            out["deleted"].append(igw_id)
            _print_status(igw_id, "success")
        except ClientError as e:
            kind = _handle_delete_error(e, igw_id, out)
            _print_status(igw_id, kind, "already_deleted" if kind == "skipped" else str(e))
    return out


# --- Step 10: Network interfaces (ENIs) — must run before subnets/SGs/VPCs ---
def _delete_enis(data: dict, session: boto3.Session, region: str, dry_run: bool) -> Dict:
    """Delete ENIs in VPCs from the result. Removing ENIs unblocks subnet, SG, and VPC deletion."""
    out = _step_result()
    vpcs = _get_results(data, "ec2", "vpcs")
    vpc_ids = [v.get("id") for v in vpcs if v.get("id")]
    if not vpc_ids:
        return out
    ec2 = session.client("ec2", region_name=region)
    for vpc_id in vpc_ids:
        try:
            resp = ec2.describe_network_interfaces(
                Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
            )
        except ClientError as e:
            if _is_idempotent_success(e):
                continue
            out["failed"].append({"id": vpc_id, "error": f"list ENIs: {e}"})
            continue
        for eni in resp.get("NetworkInterfaces") or []:
            eni_id = eni.get("NetworkInterfaceId")
            if not eni_id:
                continue
            if dry_run:
                out["skipped"].append({"id": eni_id, "reason": "dry_run"})
                _print_status(eni_id, "skipped", "dry_run")
                continue
            _progress(f"Deleting ENI {eni_id} (VPC {vpc_id})...")
            try:
                attachment = eni.get("Attachment") or {}
                attachment_id = attachment.get("AttachmentId", "")
                instance_owner = attachment.get("InstanceOwnerId", "")
                attachment_status = attachment.get("Status", "")
                
                # ELB attachments (AttachmentId starts with "ela-attach-" or InstanceOwnerId == "amazon-aws")
                # cannot be manually detached; AWS manages them. Try direct deletion.
                is_elb_attachment = (
                    attachment_id.startswith("ela-attach-") or
                    instance_owner == "amazon-aws" or
                    instance_owner == "amazon-elb"
                )
                
                if attachment_id and attachment_status in ("attached", "attaching"):
                    if is_elb_attachment:
                        _progress("ENI has ELB attachment (managed by AWS), attempting direct deletion...")
                        # ELB attachments are cleaned up automatically when LB is deleted
                        # Wait a moment for cleanup, then try deletion
                        time.sleep(5)
                    else:
                        _progress("Detaching ENI...")
                        try:
                            ec2.detach_network_interface(
                                AttachmentId=attachment_id,
                                Force=True,
                            )
                            time.sleep(2)
                        except ClientError as detach_e:
                            # If detach fails with OperationNotPermitted for ELB, try direct delete
                            if "OperationNotPermitted" in str(detach_e) and ("ela" in str(detach_e).lower() or "amazon-aws" in str(detach_e)):
                                _progress("Cannot detach ELB attachment, trying direct deletion...")
                                time.sleep(5)
                            elif not _is_idempotent_success(detach_e):
                                raise
                # Try to delete ENI
                try:
                    ec2.delete_network_interface(NetworkInterfaceId=eni_id)
                    out["deleted"].append(eni_id)
                    _print_status(eni_id, "success")
                except ClientError as delete_e:
                    # If deletion fails due to ELB attachment still present, wait and retry with backoff
                    error_code = (delete_e.response or {}).get("Error", {}).get("Code", "")
                    error_msg = str(delete_e).lower()
                    is_elb_blocking = (
                        "OperationNotPermitted" in error_code or
                        "InvalidParameterValue" in error_code or
                        ("ela" in error_msg or "amazon-aws" in error_msg or "attachment" in error_msg)
                    )
                    
                    if is_elb_blocking and is_elb_attachment:
                        # ELB cleanup can take 5-10 minutes after LB deletion (AWS managed)
                        _progress("ELB attachment cleanup pending, waiting up to 5 min...")
                        max_wait = 300  # 5 minutes
                        waited = 0
                        deleted = False
                        while waited < max_wait and not deleted:
                            time.sleep(15)
                            waited += 15
                            try:
                                # Check if ENI still exists and if attachment is gone
                                desc = ec2.describe_network_interfaces(NetworkInterfaceIds=[eni_id])
                                eni_data = desc.get("NetworkInterfaces", [{}])[0]
                                attachment = eni_data.get("Attachment") or {}
                                attachment_status = attachment.get("Status", "")
                                
                                # If no attachment or attachment is detached, we can delete
                                if not attachment.get("AttachmentId") or attachment_status in ("detached", "detaching"):
                                    ec2.delete_network_interface(NetworkInterfaceId=eni_id)
                                    out["deleted"].append(eni_id)
                                    _print_status(eni_id, "success")
                                    deleted = True
                                elif waited % 30 == 0:  # Print progress every 30s
                                    _progress(f"Still waiting for ELB cleanup... ({waited}s, attachment: {attachment_status})")
                            except ClientError as check_e:
                                if _is_idempotent_success(check_e):
                                    # ENI already gone
                                    out["skipped"].append({"id": eni_id, "reason": "already_deleted"})
                                    _print_status(eni_id, "skipped", "already_deleted")
                                    deleted = True
                                    break
                                # If still attached, continue waiting
                                if waited % 30 == 0:
                                    _progress(f"Still waiting for ELB cleanup... ({waited}s)")
                        
                        if not deleted:
                            # ELB ENIs are managed by AWS and will be cleaned up automatically (can take 10-15 min)
                            out["skipped"].append({"id": eni_id, "reason": "pending_aws_elb_cleanup"})
                            _print_status(eni_id, "skipped", "pending_aws_elb_cleanup (will auto-cleanup in ~10-15 min)")
                    else:
                        kind = _handle_delete_error(delete_e, eni_id, out)
                        _print_status(eni_id, kind, "already_deleted" if kind == "skipped" else str(delete_e))
            except ClientError as e:
                kind = _handle_delete_error(e, eni_id, out)
                _print_status(eni_id, kind, "already_deleted" if kind == "skipped" else str(e))
    return out


# --- Step 11: Subnets ---
def _delete_subnets(data: dict, session: boto3.Session, region: str, dry_run: bool) -> Dict:
    out = _step_result()
    subnets = _get_results(data, "ec2", "subnets")
    ec2 = session.client("ec2", region_name=region)
    for s in subnets:
        sid = s.get("id")
        if not sid:
            continue
        if dry_run:
            out["skipped"].append({"id": sid, "reason": "dry_run"})
            _print_status(sid, "skipped", "dry_run")
            continue
        _progress(f"Deleting subnet {sid}...")
        try:
            ec2.delete_subnet(SubnetId=sid)
            out["deleted"].append(sid)
            _print_status(sid, "success")
        except ClientError as e:
            kind = _handle_delete_error(e, sid, out)
            _print_status(sid, kind, "already_deleted" if kind == "skipped" else str(e))
    return out


# --- Step 12: Security groups ---
def _delete_sgs(data: dict, session: boto3.Session, region: str, dry_run: bool) -> Dict:
    out = _step_result()
    sgs = _get_results(data, "ec2", "security_groups")
    ec2 = session.client("ec2", region_name=region)
    for sg in sgs:
        sgid = sg.get("id")
        if not sgid:
            continue
        if dry_run:
            out["skipped"].append({"id": sgid, "reason": "dry_run"})
            _print_status(sgid, "skipped", "dry_run")
            continue
        _progress(f"Deleting security group {sgid}...")
        try:
            ec2.delete_security_group(GroupId=sgid)
            out["deleted"].append(sgid)
            _print_status(sgid, "success")
        except ClientError as e:
            kind = _handle_delete_error(e, sgid, out)
            _print_status(sgid, kind, "already_deleted" if kind == "skipped" else str(e))
    return out


# --- Step 13: VPC Endpoints ---
def _delete_vpc_endpoints(data: dict, session: boto3.Session, region: str, dry_run: bool) -> Dict:
    """Delete VPC endpoints before VPC deletion (VPC endpoints block VPC deletion)."""
    out = _step_result()
    vpces = _get_results(data, "ec2", "vpc_endpoints")
    ec2 = session.client("ec2", region_name=region)
    for vpce in vpces:
        vpce_id = vpce.get("id")
        if not vpce_id:
            continue
        if dry_run:
            out["skipped"].append({"id": vpce_id, "reason": "dry_run"})
            _print_status(vpce_id, "skipped", "dry_run")
            continue
        _progress(f"Deleting VPC endpoint {vpce_id}...")
        try:
            ec2.delete_vpc_endpoints(VpcEndpointIds=[vpce_id])
            out["deleted"].append(vpce_id)
            _print_status(vpce_id, "success")
        except ClientError as e:
            kind = _handle_delete_error(e, vpce_id, out)
            _print_status(vpce_id, kind, "already_deleted" if kind == "skipped" else str(e))
    return out


# --- Step 14: VPCs ---
def _delete_vpcs(data: dict, session: boto3.Session, region: str, dry_run: bool) -> Dict:
    out = _step_result()
    vpcs = _get_results(data, "ec2", "vpcs")
    ec2 = session.client("ec2", region_name=region)
    for v in vpcs:
        vpc_id = v.get("id")
        if not vpc_id:
            continue
        if dry_run:
            out["skipped"].append({"id": vpc_id, "reason": "dry_run"})
            _print_status(vpc_id, "skipped", "dry_run")
            continue
        _progress(f"Deleting VPC {vpc_id}...")
        try:
            ec2.delete_vpc(VpcId=vpc_id)
            out["deleted"].append(vpc_id)
            _print_status(vpc_id, "success")
        except ClientError as e:
            kind = _handle_delete_error(e, vpc_id, out)
            _print_status(vpc_id, kind, "already_deleted" if kind == "skipped" else str(e))
    return out


# --- Step 14: ECR ---
def _delete_ecr(data: dict, session: boto3.Session, region: str, dry_run: bool) -> Dict:
    out = _step_result()
    repos = _get_results(data, "ecr", "repositories")
    ecr = session.client("ecr", region_name=region)
    for r in repos:
        name = r.get("name")
        if not name:
            continue
        if dry_run:
            out["skipped"].append({"id": name, "reason": "dry_run"})
            _print_status(name, "skipped", "dry_run")
            continue
        _progress(f"Deleting ECR repository {name}...")
        try:
            ecr.delete_repository(repositoryName=name, force=True)
            out["deleted"].append(name)
            _print_status(name, "success")
        except ClientError as e:
            kind = _handle_delete_error(e, name, out)
            _print_status(name, kind, "already_deleted" if kind == "skipped" else str(e))
    return out


# --- Step 15: S3 ---
def _delete_s3(
    data: dict, session: boto3.Session, dry_run: bool, keep_state_bucket: bool
) -> Dict:
    out = _step_result()
    buckets = _get_results(data, "s3", "buckets")
    s3 = session.client("s3")
    for b in buckets:
        name = b.get("name")
        if not name:
            continue
        if keep_state_bucket and "terraform-state" in (name or ""):
            out["skipped"].append({"id": name, "reason": "preserve_state_bucket"})
            _print_status(name, "skipped", "preserve_state_bucket")
            continue
        if dry_run:
            out["skipped"].append({"id": name, "reason": "dry_run"})
            _print_status(name, "skipped", "dry_run")
            continue
        _progress(f"Deleting S3 bucket {name}...")
        try:
            _progress("Emptying bucket...")
            paginator = s3.get_paginator("list_objects_v2")
            for page in paginator.paginate(Bucket=name):
                objs = [{"Key": o["Key"]} for o in (page.get("Contents") or [])]
                if objs:
                    s3.delete_objects(Bucket=name, Delete={"Objects": objs})
            # Versioned buckets: delete all versions and delete markers
            try:
                ver_pag = s3.get_paginator("list_object_versions")
                for page in ver_pag.paginate(Bucket=name):
                    objs = [{"Key": o["Key"], "VersionId": o["VersionId"]} for o in (page.get("Versions") or [])]
                    objs += [{"Key": o["Key"], "VersionId": o["VersionId"]} for o in (page.get("DeleteMarkers") or [])]
                    if objs:
                        s3.delete_objects(Bucket=name, Delete={"Objects": objs})
            except ClientError:
                pass
            s3.delete_bucket(Bucket=name)
            out["deleted"].append(name)
            _print_status(name, "success")
        except ClientError as e:
            kind = _handle_delete_error(e, name, out)
            _print_status(name, kind, "already_deleted" if kind == "skipped" else str(e))
    return out


# --- Step 16: IAM policies ---
def _delete_iam(data: dict, session: boto3.Session, dry_run: bool) -> Dict:
    out = _step_result()
    policies = _get_results(data, "iam", "policies")
    iam = session.client("iam")
    for p in policies:
        arn = p.get("arn")
        if not arn:
            continue
        if dry_run:
            out["skipped"].append({"id": arn, "reason": "dry_run"})
            _print_status(arn, "skipped", "dry_run")
            continue
        _progress(f"Deleting IAM policy {arn.split('/')[-1]}...")
        try:
            _progress("Detaching from entities...")
            marker = None
            while True:
                kw = {"PolicyArn": arn}
                if marker:
                    kw["Marker"] = marker
                resp = iam.list_entities_for_policy(**kw)
                for ent in (resp.get("PolicyGroups") or []):
                    try:
                        iam.detach_group_policy(GroupName=ent["GroupName"], PolicyArn=arn)
                    except ClientError:
                        pass
                for ent in (resp.get("PolicyUsers") or []):
                    try:
                        iam.detach_user_policy(UserName=ent["UserName"], PolicyArn=arn)
                    except ClientError:
                        pass
                for ent in (resp.get("PolicyRoles") or []):
                    try:
                        iam.detach_role_policy(RoleName=ent["RoleName"], PolicyArn=arn)
                    except ClientError:
                        pass
                if not resp.get("IsTruncated"):
                    break
                marker = resp.get("Marker")
            _progress("Deleting policy versions and policy...")
            for v in (iam.list_policy_versions(PolicyArn=arn).get("Versions") or []):
                if not v.get("IsDefaultVersion"):
                    try:
                        iam.delete_policy_version(PolicyArn=arn, VersionId=v["VersionId"])
                    except ClientError:
                        pass
            iam.delete_policy(PolicyArn=arn)
            out["deleted"].append(arn)
            _print_status(arn, "success")
        except ClientError as e:
            kind = _handle_delete_error(e, arn, out)
            _print_status(arn, kind, "already_deleted" if kind == "skipped" else str(e))
    return out


def _step_header(step_num: int, total: int, name: str) -> None:
    """Print a clear step header so progress is visible."""
    print("", file=sys.stderr)
    print(f"--- Step {step_num}/{total}: {name} ---", file=sys.stderr, flush=True)


def run_removal(
    data: dict,
    session: boto3.Session,
    region: str,
    dry_run: bool,
    keep_state_bucket: bool,
) -> Dict[str, Dict]:
    """Run all 17 deletion steps in dependency order. Returns step -> {deleted, failed, skipped}."""
    results = {}
    total_steps = 17
    _step_header(1, total_steps, "CloudFront")
    results["cloudfront"] = _delete_cloudfront(data, session, dry_run)
    _step_header(2, total_steps, "EKS")
    results["eks"] = _delete_eks(data, session, region, dry_run)
    _step_header(3, total_steps, "ECS")
    results["ecs"] = _delete_ecs(data, session, region, dry_run)
    _step_header(4, total_steps, "RDS Aurora")
    results["rds"] = _delete_rds(data, session, region, dry_run)
    _step_header(5, total_steps, "Load balancers")
    results["elb"] = _delete_elb(data, session, region, dry_run)
    _step_header(6, total_steps, "EC2 instances")
    results["ec2_instances"] = _delete_ec2_instances(data, session, region, dry_run)
    _step_header(7, total_steps, "NAT gateways")
    results["nat_gateways"] = _delete_nat(data, session, region, dry_run)
    _step_header(8, total_steps, "Elastic IPs")
    results["elastic_ips"] = _delete_eip(data, session, region, dry_run)
    _step_header(9, total_steps, "Internet gateways")
    results["internet_gateways"] = _delete_igw(data, session, region, dry_run)
    _step_header(10, total_steps, "Network interfaces (ENIs)")
    results["network_interfaces"] = _delete_enis(data, session, region, dry_run)
    _step_header(11, total_steps, "Subnets")
    results["subnets"] = _delete_subnets(data, session, region, dry_run)
    _step_header(12, total_steps, "Security groups")
    results["security_groups"] = _delete_sgs(data, session, region, dry_run)
    _step_header(13, total_steps, "VPC Endpoints")
    results["vpc_endpoints"] = _delete_vpc_endpoints(data, session, region, dry_run)
    _step_header(14, total_steps, "VPCs")
    results["vpcs"] = _delete_vpcs(data, session, region, dry_run)
    _step_header(15, total_steps, "ECR")
    results["ecr"] = _delete_ecr(data, session, region, dry_run)
    _step_header(16, total_steps, "S3")
    results["s3"] = _delete_s3(data, session, dry_run, keep_state_bucket)
    _step_header(17, total_steps, "IAM policies")
    results["iam"] = _delete_iam(data, session, dry_run)
    return results


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(
        description="Brutal-force remove AWS resources from find-all-current-aws-resources result JSON."
    )
    parser.add_argument("--result-json", required=True, help="Path to result JSON from find-all script")
    parser.add_argument("--profile", default="admin", help="AWS profile")
    parser.add_argument("--region", default="us-east-1", help="AWS region")
    parser.add_argument("--dry-run", action="store_true", help="Do not delete, only report what would be done")
    parser.add_argument("--no-keep-state-bucket", action="store_true", help="Also delete S3 Terraform state bucket")
    args = parser.parse_args()

    result_json = args.result_json
    if not os.path.isfile(result_json):
        print(f"Error: Result JSON not found: {result_json}", file=sys.stderr)
        sys.exit(1)

    with open(result_json) as f:
        data = json.load(f)

    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    keep_state_bucket = not args.no_keep_state_bucket

    print("Brutal-force AWS resource removal", file=sys.stderr)
    print(f"  Result JSON: {result_json}", file=sys.stderr)
    print(f"  Profile: {args.profile}  Region: {args.region}", file=sys.stderr)
    print(f"  Preserved: Secrets Manager; S3 state bucket: {keep_state_bucket}", file=sys.stderr)
    if args.dry_run:
        print("  DRY-RUN: no changes will be made", file=sys.stderr)
    print("", file=sys.stderr)

    step_results = run_removal(data, session, args.region, args.dry_run, keep_state_bucket)

    total_deleted = sum(len(s["deleted"]) for s in step_results.values())
    total_failed = sum(len(s["failed"]) for s in step_results.values())
    total_skipped = sum(len(s["skipped"]) for s in step_results.values())

    output = {
        "metadata": {
            "account_id": data.get("metadata", {}).get("account_id"),
            "profile": args.profile,
            "region": args.region,
            "timestamp": datetime.now().isoformat(),
            "result_json_path": result_json,
            "dry_run": args.dry_run,
            "keep_state_bucket": keep_state_bucket,
        },
        "summary": {
            "total_deleted": total_deleted,
            "total_failed": total_failed,
            "total_skipped": total_skipped,
        },
        "steps": step_results,
    }

    script_dir = os.path.dirname(os.path.abspath(__file__))
    results_dir = os.path.join(script_dir, "results")
    os.makedirs(results_dir, exist_ok=True)
    timestamp = datetime.now().strftime("%y%m%d_%H%M%S")
    out_path = os.path.join(results_dir, f"aws-fru-removal-{timestamp}-result.json")
    with open(out_path, "w") as f:
        json.dump(output, f, indent=2, default=str)

    print("Secrets Manager: preserved (deletion exception).", file=sys.stderr)
    print(f"Removal run complete. Summary: deleted={total_deleted}, failed={total_failed}, skipped={total_skipped}", file=sys.stderr)
    print(f"Results written to: {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
