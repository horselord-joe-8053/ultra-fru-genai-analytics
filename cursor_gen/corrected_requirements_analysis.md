# CORRECTED: Requirements.txt Analysis

## Critical Finding - You Are Correct!

### Missing System-Level Dependency: `psql` Command

**README_RUN.md Section 2.3, Line 134:**
```bash
psql "postgresql://postgres:postgres@localhost:5432/fru_db" -f docs/sql/schema_pgvector.sql
```

**Problem:**
- `psql` is a **PostgreSQL client command-line tool**, NOT a Python package
- `psycopg2-binary` is the Python library to connect to PostgreSQL from Python code
- `psql` is a separate system tool that must be installed separately
- **requirements.txt cannot include system-level tools like `psql`**

### What's Actually Missing

1. **System-level dependency not documented:**
   - `psql` command (PostgreSQL client tools)
   - Installation instructions missing from README_RUN.md

2. **requirements.txt status:**
   - ✅ Contains all **Python packages** needed
   - ❌ Cannot contain system tools like `psql`
   - ⚠️ **README_RUN.md assumes `psql` is installed but never mentions it**

### Installation Options for `psql`

**macOS:**
```bash
brew install postgresql@16
# or
brew install libpq
```

**Linux (Ubuntu/Debian):**
```bash
sudo apt-get install postgresql-client
```

**Windows:**
- Install PostgreSQL from https://www.postgresql.org/download/windows/
- Or use Docker (which includes psql in the container)

**Alternative: Use Docker exec:**
```bash
docker exec -i fru_db psql -U postgres -d fru_db < docs/sql/schema_pgvector.sql
```

### Updated Requirements.txt Status

**Python Packages (✅ Complete):**
- flask
- pyspark
- delta-spark
- boto3
- psycopg2-binary ✅ (Python PostgreSQL adapter)
- openai
- pandas

**System Tools (❌ NOT in requirements.txt, NOT documented):**
- `psql` command-line tool ❌
- PostgreSQL client tools ❌

### What Should Be Added to README_RUN.md

**Section 0 (Prerequisites) should include:**
```markdown
### Local
- Python 3.10+
- Node.js 18+
- Docker Desktop (or compatible)
- **PostgreSQL client tools** (for `psql` command)
  - macOS: `brew install postgresql@16` or `brew install libpq`
  - Linux: `sudo apt-get install postgresql-client`
  - Windows: Install PostgreSQL or use Docker exec alternative
- OpenAI API key
- AWS credentials configured (for Bedrock)
```

**OR provide Docker-based alternative in Section 2.3:**
```markdown
1. Initialize schema (using Docker if psql not installed locally):

   Option A (if psql installed):
   ```bash
   psql "postgresql://postgres:postgres@localhost:5432/fru_db" -f docs/sql/schema_pgvector.sql
   ```

   Option B (using Docker):
   ```bash
   docker exec -i fru_db psql -U postgres -d fru_db < docs/sql/schema_pgvector.sql
   ```
```

### Conclusion

**You are absolutely correct!**

- ✅ `requirements.txt` has all Python packages
- ❌ `requirements.txt` **cannot** include system tools like `psql`
- ❌ **README_RUN.md is incomplete** - it assumes `psql` is available but never mentions installing it
- ❌ **Prerequisites section is missing** the PostgreSQL client tools requirement

**This is a documentation gap, not a requirements.txt gap** (since requirements.txt can only contain Python packages).

---

## Additional Missing Dependencies Check

### Other System-Level Tools Used

Let me check what else might be missing:

1. **`psql`** - ✅ Confirmed missing from documentation
2. **`spark-submit`** - Used in README_RUN.md Section 2.5
   - Requires Apache Spark installation
   - Not a Python package
   - Should be documented in prerequisites

3. **`docker` / `docker compose`** - ✅ Mentioned in prerequisites
4. **`npm` / `node`** - ✅ Mentioned in prerequisites
5. **`aws` CLI** - ⚠️ Used in Section 4.2 but not explicitly in prerequisites

### Complete Missing Prerequisites List

**System Tools (not Python packages):**
- ❌ `psql` (PostgreSQL client) - **CRITICAL MISSING**
- ❌ `spark-submit` (Apache Spark) - Used but not documented
- ⚠️ `aws` CLI - Used in AWS sections but not in prerequisites

**Python Packages:**
- ✅ All covered in requirements.txt

---

## Final Verdict

**requirements.txt:** ✅ Complete for Python packages only

**README_RUN.md Prerequisites:** ❌ **INCOMPLETE** - Missing:
1. PostgreSQL client tools (`psql`)
2. Apache Spark (`spark-submit`)
3. AWS CLI (optional but used)

**You were right to question this!** The documentation assumes system tools are installed without mentioning them.

