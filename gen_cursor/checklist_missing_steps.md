# Quick Checklist: Missing Steps in README_RUN.md

## Critical Missing Steps

### ❌ Section 2: Local Developer Mode

**MISSING:** Python dependency installation step

**Should be added after Section 2.1 (Set up environment):**

```markdown
### 2.2 Install Python Dependencies

Create a virtual environment (recommended):

```bash
python3 -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate
```

Install required packages:

```bash
pip install -r requirements.txt
```

Verify installation:

```bash
python -c "import flask, psycopg2, openai, boto3, pandas; print('✓ All dependencies installed')"
```
```

**Impact:** Users will get `ModuleNotFoundError` when trying to run ETL or API scripts.

---

## Requirements.txt Issues

### ⚠️ No Version Pinning

**Current:**
```
flask
pyspark
delta-spark
boto3
psycopg2-binary
openai
pandas
```

**Recommended:**
```
flask>=2.3.0,<3.0.0
pyspark>=3.4.0
delta-spark>=3.0.0
boto3>=1.28.0
psycopg2-binary>=2.9.0
openai>=1.0.0
pandas>=2.0.0
```

**Impact:** Potential breaking changes when dependencies update.

---

## Documentation Inconsistencies

| File | Python Dependencies Mentioned? |
|------|--------------------------------|
| README.md | ✅ Yes (Section 4.1) |
| README_RUN.md | ❌ No |

**Impact:** Confusion for users following different documentation paths.

---

## Where Requirements.txt is Referenced

1. ✅ `infra/docker/Dockerfile.api` - Line 5-6 (correctly used)
2. ✅ `README.md` - Section 4.1 (mentions installation)
3. ❌ `README_RUN.md` - **NOT mentioned anywhere**

---

## Quick Fix Summary

1. **Add Section 2.2** to README_RUN.md with Python dependency installation
2. **Renumber** subsequent sections (2.2→2.3, 2.3→2.4, etc.)
3. **Consider** adding version pinning to requirements.txt
4. **Consider** adding virtual environment instructions

---

**Status:** Requirements.txt is functionally complete but README_RUN.md is missing the installation step.

