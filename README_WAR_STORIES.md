# README_WAR_STORIES

A curated list of **non-trivial technical war stories**, capturing real lessons suitable for **senior-level interviews**.

---

## 1. HTTP Status Code Corruption: Streaming Endpoint Validation with HEAD vs GET

**creation:** `<260127-175946>`
**last_updated:** `<260127-175946>`

**keywords:** HTTP, curl, streaming endpoints, Server-Sent Events (SSE), status code validation, HEAD request
**difficulty:** 6
**significance:** 7

### 1.1 Context

During automated endpoint validation, the `/query/stream` endpoint (a Server-Sent Events streaming endpoint) consistently returned a corrupted HTTP status code: `HTTP 200000` instead of the expected `HTTP 200`. The validation script used `curl -w "%{http_code}"` with a GET request, which worked fine for regular REST endpoints but failed for streaming endpoints.

### 1.2 Root Cause

The `/query/stream` endpoint streams data continuously using Server-Sent Events (SSE). When using `curl -w "%{http_code}"` with a GET request, curl:
1. Sends the GET request
2. Receives the HTTP response headers (including status code)
3. **Starts consuming the streaming response body**
4. Tries to write the status code to stdout

The problem: The streaming data output mixed with the status code output, resulting in a corrupted value like `200000` (the actual `200` status code followed by streaming data characters that were interpreted as part of the status code).

### 1.3 Key Insight

> Streaming endpoints require different validation strategies than regular REST endpoints. GET requests consume the stream, corrupting output parsing. HEAD requests retrieve only headers without consuming the response body.

### 1.4 Resolution

Changed the validation logic for streaming endpoints from GET to HEAD request:
- **Before:** `curl -s -o /dev/null -w "%{http_code}" "$endpoint"`
- **After:** `curl -s -I -o /dev/null -w "%{http_code}" "$endpoint"`

The `-I` flag (HEAD request) retrieves only the HTTP headers without consuming the response body, allowing clean status code extraction. Added robust extraction logic: `query_stream_status=$(echo "$curl_output" | grep -oE '[0-9]{3}' | head -1 || echo "000")` to handle edge cases.

### 1.5 Takeaway

Always use HEAD requests (`curl -I`) for status validation of streaming endpoints. GET requests will consume the stream and corrupt output parsing. For regular REST endpoints, GET is fine, but streaming endpoints (SSE, WebSockets, long-polling) require HEAD requests for validation.

---

## 2. HTTP 000000 Error: HTTPS vs HTTP Protocol Mismatch for EKS Network Load Balancer

**creation:** `<260127-175946>`
**last_updated:** `<260127-175946>`

**keywords:** AWS EKS, Network Load Balancer (NLB), HTTPS, HTTP, SSL certificate, curl, ingress
**difficulty:** 7
**significance:** 8

### 2.1 Context

During endpoint validation, direct API endpoint checks for EKS ingress endpoints (DNS names like `*.elb.us-east-1.amazonaws.com`) consistently returned `HTTP 000000` errors. CloudFront endpoints worked fine, but the direct load balancer endpoint failed validation. The error appeared as a warning: `[WARNING] ⚠ API endpoint returned HTTP 000000`.

### 2.2 Root Cause

The code was attempting HTTPS connections to EKS ingress endpoints, but EKS uses NGINX Ingress Controller which creates an AWS Network Load Balancer (NLB). NLBs don't have SSL certificates by default unless explicitly configured with AWS Certificate Manager (ACM). 

When `curl` attempted an HTTPS connection to an NLB without a valid certificate:
1. SSL handshake failed
2. `curl` returned exit code 60 (SSL certificate problem)
3. The status code extraction returned `000` (indicating no HTTP response was received)
4. The display logic showed this as `000000` (due to formatting)

The `000` status code from curl is not an HTTP status code—it indicates that curl never received an HTTP response because the SSL/TLS handshake failed before any HTTP communication occurred.

### 2.3 Key Insight

> NLBs and ALBs without ACM certificates don't serve HTTPS with valid certificates. The `000` curl status code indicates SSL handshake failure, not an HTTP protocol error. Always use HTTP for AWS load balancer DNS names unless you've explicitly configured ACM certificates.

### 2.4 Resolution

Modified `fetch-deployment-info.sh` to always use `http://` when constructing API URLs for EKS ingress hostnames (which are NLB DNS names ending in `.elb.amazonaws.com`):

```bash
# Before: Conditional HTTPS/HTTP based on hostname pattern
if echo "$K8S_INGRESS_HOST" | grep -qE '\\.elb\\.|\\.amazonaws\\.com'; then
    API_URL="http://$K8S_INGRESS_HOST"
else
    API_URL="https://$K8S_INGRESS_HOST"  # Wrong assumption
fi

# After: Always HTTP for EKS Ingress (NLB)
API_URL="http://$K8S_INGRESS_HOST"
```

