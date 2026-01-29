#!/usr/bin/env python3
"""
ECR image cleanup utilities for filtering and chunking images for deletion.

This module provides functions to:
- Filter ECR images based on retention policies (age, tags, keep-recent)
- Chunk image IDs into batches for AWS API limits (100 per batch)
- Count images for reporting
"""

import json
import sys
import argparse
import subprocess
from datetime import datetime, timezone, timedelta
from typing import List, Dict, Any, Optional, Tuple


def filter_images_for_deletion(
    images_json: str,
    retention_days: int = 7,
    keep_recent: int = 5
) -> List[Dict[str, str]]:
    """
    Filter ECR images that should be deleted based on retention rules.
    
    Args:
        images_json: JSON string containing imageDetails from describe-images
        retention_days: Keep images newer than this many days
        keep_recent: Always keep N most recent images regardless of age
        
    Returns:
        List of image ID dicts (with imageDigest and/or imageTag)
    """
    try:
        data = json.loads(images_json)
        images = data.get("imageDetails", [])
    except (json.JSONDecodeError, KeyError, TypeError) as e:
        print(f"Error parsing images JSON: {e}", file=sys.stderr)
        return []
    
    if not images:
        return []
    
    # Sort by push date (newest first)
    images_sorted = sorted(
        images,
        key=lambda x: x.get("imagePushedAt", ""),
        reverse=True
    )
    
    cutoff = datetime.now(timezone.utc) - timedelta(days=retention_days)
    image_ids = []
    
    for idx, img in enumerate(images_sorted):
        tags = img.get("imageTags", []) or []
        pushed_at = img.get("imagePushedAt")
        
        # Always keep the N most recent images
        if idx < keep_recent:
            continue
        
        is_untagged = len(tags) == 0
        is_old = False
        
        if pushed_at:
            try:
                dt = datetime.fromisoformat(pushed_at.replace("Z", "+00:00"))
                is_old = dt < cutoff
            except (ValueError, AttributeError):
                pass
        
        # Only delete if untagged OR old
        if not (is_untagged or is_old):
            continue
        
        # Build image identifier
        ident = {}
        digest = img.get("imageDigest")
        if digest:
            ident["imageDigest"] = digest
        if tags:
            ident["imageTag"] = tags[0]
        
        if ident:
            image_ids.append(ident)
    
    return image_ids


def chunk_image_ids(image_ids: List[Dict[str, str]], chunk_size: int = 100) -> List[List[Dict[str, str]]]:
    """
    Split image IDs into chunks for AWS API batch limits.
    
    Args:
        image_ids: List of image ID dicts
        chunk_size: Maximum images per chunk (AWS limit is 100)
        
    Returns:
        List of chunks, each containing up to chunk_size image IDs
    """
    chunks = []
    for i in range(0, len(image_ids), chunk_size):
        chunks.append(image_ids[i:i + chunk_size])
    return chunks


def count_images(images_json: str) -> int:
    """
    Count total images from describe-images JSON.
    
    Args:
        images_json: JSON string containing imageDetails
        
    Returns:
        Number of images
    """
    try:
        data = json.loads(images_json)
        return len(data.get("imageDetails", []))
    except (json.JSONDecodeError, KeyError, TypeError):
        return 0


def describe_images(
    repository_name: str,
    profile: str = "admin",
    region: str = "us-east-1"
) -> Tuple[Optional[str], Optional[str]]:
    """
    Retrieve ECR images using AWS CLI with proper error handling and validation.
    
    Args:
        repository_name: Name of the ECR repository
        profile: AWS profile to use
        region: AWS region
        
    Returns:
        Tuple of (json_output, error_message)
        - json_output: Valid JSON string with imageDetails, or None on failure
        - error_message: Error message if failed, None on success
    """
    cmd = [
        "aws", "ecr", "describe-images",
        "--repository-name", repository_name,
        "--profile", profile,
        "--region", region,
        "--output", "json"
    ]
    
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=60,
            check=False
        )
        
        # Check exit code
        if result.returncode != 0:
            error_msg = result.stderr.strip() if result.stderr else "Unknown AWS CLI error"
            
            # Provide more specific error messages
            if "RepositoryNotFoundException" in error_msg:
                return None, f"Repository '{repository_name}' not found in region {region}"
            elif "AccessDenied" in error_msg or "UnauthorizedOperation" in error_msg:
                return None, f"Access denied. Check AWS credentials and permissions for profile '{profile}'"
            elif "InvalidParameterException" in error_msg:
                return None, f"Invalid parameter: {error_msg}"
            elif "Throttling" in error_msg or "Rate exceeded" in error_msg:
                return None, f"AWS API rate limit exceeded. Please retry later."
            else:
                return None, f"AWS CLI error (exit {result.returncode}): {error_msg}"
        
        # Validate JSON output
        output = result.stdout.strip()
        if not output:
            return None, "AWS CLI returned empty output"
        
        # Try to parse JSON to validate structure
        try:
            data = json.loads(output)
            # Validate expected structure
            if not isinstance(data, dict):
                return None, f"Invalid response format: expected JSON object, got {type(data).__name__}"
            
            # Ensure imageDetails key exists (even if empty)
            if "imageDetails" not in data:
                # Some AWS responses might not have imageDetails if empty, add it
                data["imageDetails"] = []
            
            # Return validated JSON
            return json.dumps(data), None
            
        except json.JSONDecodeError as e:
            return None, f"Invalid JSON response from AWS CLI: {e}. Raw output: {output[:200]}"
            
    except subprocess.TimeoutExpired:
        return None, f"AWS CLI command timed out after 60 seconds"
    except FileNotFoundError:
        return None, "AWS CLI not found. Please install AWS CLI and ensure it's in PATH"
    except Exception as e:
        return None, f"Unexpected error calling AWS CLI: {e}"


