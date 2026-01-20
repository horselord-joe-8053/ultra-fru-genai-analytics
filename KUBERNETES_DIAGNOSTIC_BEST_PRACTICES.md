# Kubernetes Diagnostic Best Practices (Cloud-Agnostic)

## A. Architecture Clarification

### Current Setup
- **Platform**: AWS EKS (Elastic Kubernetes Service)
- **Deployment**: Remote Kubernetes cluster (not local)
- **Containers**: Docker containers running on EKS Fargate nodes
- **Application**: Flask API application inside containers
- **Access**: Via `kubectl` commands from local machine, connecting to remote EKS cluster

### Key Points
1. Containers run **remotely** on AWS EKS cluster
2. `kubectl` commands execute **locally** but connect to **remote** cluster
3. Container logs are streamed to local machine via `kubectl logs`
4. Pod status, events, and diagnostics are accessed remotely via Kubernetes API

### Future (GCP)
- **Platform**: GKE (Google Kubernetes Engine) 
- **Access pattern**: Same - `kubectl` from local machine, connecting to remote GKE cluster
- **Container runtime**: Same Docker containers (container images in GCR instead of ECR)

## B. Best Practices for Diagnosing Container Failures

### 1. Structured Logging Strategy (Cloud-Agnostic)

#### A. Application-Level Logging
- **Use structured logging** (JSON format when possible)
- **Log levels**: DEBUG, INFO, WARNING, ERROR, CRITICAL
- **Include context**: Request IDs, correlation IDs, timestamps
- **Sanitize sensitive data**: Never log passwords, tokens, full credentials

**Implementation Pattern:**
```python
import logging
import json

# Structured logging
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)

# Log with context
app.logger.info("Flask startup initiated", extra={
    "component": "flask",
    "phase": "startup",
    "python_version": sys.version
})
```

#### B. Health Check Endpoints
- **Liveness probe**: `/health` - is app alive?
- **Readiness probe**: `/ready` - is app ready to serve traffic?
- **Startup probe**: For slow-starting apps

**Example:**
```python
@app.route("/health")
def health():
    return jsonify({"status": "healthy", "timestamp": datetime.now()})

@app.route("/ready")
def ready():
    # Check critical dependencies (DB, external services)
    db_ok = check_database()
    if db_ok:
        return jsonify({"status": "ready"}), 200
    return jsonify({"status": "not ready"}), 503
```

### 2. Container Startup Diagnostics

#### A. Entrypoint Script Best Practices
```bash
#!/bin/bash
# DO NOT use 'set -e' - it hides errors
# Instead, check exit codes explicitly

# Log environment
echo "[entrypoint] Environment check..."
echo "[entrypoint] Python: $(which python)"
echo "[entrypoint] PYTHONPATH: ${PYTHONPATH:-not set}"
echo "[entrypoint] Working dir: $(pwd)"

# Test critical dependencies before starting app
echo "[entrypoint] Testing Python imports..."
python -c "import sys; print(f'Python {sys.version}')" || {
    echo "[entrypoint] ERROR: Python check failed" >&2
    exit 1
}

# Start application with error capture
echo "[entrypoint] Starting application..."
exec python -u app.py 2>&1 || {
    exit_code=$?
    echo "[entrypoint] ERROR: Application exited with code $exit_code" >&2
    exit $exit_code
}
```

#### B. Startup Logging Pattern
```python
if __name__ == "__main__":
    import sys
    import traceback
    
    # Startup banner
    logger.info("=" * 60)
    logger.info("Application Startup")
    logger.info("=" * 60)
    
    # Environment info
    logger.info(f"Python version: {sys.version}")
    logger.info(f"Python path: {':'.join(sys.path[:3])}")
    
    # Step-by-step initialization with error handling
    try:
        logger.info("[STARTUP] Step 1: Loading configuration...")
        # Load config
        logger.info("[STARTUP] Step 1: Complete")
        
        logger.info("[STARTUP] Step 2: Initializing database...")
        init_db()
        logger.info("[STARTUP] Step 2: Complete")
        
        logger.info("[STARTUP] Step 3: Starting server...")
        app.run(host="0.0.0.0", port=5000)
    except Exception as e:
        logger.critical(f"[STARTUP] FAILED: {e}", exc_info=True)
        traceback.print_exc()
        sys.exit(1)
```

### 3. Kubernetes Observability Patterns

#### A. Pod Status Investigation
```bash
# Check pod status
kubectl get pods -n <namespace> -l app=<app-label>

# Get detailed pod information
kubectl describe pod <pod-name> -n <namespace>

# Check pod events (shows all lifecycle events)
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

#### B. Log Collection Strategies

**1. Standard Output Logs**
```bash
# Current logs
kubectl logs <pod-name> -n <namespace>

