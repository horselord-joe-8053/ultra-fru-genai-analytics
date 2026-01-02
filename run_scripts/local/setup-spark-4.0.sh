#!/bin/bash
# Setup script for Spark 4.0.1 + Delta Lake 4.0.0
# Usage: source run_scripts/local/setup-spark-4.0.sh
# Or from repo root: source ./run_scripts/local/setup-spark-4.0.sh

export SPARK_HOME=~/spark/spark-4.0.1-bin-hadoop3
export PATH=$SPARK_HOME/bin:$PATH

# Use Java 21 (required for Spark 4.0.x, Java 23 has security manager issues)
if [[ "$OSTYPE" == "darwin"* ]]; then
    export JAVA_HOME=$(/usr/libexec/java_home -v 21 2>/dev/null)
    if [ -z "$JAVA_HOME" ]; then
        echo "⚠️  Warning: Java 21 not found. Spark 4.0.x requires Java 21."
        echo "   Install with: brew install openjdk@21"
    fi
fi

echo "✅ Spark 4.0.1 environment configured"
echo "   SPARK_HOME: $SPARK_HOME"
echo "   JAVA_HOME: $JAVA_HOME"
spark-submit --version 2>&1 | grep -i "version" | head -1