def main():
    """CLI entry point for ECR cleanup utilities."""
    parser = argparse.ArgumentParser(
        description="ECR image cleanup utilities",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    subparsers = parser.add_subparsers(dest="command", help="Command to execute")
    
    # Filter command
    filter_parser = subparsers.add_parser("filter", help="Filter images for deletion")
    filter_parser.add_argument(
        "--retention-days",
        type=int,
        default=7,
        help="Keep images newer than this many days (default: 7)"
    )
    filter_parser.add_argument(
        "--keep-recent",
        type=int,
        default=5,
        help="Always keep N most recent images (default: 5)"
    )
    filter_parser.add_argument(
        "--input-json",
        type=str,
        help="JSON input (if not provided, reads from stdin)"
    )
    
    # Chunk command
    chunk_parser = subparsers.add_parser("chunk", help="Chunk image IDs into batches")
    chunk_parser.add_argument(
        "--chunk-size",
        type=int,
        default=100,
        help="Maximum images per chunk (default: 100)"
    )
    chunk_parser.add_argument(
        "--input-json",
        type=str,
        help="JSON input (if not provided, reads from stdin)"
    )
    
    # Count command
    count_parser = subparsers.add_parser("count", help="Count images in JSON")
    count_parser.add_argument(
        "--input-json",
        type=str,
        help="JSON input (if not provided, reads from stdin)"
    )
    
    # Describe-images command
    describe_parser = subparsers.add_parser("describe-images", help="Retrieve ECR images via AWS CLI")
    describe_parser.add_argument(
        "--repository-name",
        type=str,
        required=True,
        help="ECR repository name"
    )
    describe_parser.add_argument(
        "--profile",
        type=str,
        default="admin",
        help="AWS profile (default: admin)"
    )
    describe_parser.add_argument(
        "--region",
        type=str,
        default="us-east-1",
        help="AWS region (default: us-east-1)"
    )
    
    args = parser.parse_args()
    
    if not args.command:
        parser.print_help()
        sys.exit(1)
    
    try:
        if args.command == "filter":
            # Read input
            if args.input_json:
                input_data = args.input_json
            else:
                input_data = sys.stdin.read()
            
            # Filter images
            image_ids = filter_images_for_deletion(
                input_data,
                retention_days=args.retention_days,
                keep_recent=args.keep_recent
            )
            
            # Output JSON to stdout
            print(json.dumps(image_ids))
            
        elif args.command == "chunk":
            # Read input
            if args.input_json:
                input_data = args.input_json
            else:
                input_data = sys.stdin.read()
            
            # Parse image IDs
            try:
                image_ids = json.loads(input_data)
            except json.JSONDecodeError as e:
                print(f"Error parsing image IDs JSON: {e}", file=sys.stderr)
                sys.exit(1)
            
            # Chunk images
            chunks = chunk_image_ids(image_ids, chunk_size=args.chunk_size)
            
            # Output each chunk as JSON on separate lines
            for chunk in chunks:
                print(json.dumps(chunk))
                
        elif args.command == "count":
            # Read input
            if args.input_json:
                input_data = args.input_json
            else:
                input_data = sys.stdin.read()
            
            # Count images
            count = count_images(input_data)
            print(count)
            
        elif args.command == "describe-images":
            # Retrieve images via AWS CLI
            json_output, error_msg = describe_images(
                repository_name=args.repository_name,
                profile=args.profile,
                region=args.region
            )
            
            if error_msg:
                print(f"Error retrieving ECR images: {error_msg}", file=sys.stderr)
                sys.exit(1)
            
            if json_output:
                print(json_output)
            else:
                print("Error: No output from describe_images", file=sys.stderr)
                sys.exit(1)
            
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
