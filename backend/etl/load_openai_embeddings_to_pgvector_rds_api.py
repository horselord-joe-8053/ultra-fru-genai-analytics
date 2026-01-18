#!/usr/bin/env python3
"""
Load CSV data into Aurora using RDS Data API (no direct network connection required).
Uses AWS RDS Data API instead of psycopg2 for Aurora Serverless compatibility.

Note: This file will be moved to backend/env_utils/aws/rds_data_api.py during refactoring.
For now, keeping both locations for backward compatibility.

Applicable environment: [aws {ecs | eks}]
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
        # Escape single quotes
        escaped = value.replace("'", "''")
        return f"'{escaped}'"
    elif isinstance(value, (int, float)):
        return str(value)
    elif isinstance(value, list):
        # Vector embedding - convert to PostgreSQL array format
        return f"'[{','.join(map(str, value))}]'"
    else:
        str_val = str(value)
        if str_val.lower() == 'nan':
            return "NULL"
        return f"'{str_val}'"

def execute_insert_via_rds_api(rds_client, cluster_arn, secret_arn, db_name, row_data, embedding):
    """Execute a single INSERT statement via RDS Data API."""
    # Build SQL with proper formatting
    # Convert FEEDBACK_RATING to integer
    feedback_rating = row_data.get('FEEDBACK_RATING', '')
    if feedback_rating:
        try:
            feedback_rating_int = int(feedback_rating)
        except (ValueError, TypeError):
            feedback_rating_int = None
    else:
        feedback_rating_int = None
    
    sql = f"""
    INSERT INTO fru_sales_embeddings
    (id, customer_id, brand, fridge_model, capacity_liters, price, sales_date, store_name, store_address, customer_feedback, feedback_rating, feedback_sentiment_category, embedding)
    VALUES (
        {format_value(row_data['ID'])},
        {format_value(row_data.get('CUSTOMER_ID', ''))},
        {format_value(row_data['BRAND'])},
        {format_value(row_data['FRIDGE_MODEL'])},
        {format_value(row_data.get('CAPACITY_LITERS'))},
        {format_value(row_data['PRICE'])},
        {format_value(row_data['SALES_DATE'])},
        {format_value(row_data['STORE_NAME'])},
        {format_value(row_data.get('STORE_ADDRESS', ''))},
        {format_value(row_data.get('CUSTOMER_FEEDBACK', ''))},
        {feedback_rating_int if feedback_rating_int is not None else 'NULL'},
        {format_value(row_data.get('FEEDBACK_SENTIMENT_CATEGORY', ''))},
        {format_value(embedding)}::vector
    )
    ON CONFLICT (id) DO UPDATE SET
      customer_id = EXCLUDED.customer_id,
      brand = EXCLUDED.brand,
      fridge_model = EXCLUDED.fridge_model,
      capacity_liters = EXCLUDED.capacity_liters,
      price = EXCLUDED.price,
      sales_date = EXCLUDED.sales_date,
      store_name = EXCLUDED.store_name,
      store_address = EXCLUDED.store_address,
      customer_feedback = EXCLUDED.customer_feedback,
      feedback_rating = EXCLUDED.feedback_rating,
      feedback_sentiment_category = EXCLUDED.feedback_sentiment_category,
      embedding = EXCLUDED.embedding;
    """
    
    try:
        response = rds_client.execute_statement(
            resourceArn=cluster_arn,
            secretArn=secret_arn,
            database=db_name,
            sql=sql
        )
        return True, None
    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code", "Unknown")
        error_message = e.response.get("Error", {}).get("Message", str(e))
        return False, f"{error_code}: {error_message}"

def main():
    csv_path = get_optional_env("FRU_CSV_PATH", "data/raw/fridge_sales_with_rating.csv")
    cluster_arn = get_required_env("DB_CLUSTER_ARN", "Aurora cluster ARN")
    secret_arn = get_required_env("DB_SECRET_ARN", "Aurora secret ARN")
    db_name = get_optional_env("PGDATABASE", "fru_db")
    
    df = pd.read_csv(csv_path)
    
    required = ["ID","CUSTOMER_ID","BRAND","FRIDGE_MODEL","CAPACITY_LITERS","PRICE","SALES_DATE","STORE_NAME","STORE_ADDRESS","CUSTOMER_FEEDBACK","FEEDBACK_RATING","FEEDBACK_SENTIMENT_CATEGORY"]
    for c in required:
        if c not in df.columns:
            raise RuntimeError(f"Missing required column: {c}")
    
    rds_client = get_rds_data_client()
    openai_client = get_openai_client()
    rows = df.to_dict(orient="records")
    batch_size = 64
    
    total_rows = len(rows)
    success_count = 0
    error_count = 0
    
    print(f"Processing {total_rows} rows in batches of {batch_size}...")
    
    # Track errors for fail-fast detection
    error_messages = {}
    consecutive_errors = 0
    max_consecutive_errors = 10  # Fail fast if we see 10 consecutive identical errors
    
    for i in range(0, len(rows), batch_size):
        batch = rows[i:i+batch_size]
        texts = [r.get("CUSTOMER_FEEDBACK") or "" for r in batch]
        embeddings = embed_texts(openai_client, texts)
        
        batch_success = 0
        batch_errors = 0
        
        for row_data, embedding in zip(batch, embeddings):
            # Convert pandas NaN to None for proper handling
            cleaned_row = {}
            for key, val in row_data.items():
                if pd.isna(val):
                    cleaned_row[key] = None
                else:
                    cleaned_row[key] = val
            
            success, error = execute_insert_via_rds_api(
                rds_client, cluster_arn, secret_arn, db_name, cleaned_row, embedding
            )
            
            if success:
                success_count += 1
                batch_success += 1
                consecutive_errors = 0  # Reset on success
            else:
                error_count += 1
                batch_errors += 1
                consecutive_errors += 1
                
                # Track error messages for fail-fast detection
                error_key = error.split(':')[0] if ':' in error else error[:100]  # Use error type as key
                error_messages[error_key] = error_messages.get(error_key, 0) + 1
                
                print(f"Error inserting row {cleaned_row['ID']}: {error}")
        
                # Fail fast if we see many consecutive identical errors (likely schema issue)
                if consecutive_errors >= max_consecutive_errors:
                    print(f"\n❌ FAIL-FAST: Detected {consecutive_errors} consecutive errors with same pattern")
                    print(f"   Most common error: {error_key}")
                    print(f"   This likely indicates a schema problem (e.g., missing 'embedding' column)")
                    print(f"   Please verify schema initialization completed successfully")
                    print(f"\n   Progress: {success_count} inserted, {error_count} errors out of {total_rows} rows")
                    raise RuntimeError(f"Data loading failed due to repeated errors: {error_key}. "
                                    f"Likely schema issue - verify 'embedding' column exists in 'fru_sales_embeddings' table.")
        
        print(f"Processed batch [{i}..{i+len(batch)-1}]: {batch_success} success, {batch_errors} errors")
        time.sleep(0.2)  # Rate limiting
    
    print(f"\nDone. Total: {success_count} inserted, {error_count} errors out of {total_rows} rows.")
    
    # Fail if we had any errors (strict mode)
    if error_count > 0:
        print(f"\n❌ FAILED: {error_count} errors occurred during data loading")
        print(f"   Most common errors:")
        for error_key, count in sorted(error_messages.items(), key=lambda x: x[1], reverse=True)[:3]:
            print(f"     - {error_key}: {count} occurrences")
        raise RuntimeError(f"Data loading completed with {error_count} errors. "
                          f"This indicates a problem (likely schema mismatch). "
                          f"Please verify the database schema is correct.")

if __name__ == "__main__":
    main()