# Previous container logs (if pod restarted)
kubectl logs <pod-name> -n <namespace> --previous

# Follow logs in real-time
kubectl logs <pod-name> -n <namespace> -f

# Logs with timestamps
kubectl logs <pod-name> -n <namespace> --timestamps

# Logs from all containers in pod
kubectl logs <pod-name> -n <namespace> --all-containers=true
```

**2. Multiple Pods**
```bash
# Logs from all pods matching label
kubectl logs -n <namespace> -l app=<app-label> --tail=100

# Logs with specific pattern
kubectl logs -n <namespace> -l app=<app-label> | grep ERROR
```

#### C. Container Debugging
```bash
# Interactive shell into running container
kubectl exec -it <pod-name> -n <namespace> -- /bin/bash

# Execute command in container
kubectl exec <pod-name> -n <namespace> -- env | grep DB

# Check container processes
kubectl exec <pod-name> -n <namespace> -- ps aux

# Check container filesystem
kubectl exec <pod-name> -n <namespace> -- ls -la /app
```

### 4. Cloud-Agnostic Diagnostic Tools

#### A. Standard Kubernetes Commands (Works on EKS and GKE)
```bash
# Check cluster info
kubectl cluster-info

# Check node status
kubectl get nodes

# Check all resources in namespace
kubectl get all -n <namespace>

# Get detailed resource description
kubectl describe <resource-type> <resource-name> -n <namespace>

# Check resource YAML
kubectl get <resource-type> <resource-name> -n <namespace> -o yaml
```

#### B. Log Aggregation (Cloud-Specific but Same Pattern)

**AWS EKS:**
- CloudWatch Logs (configured via fluent-bit or CloudWatch Logs agent)
- Access via: `aws logs tail <log-group-name>`

**GCP GKE:**
- Cloud Logging (automatic for stdout/stderr)
- Access via: `gcloud logging read`

**Common Pattern:**
```yaml
# Both platforms can use same logging configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush         5
        Log_Level     info
    
    [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        Parser            docker
    
    [OUTPUT]
        Name              cloudwatch_logs  # AWS
        # or
        Name              stackdriver      # GCP
```

### 5. Startup Probe Pattern (Recommended for Slow-Start Apps)

```yaml
# deployment.yaml
spec:
  containers:
  - name: app
    startupProbe:
      httpGet:
        path: /health
        port: 5000
      initialDelaySeconds: 0
      periodSeconds: 5
      timeoutSeconds: 3
      failureThreshold: 30  # Allow up to 150 seconds for startup
    
    livenessProbe:
      httpGet:
        path: /health
        port: 5000
      initialDelaySeconds: 30
      periodSeconds: 10
    
    readinessProbe:
      httpGet:
        path: /ready
        port: 5000
      initialDelaySeconds: 10
      periodSeconds: 5
```

### 6. Error Handling Pattern (Cloud-Agnostic)

#### A. Application Error Handling
```python
import sys
import traceback
import logging

def init_app():
    """Initialize application with comprehensive error handling."""
    logger = logging.getLogger(__name__)
    
    # Wrap each initialization step
    steps = [
        ("Load configuration", load_config),
        ("Initialize database", init_database),
        ("Initialize cache", init_cache),
        ("Initialize external services", init_external_services),
    ]
    
    for step_name, step_func in steps:
        try:
            logger.info(f"[INIT] Starting: {step_name}")
            step_func()
            logger.info(f"[INIT] Complete: {step_name}")
        except Exception as e:
            logger.critical(f"[INIT] FAILED: {step_name} - {e}", exc_info=True)
            # Log full traceback
            traceback.print_exc(file=sys.stderr)
            # Don't exit immediately - log all failures first
            raise  # Re-raise to exit
```

#### B. Graceful Degradation
```python
def init_database():
    """Initialize database with graceful degradation."""
    try:
        pool = create_connection_pool()
        logger.info("Database pool created successfully")
        return pool
    except ConnectionError as e:
        logger.error(f"Database connection failed: {e}")
        # In production, you might want to:
        # 1. Retry with exponential backoff
        # 2. Use cached data
        # 3. Start in degraded mode
        raise  # Or handle gracefully based on requirements
```

### 7. Diagnostic Checklist (Cloud-Agnostic)

When debugging container failures, check in this order:

1. **Pod Status**
   ```bash
   kubectl get pods -n <namespace>
   kubectl describe pod <pod-name> -n <namespace>
   ```

2. **Container Logs**
   ```bash
   kubectl logs <pod-name> -n <namespace> --tail=100
   kubectl logs <pod-name> -n <namespace> --previous  # If restarted
   ```

3. **Container Events**
   ```bash
   kubectl get events -n <namespace> --sort-by='.lastTimestamp'
   ```

4. **Resource Constraints**
   ```bash
   kubectl top pod <pod-name> -n <namespace>  # CPU/Memory usage
   kubectl describe pod <pod-name> -n <namespace> | grep -A 5 "Limits\|Requests"
   ```

5. **Configuration Verification**
   ```bash
   kubectl get configmap <configmap-name> -n <namespace> -o yaml
   kubectl get secret <secret-name> -n <namespace> -o yaml
   ```

6. **Network Connectivity**
   ```bash
   kubectl exec <pod-name> -n <namespace> -- curl http://service-name:port/health
   ```

7. **Environment Variables**
   ```bash
   kubectl exec <pod-name> -n <namespace> -- env | grep -E "DB_|API_|KEY"
   ```

### 8. Cloud-Agnostic Diagnostic Script Pattern

```bash
#!/bin/bash
# diagnose-pod.sh - Works on EKS and GKE

NAMESPACE="${1:-default}"
POD_NAME="${2}"
LABEL_SELECTOR="${3:-app=my-app}"

if [ -z "$POD_NAME" ]; then
    POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[0].metadata.name}')
