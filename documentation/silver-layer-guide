# Silver Layer Setup — Staff Golden Record

## What This Builds

| Model | Schema | Purpose |
|---|---|---|
| `bronze_entraid_users` | `bronze` (view) | Snake_case interface over the raw Airbyte Entra ID table |
| `stg_staff` | `silver` (incremental) | Golden record — one row per internal staff member |
| `staff_source_xref` | `silver` (incremental) | Maps staff_id → native user IDs per SaaS system |

dbt creates and manages all tables. No manual SQL required.

---

## Prerequisites

```bash
# Stack is running
docker compose ps

# Airbyte has synced Entra ID data
docker compose exec postgres psql -U warehouse -d data_warehouse \
  -c 'SELECT COUNT(*) FROM bronze.entra_idusers;'

# dbt project compiles
docker compose exec dagster dbt compile \
  --project-dir /opt/dagster/dbt \
  --profiles-dir /opt/dagster/dbt
```

If silver schema or uuid-ossp extension don't exist yet (they should from init-scripts):

```bash
docker compose exec postgres psql -U warehouse -d data_warehouse \
  -c "CREATE SCHEMA IF NOT EXISTS silver; CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";"
```

---

## Step 1 — Copy Files Into Your dbt Project

From your `data-platform/` repo root:

```bash
# Bronze source definition
cp bronze/sources.yml               dbt/models/bronze/sources.yml

# Bronze view model
cp bronze/bronze_entraid_users.sql  dbt/models/bronze/bronze_entraid_users.sql

# Silver models
cp silver/stg_staff.sql             dbt/models/silver/stg_staff.sql
cp silver/staff_source_xref.sql     dbt/models/silver/staff_source_xref.sql

# Schema — REPLACES the existing placeholder schema.yml
cp schema.yml                       dbt/models/schema.yml
```

| Delivered file | Copy to | Action |
|---|---|---|
| `bronze/sources.yml` | `dbt/models/bronze/sources.yml` | New file |
| `bronze/bronze_entraid_users.sql` | `dbt/models/bronze/bronze_entraid_users.sql` | New file |
| `silver/stg_staff.sql` | `dbt/models/silver/stg_staff.sql` | New file |
| `silver/staff_source_xref.sql` | `dbt/models/silver/staff_source_xref.sql` | New file |
| `schema.yml` | `dbt/models/schema.yml` | **Replaces** placeholder |

---

## Step 2 — Verify dbt_project.yml

Confirm bronze + silver materialization defaults exist in `dbt/dbt_project.yml`:

```yaml
models:
  your_project_name:
    bronze:
      +materialized: view
      +schema: bronze
    silver:
      +materialized: incremental
      +schema: silver
```

---

## Step 3 — Build Everything

```bash
docker compose exec dagster dbt run \
  --project-dir /opt/dagster/dbt \
  --profiles-dir /opt/dagster/dbt \
  --select bronze_entraid_users stg_staff staff_source_xref
```

---

## Step 4 — Run Tests

```bash
docker compose exec dagster dbt test \
  --project-dir /opt/dagster/dbt \
  --profiles-dir /opt/dagster/dbt \
  --select bronze_entraid_users stg_staff staff_source_xref
```

---

## Step 5 — Quick Validation

```bash
docker compose exec postgres psql -U warehouse -d data_warehouse
```

```sql
SELECT
    (SELECT COUNT(*) FROM bronze.entra_idusers) AS bronze_rows,
    (SELECT COUNT(*) FROM silver.stg_staff) AS silver_staff,
    (SELECT COUNT(*) FROM silver.staff_source_xref) AS silver_xref;

-- Spot check — you should now see real job titles and departments
SELECT staff_id, email, display_name, job_title, department, is_active, phone
FROM silver.stg_staff ORDER BY email LIMIT 10;
```

---

## Step 6 — Refresh Dagster

```bash
docker compose exec dagster dbt compile \
  --project-dir /opt/dagster/dbt \
  --profiles-dir /opt/dagster/dbt
docker compose restart dagster
```

Open Dagster at `http://localhost:3002` → **Assets** → **Asset Graph**.

---

## Step 7 — Grant BI Access (if needed)

```bash
docker compose exec postgres psql -U warehouse -d data_warehouse \
  -c "ALTER DEFAULT PRIVILEGES IN SCHEMA silver GRANT SELECT ON TABLES TO bi_readonly;
      GRANT SELECT ON ALL TABLES IN SCHEMA silver TO bi_readonly;"
```

---

## Fields Now Populated

With the full Entra ID field set, the golden record is much richer than initially expected:

| Golden Record Column | Source Field | Status |
|---|---|---|
| `email` | `mail` (falls back to `userPrincipalName`) | ✅ Populated |
| `first_name` | `givenName` | ✅ Populated |
| `last_name` | `surname` | ✅ Populated |
| `display_name` | `displayName` | ✅ Populated |
| `job_title` | `jobTitle` | ✅ Populated |
| `department` | `department` | ✅ Populated |
| `phone` | `mobilePhone` → `businessPhones[0]` | ✅ Populated |
| `is_active` | `accountEnabled` | ✅ Populated |
| `erp_employee_id` | `employeeId` | ✅ Populated (if set in Entra ID) |
| `manager_staff_id` | Requires Graph API `manager` expansion | ❌ NULL |

The only remaining gap is `manager_staff_id`, which requires expanding the Airbyte Entra ID stream to include the `manager` relationship.

**Do not run `dbt run --full-refresh` on `stg_staff`.** This regenerates all `staff_id` UUIDs, breaking downstream FKs.