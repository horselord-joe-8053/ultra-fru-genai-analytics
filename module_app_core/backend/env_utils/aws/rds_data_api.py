"""
AWS RDS Data API client for Aurora PostgreSQL.
Works in both ECS and EKS containers (uses IAM role or AWS credentials).

Applicable environment: [aws {ecs | eks}]
"""
#!/usr/bin/env python3
"""
Load CSV data into Aurora using RDS Data API (no direct network connection required).
Uses AWS RDS Data API instead of psycopg2 for Aurora Serverless compatibility.
"""
import os
import json
import time
import pandas as pd
import boto3
from botocore.exceptions import ClientError
from openai import OpenAI
from backend.utils.env_helpers import get_required_env, get_optional_env

OPENAI_MODEL = get_required_env("OPENAI_EMBED_MODEL", "OpenAI embedding model (e.g., text-embedding-3-small)")


def get_openai_client() -> OpenAI:
    return OpenAI()  # requires OPENAI_API_KEY in env


def get_rds_data_client():
    """Get RDS Data API client using AWS credentials."""
    region = get_required_env("AWS_REGION", "AWS region")
    profile = os.environ.get("AWS_PROFILE", "").strip()
    
    if profile:
        session = boto3.Session(profile_name=profile)
    else:
        session = boto3.Session()
    
    return session.client("rds-data", region_name=region)


def embed_texts(client: OpenAI, texts):
    resp = client.embeddings.create(
        model=OPENAI_MODEL,
        input=texts,
    )
    return [item.embedding for item in resp.data]


def format_value(value):
    """Format a value for SQL insertion."""
    import math
    
    # Handle None and NaN values
    if value is None:
        return "NULL"
    elif isinstance(value, float) and (math.isnan(value) or math.isinf(value)):
        return "NULL"
    elif isinstance(value, str):
        # Handle pandas NaN string representation
        if value.lower() == 'nan' or value == '':
            return "NULL"
        # Escape single quotes in strings
        return f"'{value.replace(chr(39), chr(39) + chr(39))}'"
    elif isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    elif isinstance(value, (int, float)):
        return str(value)
    else:
        return f"'{str(value)}'"


def execute_insert_via_rds_api(rds_client, cluster_arn, secret_arn, db_name, row_data, embedding):
    """
    Insert a single row using RDS Data API.
    
    Returns:
        tuple: (success: bool, error_message: str)
    """
    # Build the INSERT statement
    sql = f"""
    INSERT INTO fru_sales_embeddings (
        brand, fridge_model, price, store_name, purchase_date,
        customer_feedback, rating, capacity_liters,
        embedding
    ) VALUES (
        {format_value(row_data.get('BRAND'))},
        {format_value(row_data.get('FRIDGE_MODEL'))},
        {format_value(row_data.get('PRICE'))},
        {format_value(row_data.get('STORE_NAME'))},
        {format_value(row_data.get('PURCHASE_DATE'))},
        {format_value(row_data.get('CUSTOMER_FEEDBACK'))},
        {format_value(row_data.get('RATING'))},
        {format_value(row_data.get('CAPACITY_LITERS'))},
        $embedding::vector
    )
    """
    
    parameters = [
        {
            'name': 'embedding',
            'value': {'arrayValue': {'doubleValues': embedding}},
            'typeHint': 'JSON'
        }
    ]
    
    try:
        response = rds_client.execute_statement(
            resourceArn=cluster_arn,
            secretArn=secret_arn,
            database=db_name,
            sql=sql,
            parameters=parameters
        )
        return True, None
    except ClientError as e:
        error_code = e.response.get('Error', {}).get('Code', 'Unknown')
        error_message = e.response.get('Error', {}).get('Message', str(e))
        return False, f"{error_code}: {error_message}"


def main():
    """Load CSV data into Aurora using RDS Data API."""
    csv_path = get_optional_env("FRU_CSV_PATH", "data/raw/fridge_sales_with_rating.csv")
    
    # AWS RDS Data API configuration
    cluster_arn = get_required_env("AWS_RDS_CLUSTER_ARN", "Aurora cluster ARN")
    secret_arn = get_required_env("AWS_RDS_SECRET_ARN", "Secrets Manager secret ARN")
    db_name = get_required_env("PGDATABASE", "Database name")
    
    print(f"Loading CSV from: {csv_path}")
    print(f"Aurora Cluster: {cluster_arn}")
    print(f"Database: {db_name}")
    
    # Read CSV
    df = pd.read_csv(csv_path)
    print(f"Found {len(df)} rows in CSV")
    
    # Initialize clients
    openai_client = get_openai_client()
    rds_client = get_rds_data_client()
    
    # Process in batches
    batch_size = 10
    successful = 0
    failed = 0
    
    for i in range(0, len(df), batch_size):
        batch = df.iloc[i:i+batch_size]
        
        # Get feedback texts for embedding
        feedback_texts = batch['CUSTOMER_FEEDBACK'].fillna('').tolist()
        
        # Generate embeddings
        try:
            embeddings = embed_texts(openai_client, feedback_texts)
        except Exception as e:
            print(f"Error generating embeddings for batch {i//batch_size + 1}: {e}")
            failed += len(batch)
            continue
        
        # Insert each row with its embedding
        for idx, (_, row) in enumerate(batch.iterrows()):
            success, error = execute_insert_via_rds_api(
                rds_client, cluster_arn, secret_arn, db_name, row, embeddings[idx]
            )
            
            if success:
                successful += 1
            else:
                failed += 1
                print(f"Failed to insert row {idx + i + 1}: {error}")
        
        print(f"Processed batch {i//batch_size + 1}: {successful} successful, {failed} failed")
        
        # Rate limiting
        time.sleep(0.1)
    
    print(f"\nCompleted: {successful} successful, {failed} failed")


if __name__ == "__main__":
    main()