Also fixed the same issue in `test/common_sh/test_environment.sh` which had been overlooked during the initial fix.

### 2.5 Takeaway

Always use HTTP for AWS load balancer DNS names (`.elb.amazonaws.com`) unless you've explicitly configured ACM certificates. The `000` curl status code is a red flag for SSL/TLS issues, not HTTP protocol problems. When debugging endpoint failures, check the protocol first—many "HTTP errors" are actually SSL certificate problems.

---

## 3. CloudFront Invalidation Timeout: Stdout/Stderr Capture Corrupting Return Values

**creation:** `<260127-175946>`
**last_updated:** `<260127-175946>`

**keywords:** Bash, command substitution, stdout, stderr, environment variables, CloudFront, invalidation, function return values
**difficulty:** 8
**significance:** 9

### 3.1 Context

CloudFront invalidation consistently timed out with `NoSuchInvalidation` errors, even though invalidations were being created successfully. The deployment script would:
1. Create a CloudFront invalidation (succeeded)
2. Attempt to wait for completion (failed with `NoSuchInvalidation`)
3. Timeout after 15 minutes
4. Deployment continued, but the invalidation never completed verification

**Why CloudFront Invalidation is Needed:** CloudFront caches content at edge locations worldwide. When you deploy new frontend files to S3, CloudFront continues serving the old cached version until the cache expires (which can take hours or days). Invalidation tells CloudFront to immediately purge cached content and fetch fresh files from the origin (S3). Without invalidation, users see stale content after deployments.

### 3.2 Root Cause

The function `create_cloudfront_invalidation()` was designed to return the invalidation ID via stdout for command substitution:

```bash
invalidation_id=$(create_cloudfront_invalidation "$dist_id" "/*")
```

However, the function also logged messages to stdout using `log_info()` and `log_success()`, which write to stdout. When captured with command substitution, the variable captured **both** the log messages and the invalidation ID:

```
invalidation_id='[INFO] Creating CloudFront invalidation...
[INFO]   Distribution ID: E33TA1D0OAYUNR
[INFO]   Paths: /*
[SUCCESS] CloudFront invalidation created: IAS6QGH99WVY9LQVVST4POTQBE
IAS6QGH99WVY9LQVVST4POTQBE'
```

This corrupted string was then passed to `wait_for_invalidation()`, which called `aws cloudfront get-invalidation --id '[INFO] Creating...IAS6QGH99WVY9LQVVST4POTQBE'`. AWS correctly returned `NoSuchInvalidation` because that malformed string is not a valid invalidation ID.

### 3.3 Key Insight

> Functions that return values via stdout must NEVER log to stdout. Command substitution captures ALL stdout, making it impossible to separate logs from return values. Use stderr for logging, or better yet, use environment variables for values that need to be passed between functions.

### 3.4 Resolution

**Initial Fix Attempt:** Redirected log messages to stderr (`>&2`), which worked but was fragile and error-prone. Any future developer adding a log statement without the redirect would reintroduce the bug.

**Final Solution:** Changed to environment variable pattern, consistent with other deployment scripts in the codebase:

```bash
# Function now sets and exports environment variable
create_cloudfront_invalidation() {
    # ... create invalidation ...
    export CLOUDFRONT_INVALIDATION_ID="$invalidation_id"
    log_success "CloudFront invalidation created: $invalidation_id"
    return 0
}

# Usage becomes simpler and more robust
if create_cloudfront_invalidation "$dist_id" "/*"; then
    wait_for_invalidation "$dist_id" "$CLOUDFRONT_INVALIDATION_ID" 15 "true"
fi
```

This approach:
- Eliminates stdout/stderr separation issues
- Makes the return value explicit (environment variable name)
- Is consistent with other deployment scripts (`fetch-deployment-info.sh` pattern)
- Is more robust (no risk of mixing logs with return values)

### 3.5 Takeaway

When a function is meant to return a value, either: (1) log to stderr only, or (2) use environment variables. Command substitution captures ALL stdout, making it impossible to separate logs from return values. Environment variables are more robust, explicit, and follow Unix conventions (stdout for data, stderr for diagnostics, or use environment for function-to-function communication).

---

## 4. EKS Load Balancer Type Confusion: NLB vs ALB Misunderstanding

**creation:** `<260127-175946>`
**last_updated:** `<260127-175946>`

**keywords:** AWS EKS, AWS Load Balancer Controller, NGINX Ingress Controller, Network Load Balancer (NLB), Application Load Balancer (ALB)
**difficulty:** 5
**significance:** 6

### 4.1 Context

