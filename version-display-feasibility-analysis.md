# Feasibility Analysis: Multi-Component Version Display

## Executive Summary

**Feasibility: ✅ YES - Feasible with minimal refactoring**

The refactor is feasible and straightforward. However, there's an important architectural clarification: there is **only ONE backend Docker image** (monolith), not separate Query/Analytics images. The display would show:
- Frontend version (already available)
- Backend version (needs to be fetched at runtime)

---

## Current Architecture

### 1. Frontend Component
- **Type**: Static build (deployed to S3, served via CloudFront)
- **Version Format**: `V_YYMMDD-HHMMSS_PROVIDER_CONTAINER_ENV`
- **Example**: `V_260122-124223_aws_eks_dev`
- **Generation**: At **build time** via Vite config injection
- **Location**: `frontend/src/utils/version.ts` → `getBuildVersion()`
- **Display**: Currently shown in `Chat.tsx` component header

### 2. Backend Component
- **Type**: Single Docker image (monolithic application)
- **Image Name**: `fru-api`
- **Tag Format**: `fru-{env}-{date}-{sha}[-dirty-{hash}]`
- **Example**: `fru-dev-20260124-6b038d3-dirty-20260124214543`
- **Generation**: At **deployment time** from git commit SHA
- **Endpoints**: Contains `/query`, `/analytics`, `/query/stream` (all in one container)
- **Current Deployed**: `744139897900.dkr.ecr.us-east-1.amazonaws.com/fru-api:fru-dev-20260124-6b038d3-dirty-20260124214543`

### 3. Key Finding
**There is NO separate "Backend_Query" or "Backend_Analytics" image.** The backend is a monolith with multiple endpoints. The version display would be:
```
Frontend: V_260122-124223_aws_eks_dev
Backend: fru-dev-20260124-6b038d3-dirty-20260124214543
```

---

## Challenge: Timing Mismatch

### Problem
- **Frontend version**: Known at **build time** (static, baked into bundle)
- **Backend version**: Known at **deployment time** (dynamic, changes per deployment)
- **Frontend is built BEFORE backend is deployed**
- **Frontend is static files** (no server-side rendering)

### Implication
The backend version **cannot** be injected at frontend build time because:
1. Frontend build happens during deployment script execution
2. Backend image tag is generated during the same deployment
3. Even if we knew it, frontend is already built and deployed to S3

---

## Solution: Runtime Fetch (Recommended)

### Approach
Add a `/version` endpoint to the backend that returns its image tag, then fetch it from the frontend at runtime.

### Implementation Steps

1. **Backend Changes** (Minimal):
   - Add `/version` endpoint to `backend/api/app.py`
   - Read image tag from environment variable (injected by Kubernetes)
   - Return JSON: `{"version": "fru-dev-20260124-6b038d3-dirty-20260124214543"}`

2. **Kubernetes Changes** (Minimal):
   - Inject `CONTAINER_IMAGE` as environment variable in deployment manifest
   - Already available in template: `${CONTAINER_IMAGE}`

3. **Frontend Changes** (Minimal):
   - Modify `frontend/src/utils/version.ts` to add `getBackendVersion()` function
   - Fetch from `/version` endpoint (or `/health` if we add it there)
   - Update `Chat.tsx` to display both versions
   - Handle loading/error states gracefully

### Complexity Assessment
- **Backend**: ~5-10 lines of code
- **Kubernetes**: Already has `${CONTAINER_IMAGE}` variable
- **Frontend**: ~20-30 lines of code (fetch + display logic)

---

## Alternative Solutions (Not Recommended)

### Option A: Build-Time Injection
- **Problem**: Requires knowing backend version before frontend build
- **Complexity**: High (requires orchestration changes)
- **Verdict**: ❌ Not feasible with current architecture

### Option B: Kubernetes API Query
- **Problem**: Requires authentication, CORS, complexity
- **Complexity**: High
- **Verdict**: ❌ Overkill for this use case

### Option C: Config File in S3
- **Problem**: Requires deployment script to write file, sync issues
- **Complexity**: Medium
- **Verdict**: ⚠️ Possible but more complex than runtime fetch

---

## Recommended Implementation

### Display Format
```
Frontend: V_260122-124223_aws_eks_dev
Backend: fru-dev-20260124-6b038d3-dirty-20260124214543
```

### Code Changes Summary

1. **Backend** (`backend/api/app.py`):
   ```python
   @app.route("/version", methods=["GET"])
   def version():
       image_tag = os.environ.get("CONTAINER_IMAGE", "unknown")
       # Extract tag from full URI if needed
       return {"version": image_tag.split(":")[-1] if ":" in image_tag else image_tag}
   ```

2. **Kubernetes** (`infra/k8s/templates/deployment.template.yaml`):
   - Already has `${CONTAINER_IMAGE}` - just need to expose as env var:
   ```yaml
   env:
     - name: CONTAINER_IMAGE
       value: ${CONTAINER_IMAGE}
   ```

3. **Frontend** (`frontend/src/utils/version.ts`):
   - Add async function to fetch backend version
   - Cache result to avoid repeated calls

4. **Frontend** (`frontend/src/components/Chat.tsx`):
   - Update display to show both versions on separate lines

---

## Risks & Considerations

### 1. Network Dependency
- Frontend must be able to reach backend `/version` endpoint
- **Mitigation**: Graceful fallback if fetch fails (show "Backend: unavailable")

### 2. CORS
- Backend must allow CORS for `/version` endpoint
- **Mitigation**: Already configured for other endpoints, just extend

### 3. Caching
- Frontend should cache backend version to avoid repeated calls
- **Mitigation**: Cache in component state or localStorage

### 4. Version Format Mismatch
- Frontend uses `V_...` format, backend uses `fru-...` format
- **Mitigation**: Display as-is (different formats are acceptable) or normalize

---

## Conclusion

✅ **Feasible**: Yes, with minimal refactoring (~50-60 lines total)

✅ **Complexity**: Low - straightforward runtime fetch pattern

✅ **Risk**: Low - graceful error handling makes it safe

⚠️ **Clarification**: Only ONE backend image (monolith), not separate Query/Analytics images

**Recommended Approach**: Runtime fetch via `/version` endpoint (Option: Runtime Fetch)

**Estimated Effort**: 1-2 hours for implementation + testing
