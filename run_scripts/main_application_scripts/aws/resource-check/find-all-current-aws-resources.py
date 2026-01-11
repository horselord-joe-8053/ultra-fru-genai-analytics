#!/usr/bin/env python3
"""
Find all non-default, non-system AWS resources in the account.
Generates JSON output file with metadata and results.
"""
import json
import subprocess
import sys
import os
from datetime import datetime
from typing import Dict, List, Any, Optional

PROJECT_NAME = "fru"


def run_aws_cmd(cmd_list: List[str], region: Optional[str] = None, profile: str = "admin") -> Any:
    """Run AWS CLI command and return JSON output."""
    full_cmd = ["aws"] + cmd_list + ["--profile", profile, "--output", "json"]
    if region:
        full_cmd.extend(["--region", region])
    try:
        result = subprocess.run(full_cmd, capture_output=True, text=True, timeout=60, check=False)
        if result.returncode == 0 and result.stdout.strip() and result.stdout.strip() != "None":
            return json.loads(result.stdout)
        return None
    except (json.JSONDecodeError, subprocess.TimeoutExpired, Exception) as e:
        return None


def get_account_id(profile: str = "admin") -> Optional[str]:
    """Get AWS account ID."""
    try:
        result = subprocess.run(
            ["aws", "sts", "get-caller-identity", "--profile", profile, "--query", "Account", "--output", "text"],
            capture_output=True, text=True, timeout=10, check=False
        )
        if result.returncode == 0:
            return result.stdout.strip()
        return None
    except Exception:
        return None


def get_regions(profile: str = "admin", check_all: bool = False, default_region: str = "us-east-1") -> List[str]:
    """Get list of regions to check."""
    if not check_all:
        return [default_region]
    try:
        result = subprocess.run(
            ["aws", "ec2", "describe-regions", "--profile", profile, "--query", "Regions[].RegionName", "--output", "json"],
            capture_output=True, text=True, timeout=30, check=False
        )
        if result.returncode == 0:
            regions = json.loads(result.stdout)
            return sorted(regions) if isinstance(regions, list) else [default_region]
        return [default_region]
    except Exception:
        return [default_region]


def collect_ec2_resources(region: str, profile: str) -> Dict[str, List[Dict[str, Any]]]:
    """Collect EC2 resources."""
    resources = {
        "instances": [],
        "vpcs": [],
        "subnets": [],
        "security_groups": [],
        "internet_gateways": [],
        "nat_gateways": [],
        "elastic_ips": []
    }
    
    # EC2 Instances
    instances = run_aws_cmd(["ec2", "describe-instances", "--query", "Reservations[].Instances[].[InstanceId,State.Name,InstanceType,LaunchTime]"], region, profile)
    if instances:
        for inst in instances:
            if len(inst) >= 4:
                resources["instances"].append({
                    "region": region,
                    "id": inst[0],
                    "state": inst[1],
                    "type": inst[2],
                    "launch_time": inst[3]
                })
    
    # VPCs (excluding default)
    vpcs = run_aws_cmd(["ec2", "describe-vpcs", "--query", "Vpcs[?IsDefault==`false`].[VpcId,CidrBlock,State]"], region, profile)
    if vpcs:
        for vpc in vpcs:
            if len(vpc) >= 3:
                resources["vpcs"].append({
                    "region": region,
                    "id": vpc[0],
                    "cidr": vpc[1],
                    "state": vpc[2]
                })
    
    # Subnets (excluding default)
    subnets = run_aws_cmd(["ec2", "describe-subnets", "--query", "Subnets[?DefaultForAz==`false`].[SubnetId,VpcId,CidrBlock,AvailabilityZone]"], region, profile)
    if subnets:
        for subnet in subnets:
            if len(subnet) >= 4:
                resources["subnets"].append({
                    "region": region,
                    "id": subnet[0],
                    "vpc_id": subnet[1],
                    "cidr": subnet[2],
                    "availability_zone": subnet[3]
                })
    
    # Security Groups (excluding default)
    sgs = run_aws_cmd(["ec2", "describe-security-groups", "--query", "SecurityGroups[?GroupName!=`default`].[GroupId,GroupName,VpcId]"], region, profile)
    if sgs:
        for sg in sgs:
            if len(sg) >= 3:
                resources["security_groups"].append({
                    "region": region,
                    "id": sg[0],
                    "name": sg[1],
                    "vpc_id": sg[2]
                })
    
    # Internet Gateways
    igws = run_aws_cmd(["ec2", "describe-internet-gateways", "--query", "InternetGateways[].[InternetGatewayId,State]"], region, profile)
    if igws:
        for igw in igws:
            if len(igw) >= 2:
                resources["internet_gateways"].append({
                    "region": region,
                    "id": igw[0],
                    "state": igw[1] if igw[1] else "available"
                })
    
    # NAT Gateways
    nat_gws = run_aws_cmd(["ec2", "describe-nat-gateways", "--query", "NatGateways[].[NatGatewayId,State,VpcId,SubnetId]"], region, profile)
    if nat_gws:
        for nat in nat_gws:
            if len(nat) >= 4:
                resources["nat_gateways"].append({
                    "region": region,
                    "id": nat[0],
                    "state": nat[1],
                    "vpc_id": nat[2],
                    "subnet_id": nat[3]
                })
    
    # Elastic IPs
    eips = run_aws_cmd(["ec2", "describe-addresses", "--query", "Addresses[].[PublicIp,AllocationId,AssociationId,InstanceId]"], region, profile)
    if eips:
        for eip in eips:
            if len(eip) >= 4:
                resources["elastic_ips"].append({
                    "region": region,
                    "public_ip": eip[0],
                    "allocation_id": eip[1],
                    "association_id": eip[2] if eip[2] else None,
                    "instance_id": eip[3] if eip[3] else None
                })
    
    return resources


