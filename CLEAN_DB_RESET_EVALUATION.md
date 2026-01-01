# Evaluation: Clean Database Reset Approach

## Current Situation

**Database Tables:**
1. `fru_sales_embeddings` - Main data table (currently has TEXT for feedback_rating)
2. `batch_analytics` - Spark analytics results (separate table)

**Current Schema File Issues:**
- Lines 47-53: Migration to add missing columns (unnecessary if recreating)
- Lines 55-68: Migration to convert TEXT → INTEGER (unnecessary if recreating)
- Lines 70-78: Index creation (idempotent, can keep)

## Proposed Approach

### 1. Remove Migration Scripts (Lines 47-68)

**Pros:**
- ✅ Simpler schema file
- ✅ No edge cases to handle
- ✅ Cleaner code
- ✅ If recreating table, migrations are unnecessary

**Cons:**
- ⚠️ If someone has existing data, they'd need to reload
- ⚠️ But user wants to delete and recreate anyway

**Verdict: ✅ YES - Remove migrations if we're recreating**

### 2. Drop and Recreate Database/Table

**Option A: Drop Entire Database**
```sql
DROP DATABASE fru_db;
CREATE DATABASE fru_db;
```
- ❌ Too aggressive - loses `batch_analytics` table
- ❌ Requires recreating database, users, permissions
- ❌ More complex

**Option B: Drop Only `fru_sales_embeddings` Table**
```sql
DROP TABLE IF EXISTS fru_sales_embeddings CASCADE;
-- Then run CREATE TABLE from schema
```
- ✅ Keeps `batch_analytics` intact
- ✅ Simpler - just one table
- ✅ Preserves database structure
- ✅ Can be run multiple times safely

**Option C: TRUNCATE Instead of DROP**
```sql
TRUNCATE TABLE fru_sales_embeddings;
-- Then run CREATE TABLE (will use IF NOT EXISTS, so no-op)
```
- ⚠️ Keeps table structure but doesn't fix schema issues
- ⚠️ If column is TEXT, it stays TEXT
- ❌ Doesn't solve the problem

**Verdict: ✅ Option B - Drop only `fru_sales_embeddings` table**

## Recommended Clean Approach

### Step 1: Simplify Schema File
- Remove lines 47-68 (migrations)
- Keep CREATE TABLE (already defines INTEGER)
- Keep index creation (idempotent)

### Step 2: Create Reset Script
- Drop `fru_sales_embeddings` table (CASCADE to drop indexes)
- Run schema file (creates table with correct types)
- Run ETL to repopulate

### Step 3: Update init-db.sh
- Add `--reset` flag option
- Or create separate `reset-db.sh` script

## Potential Issues & Solutions

### Issue 1: Data Loss
- **Risk:** Dropping table loses all data
- **Solution:** ETL repopulates from CSV (user wants this)
- **Mitigation:** Script warns before dropping

### Issue 2: Foreign Key Constraints
- **Risk:** If other tables reference `fru_sales_embeddings`
- **Solution:** Use CASCADE in DROP TABLE
- **Reality:** No foreign keys in current schema

### Issue 3: Index Recreation
- **Risk:** Dropping table drops indexes
- **Solution:** Schema file recreates indexes (idempotent)
- **Reality:** Indexes are recreated automatically

### Issue 4: batch_analytics Data
- **Risk:** Accidentally losing batch_analytics data
- **Solution:** Only drop `fru_sales_embeddings`, not batch_analytics
- **Reality:** batch_analytics is separate, unaffected

## Clean Implementation Plan

### 1. Simplify `sql/schema_pgvector.sql`
```sql
-- Remove lines 47-68 (migrations)
-- Keep CREATE TABLE (already correct)
-- Keep index creation (idempotent)
```

### 2. Create `run_scripts/local/reset-db.sh`
```bash
#!/bin/bash
# Reset fru_sales_embeddings table (drop and recreate)
# WARNING: This will delete all data in fru_sales_embeddings

# 1. Drop table
docker exec fru_db psql -U postgres -d fru_db -c "DROP TABLE IF EXISTS fru_sales_embeddings CASCADE;"

# 2. Recreate schema
./run_scripts/local/init-db.sh

# 3. Repopulate data
./run_scripts/local/load-data.sh
```

### 3. Alternative: Add `--reset` flag to `init-db.sh`
- More integrated
- Single command

## Evaluation Result

✅ **YES - This is a cleaner approach**

**Benefits:**
1. ✅ Simpler schema file (no migrations)
2. ✅ Guaranteed correct schema (fresh table)
3. ✅ No unexpected results (explicit reset)
4. ✅ Preserves batch_analytics
5. ✅ Easy to understand and maintain
6. ✅ Can be run multiple times safely

**Risks:**
1. ⚠️ Data loss (but user wants to repopulate anyway)
2. ⚠️ Need to run ETL after reset (but script handles this)

**Recommendation:**
- ✅ Remove migration scripts (lines 47-68)
- ✅ Create reset script that drops only `fru_sales_embeddings`
- ✅ Recreate schema and repopulate data
- ✅ This is the cleanest approach for local development