During debugging of the HTTP 000000 error, code comments and analysis incorrectly stated that "EKS uses AWS Load Balancer Controller to create ALBs." However, the project's EKS setup documentation (`README_WORKFLOW_EKS_NOTES.md`) indicated that EKS uses NGINX Ingress Controller, which creates NLBs, not ALBs. This architectural misunderstanding led to incorrect assumptions about SSL certificate configuration.

### 4.2 Root Cause

EKS supports multiple ingress controllers, each creating different types of load balancers:
- **AWS Load Balancer Controller** → Creates Application Load Balancers (ALBs)
- **NGINX Ingress Controller** → Creates Network Load Balancers (NLBs)

The project uses NGINX Ingress Controller, but comments and analysis incorrectly assumed ALB usage. This led to confusion about why SSL certificates weren't working (ALBs can have ACM certificates more easily configured, while NLBs require explicit ACM setup).

### 4.3 Key Insight

> EKS can use different ingress controllers, each creating different load balancer types. Don't assume load balancer types based on platform (EKS vs ECS). Always verify the actual ingress controller and load balancer type in your infrastructure.

### 4.4 Resolution

Updated comments and documentation to correctly reflect NLB usage for EKS:

```bash
# Updated comment in fetch-deployment-info.sh
# EKS Ingress uses NGINX Ingress Controller, which creates an NLB (Network Load Balancer) on AWS.
# NLBs use .elb.amazonaws.com DNS names and don't have SSL certificates by default
# (unless configured with ACM), so always use HTTP.
```

This clarification helped explain why HTTP (not HTTPS) was required for EKS ingress endpoints.

### 4.5 Takeaway

Don't assume load balancer types based on platform (EKS vs ECS). Verify the actual ingress controller and load balancer type in your infrastructure. Different ingress controllers create different load balancer types, and each has different SSL/TLS certificate requirements.

---

## 5. Protocol Inconsistency: HTTPS Used Where HTTP Required for NLB Endpoints

**creation:** `<260127-175946>`
**last_updated:** `<260127-175946>`

**keywords:** HTTPS, HTTP, protocol, EKS, NLB, test files, consistency, SSL certificates, CloudFront
**difficulty:** 4
**significance:** 6

### 5.1 Context

After fixing the HTTP 000000 error in `fetch-deployment-info.sh` by changing EKS ingress URLs from HTTPS to HTTP, the same issue persisted in test files. The test script `test/common_sh/test_environment.sh` was still attempting HTTPS connections to EKS ingress endpoints, causing test failures.

### 5.2 Root Cause

During the initial fix, only the main deployment script (`fetch-deployment-info.sh`) was updated. The test file `test/common_sh/test_environment.sh` contained duplicate logic for constructing API URLs from EKS ingress hostnames, but it wasn't updated. This created an inconsistency where:
- Production deployment scripts used HTTP (correct)
- Test scripts used HTTPS (incorrect)

**Certificate Limitation Explanation:** 
- **Local machine:** Cannot test HTTPS connections to NLB endpoints because NLBs don't have SSL certificates by default. The local machine would need to trust a certificate that doesn't exist, causing SSL handshake failures.
- **Remote (CloudFront):** CloudFront distributions are configured with ACM certificates and serve HTTPS properly. Users access the application via CloudFront's HTTPS endpoint, which then proxies to the backend (NLB) over HTTP internally. The SSL/TLS termination happens at CloudFront, not at the NLB.

This is a common pattern: CloudFront handles HTTPS for end users, while the origin (NLB/ALB) uses HTTP internally. The NLB doesn't need certificates because it's not directly exposed to end users—only CloudFront connects to it.

### 5.3 Key Insight

> When fixing protocol issues, search the entire codebase for similar patterns. Test files and utility scripts often duplicate logic that needs the same fix. Also understand the architecture: CloudFront terminates SSL for end users, while internal load balancers (NLB/ALB) typically use HTTP.

### 5.4 Resolution

Updated `test/common_sh/test_environment.sh` to use `http://` for EKS ingress hostnames, matching the main script behavior:

```bash
# Before (lines 124, 135)
API_URL="https://$K8S_INGRESS_HOST"
API_URL="https://$k8s_ingress"

# After
API_URL="http://$K8S_INGRESS_HOST"
API_URL="http://$k8s_ingress"
```

This ensured consistency across all scripts and fixed test failures.

### 5.5 Takeaway

Always search for similar patterns across the entire codebase when fixing protocol/URL construction issues. Test files are often overlooked but contain duplicate logic that needs the same fix. Understand your architecture: if CloudFront is in front, it handles HTTPS for users while internal load balancers use HTTP. Local testing of NLB endpoints must use HTTP because NLBs don't have certificates; CloudFront provides the HTTPS layer for production users.

---