def collect_s3_resources(profile: str) -> Dict[str, List[Dict[str, Any]]]:
    """Collect S3 resources."""
    resources = {"buckets": []}
    
    buckets = run_aws_cmd(["s3api", "list-buckets", "--query", "Buckets[].[Name,CreationDate]"], None, profile)
    if buckets:
        for bucket in buckets:
            if len(bucket) >= 2:
                resources["buckets"].append({
                    "name": bucket[0],
                    "creation_date": bucket[1]
                })
    
    return resources


def collect_ecs_resources(region: str, profile: str) -> Dict[str, List[Dict[str, Any]]]:
    """Collect ECS resources."""
    resources = {"clusters": [], "task_definitions": []}
    
    # ECS Clusters
    clusters = run_aws_cmd(["ecs", "list-clusters", "--query", "clusterArns[]"], region, profile)
    if clusters:
        for cluster_arn in clusters:
            cluster_name = cluster_arn.split("/")[-1] if "/" in cluster_arn else cluster_arn
            resources["clusters"].append({
                "region": region,
                "name": cluster_name,
                "arn": cluster_arn
            })
    
    # Task Definitions (limit to 20)
    task_defs = run_aws_cmd(["ecs", "list-task-definitions", "--query", "taskDefinitionArns[]"], region, profile)
    if task_defs:
        for task_def_arn in task_defs[:20]:
            task_def_name = task_def_arn.split("/")[-1] if "/" in task_def_arn else task_def_arn
            resources["task_definitions"].append({
                "region": region,
                "name": task_def_name,
                "arn": task_def_arn
            })
    
    return resources


def collect_eks_resources(region: str, profile: str) -> Dict[str, List[Dict[str, Any]]]:
    """Collect EKS resources."""
    resources = {"clusters": []}
    
    clusters = run_aws_cmd(["eks", "list-clusters", "--query", "clusters[]"], region, profile)
    if clusters:
        for cluster_name in clusters:
            resources["clusters"].append({
                "region": region,
                "name": cluster_name
            })
    
    return resources


