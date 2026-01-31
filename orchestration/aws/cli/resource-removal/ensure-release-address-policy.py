#!/usr/bin/env python3
"""
Attach an IAM inline policy to the current caller (user or role) allowing
ec2:ReleaseAddress and ec2:DescribeAddresses so the removal script can release
Elastic IPs that fail with AuthFailure.

Usage:
  python3 ensure-release-address-policy.py [--profile PROFILE] [--dry-run]

Requires: boto3 (pip install boto3)
"""
import json
import sys

try:
    import boto3
    from botocore.exceptions import ClientError
except ImportError:
    print("Error: boto3 required. pip install boto3", file=sys.stderr)
    sys.exit(1)

POLICY_NAME = "AllowReleaseAddress"
POLICY_DOC = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": ["ec2:ReleaseAddress", "ec2:DescribeAddresses"],
            "Resource": "*",
        }
    ],
}


def main() -> None:
    import argparse
    parser = argparse.ArgumentParser(description="Attach IAM policy for ec2:ReleaseAddress")
    parser.add_argument("--profile", default="admin", help="AWS profile")
    parser.add_argument("--dry-run", action="store_true", help="Print what would be done")
    args = parser.parse_args()

    session = boto3.Session(profile_name=args.profile)
    sts = session.client("sts")
    iam = session.client("iam")

    try:
        identity = sts.get_caller_identity()
    except ClientError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    arn = identity.get("Arn", "")
    account = identity.get("Account", "")

    if ":user/" in arn:
        # IAM User: arn:aws:iam::ACCOUNT:user/UserName
        user_name = arn.split("/")[-1]
        if args.dry_run:
            print(f"Would attach inline policy '{POLICY_NAME}' to IAM user: {user_name}", file=sys.stderr)
            sys.exit(0)
        try:
            iam.put_user_policy(
                UserName=user_name,
                PolicyName=POLICY_NAME,
                PolicyDocument=json.dumps(POLICY_DOC),
            )
            print(f"Attached policy '{POLICY_NAME}' to user {user_name}", file=sys.stderr)
        except ClientError as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)
    elif ":assumed-role/" in arn or ":role/" in arn:
        # Assumed role: arn:aws:sts::ACCOUNT:assumed-role/RoleName/session
        # Or direct role: arn:aws:iam::ACCOUNT:role/RoleName
        role_name = arn.split("/")[-2] if "/" in arn else arn.split(":")[-1]
        if args.dry_run:
            print(f"Would attach inline policy '{POLICY_NAME}' to IAM role: {role_name}", file=sys.stderr)
            sys.exit(0)
        try:
            iam.put_role_policy(
                RoleName=role_name,
                PolicyName=POLICY_NAME,
                PolicyDocument=json.dumps(POLICY_DOC),
            )
            print(f"Attached policy '{POLICY_NAME}' to role {role_name}", file=sys.stderr)
        except ClientError as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        print(f"Unsupported caller type: {arn}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
