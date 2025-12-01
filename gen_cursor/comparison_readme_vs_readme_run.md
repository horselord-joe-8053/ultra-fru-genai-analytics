# README.md vs README_RUN.md - Dependency Installation Comparison

## Side-by-Side Comparison

### Python Dependencies Installation

| Aspect | README.md | README_RUN.md |
|--------|-----------|---------------|
| **Mentioned?** | ✅ Yes | ❌ No |
| **Location** | Section 4.1 (Local Quickstart) | N/A |
| **Content** | `pip install -r requirements.txt` | Missing |
| **Virtual Environment** | ❌ Not mentioned | ❌ Not mentioned |
| **Verification Step** | ❌ Not mentioned | ❌ Not mentioned |

### Frontend Dependencies Installation

| Aspect | README.md | README_RUN.md |
|--------|-----------|---------------|
| **Mentioned?** | ❌ Not in quickstart | ✅ Yes |
| **Location** | N/A | Section 2.4 |
| **Content** | N/A | `npm install` |
| **Build Step** | N/A | `npm run build` (Section 3) |

### Docker Setup

| Aspect | README.md | README_RUN.md |
|--------|-----------|---------------|
| **Docker Compose** | ✅ Section 4.2 | ✅ Section 2.2 |
| **Dockerfile Reference** | ✅ Implied | ✅ Section 3.1 (example) |
| **Requirements.txt in Docker** | ✅ Implied | ✅ Shown in Dockerfile example |

---

## Extracted Sections

### README.md - Section 4.1

```markdown
## 4.1 Install dependencies

```bash
pip install -r requirements.txt
```
```

**Status:** ✅ Present

---

### README_RUN.md - Section 2 (Local Developer Mode)

**Section 2.1:** Set up environment (`.env` file)
**Section 2.2:** Run Postgres + pgvector + API with Docker
**Section 2.3:** Load CSV into the database
**Section 2.4:** Start frontend (React analytical chat UI)
**Section 2.5:** Using Spark + Delta locally

**Missing:** No step for `pip install -r requirements.txt`

**Status:** ❌ Missing

---

## Impact Analysis

### User Journey Following README_RUN.md

1. ✅ Create `.env` file (Section 2.1)
2. ✅ Run Docker Compose (Section 2.2)
3. ❌ **SKIP:** Install Python dependencies
4. ❌ **FAIL:** Run ETL script (Section 2.3) → `ModuleNotFoundError: No module named 'flask'`
5. ❌ **FAIL:** Run API locally (if attempted) → `ModuleNotFoundError`

### User Journey Following README.md

1. ✅ Install dependencies (Section 4.1) → `pip install -r requirements.txt`
2. ✅ Run pgvector locally (Section 4.2)
3. ✅ Initialize schema (Section 4.3)
4. ✅ Load embeddings (Section 4.4)
5. ✅ Run API locally (Section 4.5)

**Status:** ✅ Complete workflow

---

## Recommendation

**README_RUN.md should include the same dependency installation step as README.md**

**Suggested addition to README_RUN.md Section 2:**

```markdown
### 2.2 Install Python Dependencies

Before running any Python scripts, install the required packages:

```bash
# Optional but recommended: create a virtual environment
python3 -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt
```

> **Note:** This step is required before running ETL scripts (Section 2.3) or the API locally.
```

---

## Conclusion

**README_RUN.md is missing a critical step** that README.md includes. This will cause users following README_RUN.md to encounter errors when trying to run Python scripts.

**Priority:** High - This is a blocking issue for local development setup.