def collect_rds_resources(region: str, profile: str) -> Dict[str, List[Dict[str, Any]]]:
    """Collect RDS resources."""
    resources = {"instances": [], "aurora_clusters": []}
    
    # RDS Instances
    db_instances = run_aws_cmd(["rds", "describe-db-instances", "--query", "DBInstances[].[DBInstanceIdentifier,Engine,DBInstanceStatus]"], region, profile)
    if db_instances:
        for db in db_instances:
            if len(db) >= 3:
                resources["instances"].append({
                    "region": region,
                    "id": db[0],
                    "engine": db[1],
                    "status": db[2]
                })
    
    # Aurora Clusters
    aurora_clusters = run_aws_cmd(["rds", "describe-db-clusters", "--query", "DBClusters[].[DBClusterIdentifier,Engine,Status]"], region, profile)
    if aurora_clusters:
        for cluster in aurora_clusters:
            if len(cluster) >= 3:
                resources["aurora_clusters"].append({
                    "region": region,
                    "id": cluster[0],
                    "engine": cluster[1],
                    "status": cluster[2]
                })
    
    return resources


def collect_elb_resources(region: str, profile: str) -> Dict[str, List[Dict[str, Any]]]:
    """Collect ELB/ALB resources."""
    resources = {"load_balancers": []}
    
    lbs = run_aws_cmd(["elbv2", "describe-load-balancers", "--query", "LoadBalancers[].[LoadBalancerName,Type,State.Code,DNSName]"], region, profile)
    if lbs:
        for lb in lbs:
            if len(lb) >= 4:
                resources["load_balancers"].append({
                    "region": region,
                    "name": lb[0],
                    "type": lb[1],
                    "state": lb[2],
                    "dns_name": lb[3]
                })
    
    return resources


def collect_lambda_resources(region: str, profile: str) -> Dict[str, List[Dict[str, Any]]]:
    """Collect Lambda resources."""
    resources = {"functions": []}
    
    funcs = run_aws_cmd(["lambda", "list-functions", "--query", "Functions[].[FunctionName,Runtime,LastModified]"], region, profile)
    if funcs:
        for func in funcs:
            if len(func) >= 3:
                resources["functions"].append({
                    "region": region,
                    "name": func[0],
                    "runtime": func[1],
                    "last_modified": func[2]
                })
    
    return resources


def collect_api_gateway_resources(region: str, profile: str) -> Dict[str, List[Dict[str, Any]]]:
    """Collect API Gateway resources."""
    resources = {"rest_apis": []}
    
    apis = run_aws_cmd(["apigateway", "get-rest-apis", "--query", "items[].[name,id,createdDate]"], region, profile)
    if apis:
        for api in apis:
            if len(api) >= 3:
                resources["rest_apis"].append({
                    "region": region,
                    "name": api[0] if api[0] else "unnamed",
                    "id": api[1],
                    "created_date": api[2]
                })
    
    return resources


def collect_cloudfront_resources(profile: str) -> Dict[str, List[Dict[str, Any]]]:
    """Collect CloudFront resources."""
    resources = {"distributions": []}
    
    distributions = run_aws_cmd(["cloudfront", "list-distributions", "--query", "DistributionList.Items[].[Id,Status,DomainName]"], None, profile)
    if distributions:
        for dist in distributions:
            if len(dist) >= 3:
                resources["distributions"].append({
                    "id": dist[0],
                    "status": dist[1],
                    "domain_name": dist[2]
                })
    
    return resources


def collect_ecr_resources(region: str, profile: str) -> Dict[str, List[Dict[str, Any]]]:
    """Collect ECR resources."""
    resources = {"repositories": []}
    
    repos = run_aws_cmd(["ecr", "describe-repositories", "--query", "repositories[].[repositoryName,registryId,repositoryUri]"], region, profile)
    if repos:
        for repo in repos:
            if len(repo) >= 3:
                resources["repositories"].append({
                    "region": region,
                    "name": repo[0],
                    "registry_id": repo[1],
                    "uri": repo[2]
                })
    
    return resources


def collect_iam_resources(profile: str) -> Dict[str, List[Dict[str, Any]]]:
    """Collect IAM resources."""
    resources = {"roles": [], "policies": []}
    
    # Custom Roles (excluding AWS managed)
    roles = run_aws_cmd(["iam", "list-roles", "--query", "Roles[?!contains(Arn, `:aws:`)][RoleName,Arn]"], None, profile)
    if roles:
        for role in roles:
            if len(role) >= 2:
                resources["roles"].append({
                    "name": role[0],
                    "arn": role[1]
                })
    
    # Customer Managed Policies
    policies = run_aws_cmd(["iam", "list-policies", "--scope", "Local", "--query", "Policies[].[PolicyName,Arn]"], None, profile)
    if policies:
        for policy in policies:
            if len(policy) >= 2:
                resources["policies"].append({
                    "name": policy[0],
                    "arn": policy[1]
                })
    
    return resources


