# Silver Layer Transformation Guide

## FreshService Tickets — Bronze → Silver

**Audience:** New team members
**Scope:** Silver layer only — cleaning, typing, and deduplicating bronze data into business-ready entities
**Prerequisite:** Completed the Bronze Layer Ingestion Guide; `bronze.freshservice_tickets` view exists and returns data

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Step 1 — Profile the Bronze Data](#step-1--profile-the-bronze-data)
4. [Step 2 — Define the Silver Data Contract](#step-2--define-the-silver-data-contract)
5. [Step 3 — Build the dbt Silver Model](#step-3--build-the-dbt-silver-model)
6. [Step 4 — Add Schema Documentation and Tests](#step-4--add-schema-documentation-and-tests)
7. [Step 5 — Run and Validate the Silver Model](#step-5--run-and-validate-the-silver-model)
8. [Step 6 — Register the Silver Model in Dagster](#step-6--register-the-silver-model-in-dagster)
9. [Step 7 — Grant BI Access](#step-7--grant-bi-access)
10. [Step 8 — End-to-End Validation](#step-8--end-to-end-validation)
11. [Appendix — AI Prompt Templates](#appendix--ai-prompt-templates)

---

## 1. Overview

The **silver schema** is where raw data becomes trustworthy. Every silver model takes a bronze view as input and applies three categories of transformation:

| Transformation | What it does | Why it matters |
|---|---|---|
| **Type casting** | Converts text fields to proper SQL types (integer, timestamp, boolean) | Enables filtering, sorting, aggregation |
| **Deduplication** | Removes duplicate records using a unique key + recency logic | Airbyte append mode can produce duplicates on re-syncs |
| **Standardization** | Maps coded values to readable labels, normalizes nulls, trims whitespace | Consistent data for downstream consumers |

Silver models are **incremental** — after the initial full load, each subsequent run only processes new or updated records. This keeps run times short as data volume grows.

The flow for this guide:

```
bronze.freshservice_tickets (view)
        ↓
   dbt incremental model
        ↓
silver.freshservice_tickets (table)
        ↓
   Available to gold models + BI (Metabase)
```

**What you will have at the end of this guide:**
- An incremental dbt model at `silver.freshservice_tickets` with proper column types
- Deduplication logic ensuring one row per ticket (latest version wins)
- Schema tests covering uniqueness, not-null constraints, and accepted values
- The model registered in Dagster's asset graph, running after the bronze sync
- `bi_readonly` role granted SELECT access for Metabase dashboards

---

## 2. Prerequisites

| Requirement | How to verify |
|---|---|
| Bronze guide is complete | `SELECT COUNT(*) FROM bronze.freshservice_tickets;` returns rows |
| dbt project compiles | `docker compose exec dagster dbt compile --project-dir /opt/dagster/dbt` succeeds |
| You understand the bronze fields | Run `SELECT * FROM bronze.freshservice_tickets LIMIT 3;` and review the columns |
| Silver schema exists | `SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'silver';` returns a row |

---

## Step 1 — Profile the Bronze Data

Before writing any transformation logic, you need to understand the actual data — its types, distributions, nulls, and edge cases. This step prevents surprises during model development.

### 1a. Run profiling queries

Connect to the database:

```bash
docker compose exec postgres psql -U warehouse -d data_warehouse
```

Run the following queries:

```sql
-- 1. Total record count
SELECT COUNT(*) AS total_rows
FROM bronze.freshservice_tickets;

-- 2. Check for duplicate ticket IDs (critical for dedup logic)
SELECT ticket_id, COUNT(*) AS occurrences
FROM bronze.freshservice_tickets
GROUP BY ticket_id
HAVING COUNT(*) > 1
ORDER BY occurrences DESC
LIMIT 20;

-- 3. Null analysis on key fields
SELECT
    COUNT(*) AS total,
    COUNT(ticket_id) AS has_ticket_id,
    COUNT(subject) AS has_subject,
    COUNT(status) AS has_status,
    COUNT(priority) AS has_priority,
    COUNT(created_at) AS has_created_at,
    COUNT(updated_at) AS has_updated_at,
    COUNT(requester_id) AS has_requester_id,
    COUNT(responder_id) AS has_responder_id,
    COUNT(group_id) AS has_group_id,
    COUNT(category) AS has_category
FROM bronze.freshservice_tickets;

-- 4. Distinct values for categorical fields
SELECT 'status' AS field, status AS value, COUNT(*) AS cnt
FROM bronze.freshservice_tickets GROUP BY status
UNION ALL
SELECT 'priority', priority, COUNT(*)
FROM bronze.freshservice_tickets GROUP BY priority
UNION ALL
SELECT 'source', source, COUNT(*)
FROM bronze.freshservice_tickets GROUP BY source
UNION ALL
SELECT 'type', type, COUNT(*)
FROM bronze.freshservice_tickets GROUP BY type
ORDER BY field, cnt DESC;

-- 5. Date range check
SELECT
    MIN(created_at) AS earliest_ticket,
    MAX(created_at) AS latest_ticket,
    MIN(updated_at) AS earliest_update,
    MAX(updated_at) AS latest_update
FROM bronze.freshservice_tickets;

-- 6. Sample of raw values to verify casting needs
SELECT ticket_id, status, priority, is_escalated, spam,
       created_at, updated_at
FROM bronze.freshservice_tickets
LIMIT 10;
```

### 1b. Document your findings

Record the profiling results — you'll reference them when defining the data contract. Pay special attention to:

- **Duplicates:** How many exist? This confirms whether deduplication is necessary (it almost always is with Airbyte append mode).
- **Null patterns:** Which fields are frequently null? These should be nullable in the silver model.
- **Coded values:** FreshService uses integer codes for `status` (e.g., 2 = Open, 3 = Pending) and `priority` (e.g., 1 = Low, 4 = Urgent). You'll map these in the silver model.
- **Date formats:** Confirm timestamps are in ISO 8601 format so casting to `TIMESTAMP` will work.

> **🤖 AI Prompt — Automated profiling analysis:**
>
> ```
> I'm profiling FreshService ticket data in our bronze layer before
> building the silver model. Here are the results of my profiling queries:
>
> Total rows: [paste count]
>
> Duplicates found:
> [paste duplicate query results]
>
> Null analysis:
> [paste null analysis results]
>
> Distinct values for categorical fields:
> [paste categorical distribution results]
>
> Date ranges:
> [paste date range results]
>
> Sample raw values:
> [paste sample rows]
>
> Based on this profile:
> 1. Which fields need special handling (nulls, edge cases)?
> 2. What deduplication strategy do you recommend?
> 3. What are the FreshService integer code mappings for status,
>    priority, and source fields?
> 4. Are there any data quality red flags I should address?
> ```

---

## Step 2 — Define the Silver Data Contract

The data contract specifies the exact column names, types, and constraints for the silver table. Define this before writing SQL so the model has a clear target.

### 2a. Column specification

Below is the standard silver contract for FreshService tickets. Adjust based on your profiling results.

| Silver Column | Source (Bronze) | SQL Type | Nullable | Notes |
|---|---|---|---|---|
| `ticket_id` | `ticket_id` | `INTEGER` | No | Primary / unique key |
| `subject` | `subject` | `TEXT` | No | Ticket title |
| `description` | `description` | `TEXT` | Yes | HTML body, can be very long |
| `status_code` | `status` | `INTEGER` | No | Raw FreshService code |
| `status_label` | *(derived)* | `TEXT` | No | Mapped label (Open, Pending, etc.) |
| `priority_code` | `priority` | `INTEGER` | No | Raw FreshService code |
| `priority_label` | *(derived)* | `TEXT` | No | Mapped label (Low, Medium, etc.) |
| `source_code` | `source` | `INTEGER` | Yes | Raw FreshService code |
| `source_label` | *(derived)* | `TEXT` | Yes | Mapped label (Email, Portal, etc.) |
| `ticket_type` | `type` | `TEXT` | Yes | Incident, Service Request, etc. |
| `requester_id` | `requester_id` | `INTEGER` | Yes | FK to requesters |
| `responder_id` | `responder_id` | `INTEGER` | Yes | FK to agents |
| `group_id` | `group_id` | `INTEGER` | Yes | FK to groups |
| `department_id` | `department_id` | `INTEGER` | Yes | FK to departments |
| `category` | `category` | `TEXT` | Yes | |
| `sub_category` | `sub_category` | `TEXT` | Yes | |
| `item_category` | `item_category` | `TEXT` | Yes | |
| `is_escalated` | `is_escalated` | `BOOLEAN` | No | Cast from text |
| `is_spam` | `spam` | `BOOLEAN` | No | Cast from text |
| `created_at` | `created_at` | `TIMESTAMP` | No | Ticket creation time |
| `updated_at` | `updated_at` | `TIMESTAMP` | No | Last modification time |
| `due_by` | `due_by` | `TIMESTAMP` | Yes | Resolution due date |
| `first_response_due_by` | `fr_due_by` | `TIMESTAMP` | Yes | First response SLA |
| `_airbyte_emitted_at` | `_airbyte_emitted_at` | `TIMESTAMP` | No | Preserved for lineage |
| `_silver_loaded_at` | *(generated)* | `TIMESTAMP` | No | `now()` at model run time |

### 2b. FreshService code mappings

These are standard FreshService API integer codes. Verify against your own instance if your organization has customized them.

**Status codes:**

| Code | Label |
|---|---|
| 2 | Open |
| 3 | Pending |
| 4 | Resolved |
| 5 | Closed |

**Priority codes:**

| Code | Label |
|---|---|
| 1 | Low |
| 2 | Medium |
| 3 | High |
| 4 | Urgent |

**Source codes:**

| Code | Label |
|---|---|
| 1 | Email |
| 2 | Portal |
| 3 | Phone |
| 7 | Chat |
| 9 | Feedback Widget |
| 10 | Yammer |

> **🤖 AI Prompt — Verifying and extending the data contract:**
>
> ```
> I'm defining a silver data contract for FreshService tickets.
> Here is my draft column specification:
>
> [paste the table above]
>
> And here is a sample of raw bronze data:
>
> [paste 3-5 sample rows from bronze.freshservice_tickets]
>
> Please review and:
> 1. Flag any fields in the bronze data that I missed in my contract
> 2. Confirm the type castings are safe given the sample values
> 3. Verify the FreshService status/priority/source code mappings
>    are complete — are there any codes I'm missing?
> 4. Suggest any additional derived columns that would be useful
>    (e.g., SLA breach flags, response time calculations)
> ```

---

## Step 3 — Build the dbt Silver Model

### 3a. Create the model file

Create `dbt/models/silver/freshservice_tickets.sql`:

> **🤖 AI Prompt — Generating the full silver model:**
>
> ```
> I need a dbt silver incremental model for FreshService tickets.
>
> Architecture context:
> - Source: bronze.freshservice_tickets (a dbt view in the bronze schema)
> - Target: silver.freshservice_tickets (incremental table)
> - Database: PostgreSQL 15
> - dbt adapter: dbt-postgres
>
> Data contract (column spec):
>
> [paste the full column specification table from Step 2a]
>
> Code mappings to apply:
>
> [paste the status, priority, and source mapping tables from Step 2b]
>
> Requirements:
> 1. Use {{ config(materialized='incremental', schema='silver',
>    unique_key='ticket_id') }}
> 2. For incremental runs, filter on updated_at > the max updated_at
>    already in the silver table, using the standard dbt
>    {% if is_incremental() %} pattern
> 3. Deduplicate using ROW_NUMBER() partitioned by ticket_id, ordered
>    by _airbyte_emitted_at DESC — keep only the latest version
> 4. Cast all columns to the types specified in the contract
> 5. Map status, priority, and source codes to labels using CASE
>    statements. Include an 'Unknown' fallback for unrecognized codes
> 6. Add a _silver_loaded_at column set to now()
> 7. Use a CTE-based structure:
>    - CTE 1: source (select from bronze)
>    - CTE 2: filtered (apply incremental filter)
>    - CTE 3: deduplicated (row_number dedup)
>    - CTE 4: typed (all type casts and mappings)
>    - Final SELECT from typed
> 8. Add a comment header explaining the model
>
> Please generate the complete SQL file.
> ```

### 3b. Example silver model structure

Below is a reference implementation. Your AI-generated version should follow this same CTE pattern but will reflect your exact field list.

```sql
-- Silver model: FreshService Tickets
-- Cleans, types, and deduplicates bronze ticket data.
-- Incremental: processes only new/updated records after initial load.

{{ config(
    materialized='incremental',
    schema='silver',
    unique_key='ticket_id',
    incremental_strategy='merge'
) }}

WITH source AS (

    SELECT *
    FROM {{ ref('freshservice_tickets') }}

),

filtered AS (

    SELECT *
    FROM source
    {% if is_incremental() %}
    WHERE updated_at > (
        SELECT COALESCE(MAX(updated_at), '1970-01-01')::text
        FROM {{ this }}
    )
    {% endif %}

),

deduplicated AS (

    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY ticket_id
            ORDER BY _airbyte_emitted_at DESC
        ) AS _row_num
    FROM filtered

),

typed AS (

    SELECT
        -- Primary key
        ticket_id::INTEGER                          AS ticket_id,

        -- Core fields
        NULLIF(TRIM(subject), '')                   AS subject,
        description                                 AS description,

        -- Status mapping
        status::INTEGER                             AS status_code,
        CASE status::INTEGER
            WHEN 2 THEN 'Open'
            WHEN 3 THEN 'Pending'
            WHEN 4 THEN 'Resolved'
            WHEN 5 THEN 'Closed'
            ELSE 'Unknown'
        END                                         AS status_label,

        -- Priority mapping
        priority::INTEGER                           AS priority_code,
        CASE priority::INTEGER
            WHEN 1 THEN 'Low'
            WHEN 2 THEN 'Medium'
            WHEN 3 THEN 'High'
            WHEN 4 THEN 'Urgent'
            ELSE 'Unknown'
        END                                         AS priority_label,

        -- Source mapping
        source::INTEGER                             AS source_code,
        CASE source::INTEGER
            WHEN 1 THEN 'Email'
            WHEN 2 THEN 'Portal'
            WHEN 3 THEN 'Phone'
            WHEN 7 THEN 'Chat'
            WHEN 9 THEN 'Feedback Widget'
            WHEN 10 THEN 'Yammer'
            ELSE 'Unknown'
        END                                         AS source_label,

        -- Classification
        NULLIF(TRIM(type), '')                      AS ticket_type,
        NULLIF(TRIM(category), '')                  AS category,
        NULLIF(TRIM(sub_category), '')              AS sub_category,
        NULLIF(TRIM(item_category), '')             AS item_category,

        -- Relationships (foreign keys)
        requester_id::INTEGER                       AS requester_id,
        responder_id::INTEGER                       AS responder_id,
        group_id::INTEGER                           AS group_id,
        department_id::INTEGER                      AS department_id,

        -- Booleans
        is_escalated::BOOLEAN                       AS is_escalated,
        spam::BOOLEAN                               AS is_spam,

        -- Timestamps
        created_at::TIMESTAMP                       AS created_at,
        updated_at::TIMESTAMP                       AS updated_at,
        due_by::TIMESTAMP                           AS due_by,
        fr_due_by::TIMESTAMP                        AS first_response_due_by,

        -- Lineage
        _airbyte_emitted_at                         AS _airbyte_emitted_at,
        NOW()                                       AS _silver_loaded_at

    FROM deduplicated
    WHERE _row_num = 1

)

SELECT * FROM typed
```

> **Key design decisions explained:**
>
> - **`unique_key='ticket_id'` + `incremental_strategy='merge'`** — On incremental runs, if a ticket already exists in silver with the same `ticket_id`, the new row replaces it. This is how updated tickets flow through.
> - **`ROW_NUMBER()` deduplication** — Airbyte append mode can create multiple rows for the same ticket. We keep only the most recently emitted version.
> - **`NULLIF(TRIM(...), '')`** — Converts empty strings to proper NULLs so downstream queries can use `IS NULL` consistently.
> - **`COALESCE(MAX(updated_at), '1970-01-01')`** — Safe fallback for the very first incremental run when the silver table is empty.
> - **`_silver_loaded_at`** — Audit column that records when each record was processed by the silver model. Useful for debugging pipeline freshness.

---

## Step 4 — Add Schema Documentation and Tests

### 4a. Update `schema.yml`

Open `dbt/models/schema.yml` and add the silver model entry. This serves as both documentation and a test suite.

> **🤖 AI Prompt — Generating schema.yml for the silver model:**
>
> ```
> Generate a dbt schema.yml entry for the silver FreshService tickets model.
>
> Model name: freshservice_tickets (in the silver directory)
> Description: Cleaned, typed, and deduplicated FreshService ticket data.
> One row per ticket, representing the latest known state.
>
> Column list with types:
>
> [paste the full column specification table from Step 2a]
>
> Apply these tests:
> - ticket_id: unique, not_null
> - subject: not_null
> - status_code: not_null, accepted_values [2, 3, 4, 5]
> - status_label: not_null, accepted_values [Open, Pending, Resolved, Closed, Unknown]
> - priority_code: not_null, accepted_values [1, 2, 3, 4]
> - priority_label: not_null, accepted_values [Low, Medium, High, Urgent, Unknown]
> - created_at: not_null
> - updated_at: not_null
> - is_escalated: not_null
> - is_spam: not_null
> - _silver_loaded_at: not_null
>
> Also add a freshness check: warn after 36 hours, error after 72 hours
> based on _silver_loaded_at.
>
> Format as valid YAML that I can paste directly into schema.yml.
> ```

### 4b. Example schema entry

```yaml
  - name: freshservice_tickets
    description: >
      Silver layer: Cleaned, typed, and deduplicated FreshService tickets.
      One row per ticket representing its latest known state.
      Sourced from bronze.freshservice_tickets via Airbyte sync.
    config:
      schema: silver
    columns:
      - name: ticket_id
        description: "Unique FreshService ticket identifier"
        tests:
          - unique
          - not_null

      - name: status_code
        description: "FreshService integer status code"
        tests:
          - not_null
          - accepted_values:
              values: [2, 3, 4, 5]

      - name: status_label
        description: "Human-readable status: Open, Pending, Resolved, Closed"
        tests:
          - not_null

      - name: priority_code
        description: "FreshService integer priority code"
        tests:
          - not_null
          - accepted_values:
              values: [1, 2, 3, 4]

      - name: created_at
        description: "Timestamp when the ticket was created in FreshService"
        tests:
          - not_null

      - name: updated_at
        description: "Timestamp of the last update to the ticket"
        tests:
          - not_null

      # ... additional columns follow the same pattern
```

---

## Step 5 — Run and Validate the Silver Model

### 5a. Full initial run

The first run will process all records from the bronze view (full load):

```bash
# Run only the silver tickets model
docker compose exec dagster dbt run \
  --project-dir /opt/dagster/dbt \
  --select silver.freshservice_tickets

# Run all tests on it
docker compose exec dagster dbt test \
  --project-dir /opt/dagster/dbt \
  --select silver.freshservice_tickets
```

### 5b. Validate the results

```bash
docker compose exec postgres psql -U warehouse -d data_warehouse
```

```sql
-- 1. Row count comparison (silver should equal unique tickets in bronze)
SELECT
    (SELECT COUNT(*) FROM bronze.freshservice_tickets) AS bronze_rows,
    (SELECT COUNT(DISTINCT ticket_id) FROM bronze.freshservice_tickets) AS bronze_unique,
    (SELECT COUNT(*) FROM silver.freshservice_tickets) AS silver_rows;

-- 2. Verify deduplication worked
SELECT ticket_id, COUNT(*) AS cnt
FROM silver.freshservice_tickets
GROUP BY ticket_id
HAVING COUNT(*) > 1;
-- Expected: 0 rows (no duplicates)

-- 3. Verify type casting (these should not error)
SELECT
    ticket_id + 0 AS int_check,
    created_at + INTERVAL '1 day' AS timestamp_check,
    NOT is_escalated AS bool_check
FROM silver.freshservice_tickets
LIMIT 1;

-- 4. Status and priority distribution
SELECT status_label, priority_label, COUNT(*) AS cnt
FROM silver.freshservice_tickets
GROUP BY status_label, priority_label
ORDER BY cnt DESC;

-- 5. Check for 'Unknown' mappings (may indicate new codes)
SELECT 'status' AS field, status_code::TEXT AS code, COUNT(*) AS cnt
FROM silver.freshservice_tickets WHERE status_label = 'Unknown' GROUP BY status_code
UNION ALL
SELECT 'priority', priority_code::TEXT, COUNT(*)
FROM silver.freshservice_tickets WHERE priority_label = 'Unknown' GROUP BY priority_code
UNION ALL
SELECT 'source', source_code::TEXT, COUNT(*)
FROM silver.freshservice_tickets WHERE source_label = 'Unknown' GROUP BY source_code;

-- 6. Confirm _silver_loaded_at is populated
SELECT MIN(_silver_loaded_at), MAX(_silver_loaded_at)
FROM silver.freshservice_tickets;
```

### 5c. Test incremental behavior

To verify that incremental runs work correctly:

1. Note the current row count: `SELECT COUNT(*) FROM silver.freshservice_tickets;`
2. Trigger a new Airbyte sync (Airbyte UI → Sync now)
3. Re-run the silver model: `dbt run --select silver.freshservice_tickets`
4. Check the row count again — it should reflect any new or updated tickets, not a full reload

> **🤖 AI Prompt — Debugging silver model failures:**
>
> ```
> My dbt silver model for FreshService tickets failed during the run.
> Here is the error output:
>
> [paste the full dbt error message]
>
> Model file: dbt/models/silver/freshservice_tickets.sql
> Database: PostgreSQL 15
> Source: bronze.freshservice_tickets view
>
> Here are 5 sample rows from the bronze source:
>
> [paste sample bronze data]
>
> What is causing this error and how do I fix the SQL?
> ```

---

## Step 6 — Register the Silver Model in Dagster

If you followed the Bronze guide, dbt assets are already registered in Dagster via the `@dbt_assets` decorator. Since the silver model references the bronze model with `{{ ref('freshservice_tickets') }}`, Dagster will **automatically** detect the dependency.

### 6a. Verify the asset graph

1. Restart Dagster to pick up the new model: `docker compose restart dagster`
2. Open the **Dagster UI** at `http://localhost:3002`
3. Go to the **Assets** tab → **Asset Graph**
4. You should see a dependency chain:

```
[Airbyte: freshservice sync] → [dbt: freshservice_tickets (bronze)] → [dbt: freshservice_tickets (silver)]
```

### 6b. Test the full pipeline

In Dagster, materialize the **Airbyte asset** for FreshService. This should trigger the full chain:

1. Airbyte syncs fresh data → bronze raw table
2. dbt bronze view refreshes automatically
3. dbt silver incremental model runs

If the silver model does NOT appear in the asset graph, the most likely cause is that Dagster hasn't recompiled the dbt manifest.

> **🤖 AI Prompt — Fixing missing dbt assets in Dagster:**
>
> ```
> I added a new dbt silver model (silver/freshservice_tickets.sql) but
> it doesn't appear in the Dagster asset graph.
>
> Setup:
> - Dagster definitions file: dagster/pipelines/definitions.py
> - dbt project mounted at: /opt/dagster/dbt
> - We use @dbt_assets(manifest_path=...) to load dbt models
> - I have restarted the Dagster container
>
> Here is my current definitions.py:
>
> [paste definitions.py contents]
>
> And my dbt_project.yml:
>
> [paste dbt_project.yml contents]
>
> What do I need to do to get the new silver model to appear?
> Should I regenerate the manifest? Is there a Dagster config change needed?
> ```

### 6c. Regenerate the dbt manifest (if needed)

If assets are missing, regenerate the manifest:

```bash
docker compose exec dagster dbt compile --project-dir /opt/dagster/dbt
docker compose restart dagster
```

Check the Dagster UI again — the silver model should now appear.

---

## Step 7 — Grant BI Access

The `bi_readonly` role should already have SELECT permissions on the silver schema (set up in `init-scripts/01-init-schemas.sql`). Verify and fix if needed.

### 7a. Verify existing permissions

```bash
docker compose exec postgres psql -U warehouse -d data_warehouse
```

```sql
-- Check if bi_readonly can access silver schema
SELECT grantee, privilege_type, table_schema, table_name
FROM information_schema.table_privileges
WHERE table_schema = 'silver'
  AND table_name = 'freshservice_tickets'
  AND grantee = 'bi_readonly';
```

### 7b. Grant permissions if missing

If the query above returns no rows:

```sql
-- Grant access for this table
GRANT SELECT ON silver.freshservice_tickets TO bi_readonly;

-- Ensure future silver tables are also accessible
ALTER DEFAULT PRIVILEGES IN SCHEMA silver
    GRANT SELECT ON TABLES TO bi_readonly;
```

### 7c. Verify in Metabase

1. Open **Metabase** at `http://localhost:3000`
2. Go to **Admin** → **Databases** → your PostgreSQL connection
3. Click **Sync database schema now**
4. Navigate to **New Question** → select the `silver` schema → you should see `freshservice_tickets`
5. Run a quick query to confirm data is visible

---

## Step 8 — End-to-End Validation

| Check | Command / Action | Expected Result |
|---|---|---|
| Silver model runs | `dbt run --select silver.freshservice_tickets` | No errors |
| All tests pass | `dbt test --select silver.freshservice_tickets` | All tests pass |
| No duplicates | `SELECT ticket_id, COUNT(*) ... HAVING COUNT(*) > 1` | 0 rows |
| Row count matches unique bronze | Compare `COUNT(*)` silver vs `COUNT(DISTINCT ticket_id)` bronze | Counts match |
| Types are correct | `\d silver.freshservice_tickets` in psql | Proper integer/timestamp/boolean types |
| No 'Unknown' labels (ideally) | Query for `Unknown` in label columns | 0 rows, or known/expected gaps |
| Incremental works | Sync + re-run → row count changes only for new/updated | No full reload |
| Dagster graph is correct | Asset graph shows bronze → silver dependency | Chain visible |
| BI access works | Metabase can query `silver.freshservice_tickets` | Data visible |
| Dagster schedule triggers full chain | Wait for next scheduled run or trigger manually | Airbyte → bronze → silver all succeed |

---

## Appendix — AI Prompt Templates

### S1. Bronze data profiling analysis

```
I'm profiling FreshService ticket data in our bronze layer before building
the silver model. Here are the results of my profiling queries:

Total rows: [paste count]
Duplicates: [paste duplicate query results]
Null analysis: [paste null analysis results]
Categorical distributions: [paste results]
Date ranges: [paste results]
Sample values: [paste 5-10 sample rows]

Based on this profile:
1. Which fields need special handling (nulls, edge cases)?
2. What deduplication strategy do you recommend?
3. What are the FreshService integer code mappings for status, priority,
   and source fields?
4. Are there any data quality red flags I should address?
```

### S2. Reviewing and extending the data contract

```
I'm defining a silver data contract for FreshService tickets.
Here is my draft column specification:

[paste the column spec table]

And here is a sample of raw bronze data:

[paste 3-5 sample rows]

Please review and:
1. Flag any fields I missed
2. Confirm type castings are safe given the sample values
3. Verify the FreshService code mappings are complete
4. Suggest additional derived columns (SLA breach flags, etc.)
```

### S3. Generating the full silver incremental model

```
I need a dbt silver incremental model for FreshService tickets.

Architecture context:
- Source: bronze.freshservice_tickets (a dbt view in the bronze schema)
- Target: silver.freshservice_tickets (incremental table)
- Database: PostgreSQL 15
- dbt adapter: dbt-postgres

Data contract:
[paste the full column specification table]

Code mappings:
[paste the status, priority, and source mapping tables]

Requirements:
1. materialized='incremental', schema='silver', unique_key='ticket_id',
   incremental_strategy='merge'
2. Incremental filter on updated_at using {% if is_incremental() %}
3. ROW_NUMBER() dedup partitioned by ticket_id, ordered by
   _airbyte_emitted_at DESC
4. Cast all columns per the contract
5. CASE statements for code-to-label mappings with 'Unknown' fallback
6. _silver_loaded_at = now()
7. CTE structure: source → filtered → deduplicated → typed → final SELECT
8. Comment header explaining the model

Generate the complete SQL file.
```

### S4. Generating schema.yml with tests

```
Generate a dbt schema.yml entry for the silver FreshService tickets model.

Model name: freshservice_tickets (in the silver directory)
Description: Cleaned, typed, and deduplicated FreshService ticket data.

Columns: [paste column list]

Tests needed:
- ticket_id: unique, not_null
- status_code: not_null, accepted_values [2, 3, 4, 5]
- priority_code: not_null, accepted_values [1, 2, 3, 4]
- created_at, updated_at: not_null
- is_escalated, is_spam: not_null

Format as valid YAML for schema.yml.
```

### S5. Debugging silver model failures

```
My dbt silver model for FreshService tickets failed. Error output:

[paste full dbt error message]

Model file: dbt/models/silver/freshservice_tickets.sql
Database: PostgreSQL 15
Source: bronze.freshservice_tickets

Sample bronze data (5 rows):
[paste sample data]

What is causing this error and how do I fix the SQL?
```

### S6. Debugging missing Dagster assets

```
I added a new dbt silver model but it doesn't appear in the Dagster
asset graph.

Setup:
- definitions.py: [paste contents]
- dbt_project.yml: [paste contents]
- dbt project at: /opt/dagster/dbt
- Dagster container has been restarted

What do I need to do to make the new model appear? Do I need to
regenerate the manifest?
```

### S7. Adding a new FreshService entity to silver

```
I already have a working silver model for FreshService tickets.
I now need to build a silver model for a new entity: [agents / requesters /
departments / etc.]

Here is the bronze view for this entity:
[paste SELECT * FROM bronze.freshservice_<entity> LIMIT 5]

And the column list:
[paste jsonb_object_keys output]

Following the same patterns as our tickets silver model (incremental,
dedup by ROW_NUMBER, CASE mappings, CTE structure), generate:
1. The silver SQL model
2. The schema.yml entry with tests
3. A list of any code mappings I need to define
```