fi

echo "=== Pod Diagnostics: $POD_NAME ==="
echo ""

echo "1. Pod Status:"
kubectl get pod "$POD_NAME" -n "$NAMESPACE"
echo ""

echo "2. Pod Description:"
kubectl describe pod "$POD_NAME" -n "$NAMESPACE" | head -50
echo ""

echo "3. Recent Events:"
kubectl get events -n "$NAMESPACE" --field-selector involvedObject.name="$POD_NAME" --sort-by='.lastTimestamp' | tail -10
echo ""

echo "4. Current Logs (last 50 lines):"
kubectl logs "$POD_NAME" -n "$NAMESPACE" --tail=50
echo ""

echo "5. Previous Logs (if restarted):"
kubectl logs "$POD_NAME" -n "$NAMESPACE" --previous --tail=50 2>/dev/null || echo "No previous logs"
echo ""

echo "6. Environment Variables:"
kubectl exec "$POD_NAME" -n "$NAMESPACE" -- env 2>/dev/null | grep -E "APP_|DB_|API_" || echo "Cannot exec into pod"
echo ""

echo "=== End Diagnostics ==="
```

## C. Implementation for Cloud-Agnostic Diagnostic

### Recommended Changes

1. **Enhanced Entrypoint Script** (Cloud-agnostic)
   - Add pre-flight checks
   - Log environment details
   - Capture and log Python exit codes
   - Works on both EKS and GKE

2. **Structured Application Logging** (Cloud-agnostic)
   - Step-by-step startup logging
   - Comprehensive error logging with tracebacks
   - Health check endpoints
   - Works on both EKS and GKE

3. **Kubernetes Resource Configuration** (Cloud-agnostic)
   - Startup probes for slow-starting apps
   - Proper liveness/readiness probes
   - Resource limits and requests
   - Works on both EKS and GKE (same YAML)

4. **Diagnostic Scripts** (Cloud-agnostic)
   - Use standard `kubectl` commands
   - No cloud-specific APIs
   - Works identically on EKS and GKE

### Cloud-Specific Considerations

**Log Aggregation:**
- AWS: CloudWatch Logs (configure via fluent-bit)
- GCP: Cloud Logging (automatic)
- **Both**: Can use same stdout/stderr logging pattern

**Metrics:**
- AWS: CloudWatch Metrics
- GCP: Cloud Monitoring
- **Both**: Prometheus + Grafana (cloud-agnostic solution)

**Storage:**
- Both use Kubernetes PersistentVolumes
- Storage class names differ, but YAML pattern is same

## Summary

**Best Practices for Cloud-Agnostic Diagnostics:**

1. ✅ **Use standard Kubernetes APIs** (`kubectl`, Kubernetes YAML)
2. ✅ **Log to stdout/stderr** (captured by both platforms)
3. ✅ **Implement health check endpoints**
4. ✅ **Use structured, comprehensive logging**
5. ✅ **Add startup probes for slow-starting apps**
6. ✅ **Create reusable diagnostic scripts using `kubectl`**
7. ✅ **Handle errors gracefully with detailed logging**

**Cloud-Specific Only When Necessary:**
- Log aggregation configuration (fluent-bit config)
- Metrics backend (CloudWatch vs Cloud Monitoring)
- Service account authentication (IAM vs GCP IAM)
- But diagnostic **approach** remains the same!