def collect_secrets_manager_resources(region: str, profile: str) -> Dict[str, List[Dict[str, Any]]]:
    """Collect Secrets Manager resources."""
    resources = {"secrets": []}
    
    secrets = run_aws_cmd(["secretsmanager", "list-secrets", "--query", "SecretList[].[Name,ARN]"], region, profile)
    if secrets:
        for secret in secrets:
            if len(secret) >= 2:
                resources["secrets"].append({
                    "region": region,
                    "name": secret[0],
                    "arn": secret[1]
                })
    
    return resources


def collect_sqs_resources(region: str, profile: str) -> Dict[str, List[Dict[str, Any]]]:
    """Collect SQS resources."""
    resources = {"queues": []}
    
    queues = run_aws_cmd(["sqs", "list-queues", "--query", "QueueUrls[]"], region, profile)
    if queues:
        for queue_url in queues:
            queue_name = queue_url.split("/")[-1] if "/" in queue_url else queue_url
            resources["queues"].append({
                "region": region,
                "name": queue_name,
                "url": queue_url
            })
    
    return resources


def collect_sns_resources(region: str, profile: str) -> Dict[str, List[Dict[str, Any]]]:
    """Collect SNS resources."""
    resources = {"topics": []}
    
    topics = run_aws_cmd(["sns", "list-topics", "--query", "Topics[].[TopicArn]"], region, profile)
    if topics:
        for topic_arn in topics:
            topic_name = topic_arn.split(":")[-1] if ":" in topic_arn else topic_arn
            resources["topics"].append({
                "region": region,
                "name": topic_name,
                "arn": topic_arn
            })
    
    return resources


