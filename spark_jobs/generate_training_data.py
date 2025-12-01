from pyspark.sql import SparkSession
import json
import os
import sys

def main(delta_path: str, out_jsonl: str):
    spark = SparkSession.builder.appName("fru-generate-training-data").getOrCreate()
    df = spark.read.format("delta").load(delta_path)

    cols = df.columns
    needed = ["BRAND", "FRIDGE_MODEL", "STORE_NAME", "SALES_DATE", "FEEDBACK_RATING"]
    for c in needed:
        if c not in cols:
            print("Warning: column", c, "missing in Delta table")

    df_sample = (
        df.select("BRAND", "FRIDGE_MODEL", "STORE_NAME", "SALES_DATE", "FEEDBACK_RATING")
        .dropna()
        .dropDuplicates()
        .limit(200)
    )

    records = []
    for row in df_sample.collect():
        row = row.asDict()
        brand = row.get("BRAND")
        model = row.get("FRIDGE_MODEL")
        store = row.get("STORE_NAME")
        rating = row.get("FEEDBACK_RATING")

        q1 = f"How many {brand} fridges were sold at {store}?"
        sql1 = (
            "SELECT STORE_NAME, BRAND, COUNT(*) AS qty "
            "FROM fru_sales "
            f"WHERE BRAND = '{brand}' AND STORE_NAME = '{store}' "
            "GROUP BY STORE_NAME, BRAND;"
        )
        records.append({"question": q1, "sql": sql1})

        q2 = f"What is the average price of model {model} in {store}?"
        sql2 = (
            "SELECT STORE_NAME, FRIDGE_MODEL, AVG(PRICE) AS avg_price "
            "FROM fru_sales "
            f"WHERE FRIDGE_MODEL = '{model}' AND STORE_NAME = '{store}' "
            "GROUP BY STORE_NAME, FRIDGE_MODEL;"
        )
        records.append({"question": q2, "sql": sql2})

        if rating:
            q3 = f"How many sales at {store} had {rating.lower()} feedback?"
            sql3 = (
                "SELECT STORE_NAME, FEEDBACK_RATING, COUNT(*) AS cnt "
                "FROM fru_sales "
                f"WHERE STORE_NAME = '{store}' AND FEEDBACK_RATING = '{rating}' "
                "GROUP BY STORE_NAME, FEEDBACK_RATING;"
            )
            records.append({"question": q3, "sql": sql3})

    os.makedirs(os.path.dirname(out_jsonl), exist_ok=True)
    with open(out_jsonl, "w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")

    print(f"Wrote {len(records)} training pairs to {out_jsonl}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: generate_training_data.py <delta_path> <out_jsonl>")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