def main(profile: str = "admin", region: str = "us-east-1", check_all_regions: bool = False, output_file: str = None):
    """Main function to collect AWS resources and generate JSON output."""
    
    # Get account ID
    account_id = get_account_id(profile)
    if not account_id:
        print(f"Error: Failed to get AWS account ID. Check AWS credentials and profile: {profile}", file=sys.stderr)
        sys.exit(1)
    
    # Get regions
    regions = get_regions(profile, check_all_regions, region)
    
    # Initialize results structure
    results = {
        "ec2": {
            "instances": [],
            "vpcs": [],
            "subnets": [],
            "security_groups": [],
            "internet_gateways": [],
            "nat_gateways": [],
            "elastic_ips": []
        },
        "s3": {"buckets": []},
        "ecs": {"clusters": [], "task_definitions": []},
        "eks": {"clusters": []},
        "rds": {"instances": [], "aurora_clusters": []},
        "elb": {"load_balancers": []},
        "lambda": {"functions": []},
        "api_gateway": {"rest_apis": []},
        "cloudfront": {"distributions": []},
        "ecr": {"repositories": []},
        "iam": {"roles": [], "policies": []},
        "secrets_manager": {"secrets": []},
        "sqs": {"queues": []},
        "sns": {"topics": []}
    }
    
    # Collect resources
    print(f"Collecting resources from {len(regions)} region(s)...", file=sys.stderr)
    
    # Collect region-specific resources
    for reg in regions:
        print(f"  Processing region: {reg}", file=sys.stderr)
        
        # EC2
        ec2_res = collect_ec2_resources(reg, profile)
        results["ec2"]["instances"].extend(ec2_res["instances"])
        results["ec2"]["vpcs"].extend(ec2_res["vpcs"])
        results["ec2"]["subnets"].extend(ec2_res["subnets"])
        results["ec2"]["security_groups"].extend(ec2_res["security_groups"])
        results["ec2"]["internet_gateways"].extend(ec2_res["internet_gateways"])
        results["ec2"]["nat_gateways"].extend(ec2_res["nat_gateways"])
        results["ec2"]["elastic_ips"].extend(ec2_res["elastic_ips"])
        
        # ECS
        ecs_res = collect_ecs_resources(reg, profile)
        results["ecs"]["clusters"].extend(ecs_res["clusters"])
        results["ecs"]["task_definitions"].extend(ecs_res["task_definitions"])
        
        # EKS
        eks_res = collect_eks_resources(reg, profile)
        results["eks"]["clusters"].extend(eks_res["clusters"])
        
        # RDS
        rds_res = collect_rds_resources(reg, profile)
        results["rds"]["instances"].extend(rds_res["instances"])
        results["rds"]["aurora_clusters"].extend(rds_res["aurora_clusters"])
        
        # ELB
        elb_res = collect_elb_resources(reg, profile)
        results["elb"]["load_balancers"].extend(elb_res["load_balancers"])
        
        # Lambda
        lambda_res = collect_lambda_resources(reg, profile)
        results["lambda"]["functions"].extend(lambda_res["functions"])
        
        # API Gateway
        api_res = collect_api_gateway_resources(reg, profile)
        results["api_gateway"]["rest_apis"].extend(api_res["rest_apis"])
        
        # ECR
        ecr_res = collect_ecr_resources(reg, profile)
        results["ecr"]["repositories"].extend(ecr_res["repositories"])
        
        # Secrets Manager
        secrets_res = collect_secrets_manager_resources(reg, profile)
        results["secrets_manager"]["secrets"].extend(secrets_res["secrets"])
        
        # SQS
        sqs_res = collect_sqs_resources(reg, profile)
        results["sqs"]["queues"].extend(sqs_res["queues"])
        
        # SNS
        sns_res = collect_sns_resources(reg, profile)
        results["sns"]["topics"].extend(sns_res["topics"])
    
    # Collect global resources (only once)
    if regions:
        print(f"  Processing global resources...", file=sys.stderr)
        # S3
        s3_res = collect_s3_resources(profile)
        results["s3"]["buckets"] = s3_res["buckets"]
        
        # CloudFront
        cloudfront_res = collect_cloudfront_resources(profile)
        results["cloudfront"]["distributions"] = cloudfront_res["distributions"]
        
        # IAM
        iam_res = collect_iam_resources(profile)
        results["iam"]["roles"] = iam_res["roles"]
        results["iam"]["policies"] = iam_res["policies"]
    
    # Calculate total resources
    total_resources = 0
    for service_resources in results.values():
        for resource_list in service_resources.values():
            total_resources += len(resource_list)
    
    # Build metadata
    metadata = {
        "account_id": account_id,
        "profile": profile,
        "region": "all" if check_all_regions else region,
        "timestamp": datetime.now().isoformat(),
        "total_resources": total_resources
    }
    
    # Build final output
    output = {
        "metadata": metadata,
        "results": results
    }
    
    # Write JSON file
    if output_file:
        os.makedirs(os.path.dirname(output_file), exist_ok=True)
        with open(output_file, 'w') as f:
            json.dump(output, f, indent=2, default=str)
        print(f"JSON output saved to: {output_file}", file=sys.stderr)
        return output_file
    else:
        # Print to stdout
        print(json.dumps(output, indent=2, default=str))
        return None


if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description="Find all non-default, non-system AWS resources in the account")
    parser.add_argument("--profile", default="admin", help="AWS profile to use (default: admin)")
    parser.add_argument("--region", default="us-east-1", help="AWS region to check (default: us-east-1)")
    parser.add_argument("--all-regions", action="store_true", help="Check all regions")
    parser.add_argument("--output", help="Output JSON file path (if not specified, prints to stdout)")
    
    args = parser.parse_args()
    
    output_file = args.output
    if not output_file:
        # Generate default filename with timestamp
        script_dir = os.path.dirname(os.path.abspath(__file__))
        results_dir = os.path.join(script_dir, "results")
        os.makedirs(results_dir, exist_ok=True)
        timestamp = datetime.now().strftime("%y%m%d_%H%M%S")
        output_file = os.path.join(results_dir, f"aws-{PROJECT_NAME}-{timestamp}-result.json")
    
    main(args.profile, args.region, args.all_regions, output_file)

