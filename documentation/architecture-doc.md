# Data Platform Architecture

**Repo:** https://github.com/siege911/data-platform

## Stack

| Layer | Tool | Purpose |
|-------|------|---------|
| Ingestion | **Airbyte** (separate compose) | UI-configured SaaS connectors → PostgreSQL |
| Storage | **PostgreSQL 15** | Medallion architecture (bronze/silver/gold schemas) |
| Transformation | **dbt Core** (dbt-postgres) | SQL-based bronze→silver→gold transforms |
| Orchestration | **Dagster** | Schedules Airbyte syncs + dbt runs, asset-based |
| BI | **Metabase** | Dashboards on silver/gold tables |
| Monitoring | **Prometheus + Grafana** | Infrastructure & DB metrics via postgres-exporter |
| DB Admin | **pgAdmin** | PostgreSQL UI |

All services run via **Docker Compose** on a single server, connected on a shared `data_platform_network` bridge network.

## Medallion Architecture

- **`bronze` schema** — Raw data from Airbyte. JSONB `_airbyte_data` column per source table. Append-only.
- **`silver` schema** — Cleaned, typed, deduplicated via dbt incremental models. Business entities with proper columns.
- **`gold` schema** — Aggregated/denormalized tables materialized by dbt. BI-ready.

Additional schemas: `airbyte_internal`, `dbt_artifacts`. Separate DBs for `metabase` and `dagster` metadata.

A `bi_readonly` role has SELECT on silver/gold only.

## Folder Structure

```
data-platform/
├── .env                          # Generated passwords (POSTGRES_PASSWORD, GRAFANA_ADMIN_PASSWORD, PGADMIN_PASSWORD)
├── docker-compose.yml            # Core services (postgres, pgadmin, metabase, dagster, prometheus, grafana, postgres-exporter)
├── airbyte/
│   ├── custom-connectors/
│   │   └── entra_connector.yaml  # Custom Entra ID / Microsoft Graph connector
│   └── run-ab-platform.sh        # Separate Airbyte install (own compose)
├── dagster/
│   ├── Dockerfile                # Python 3.11, installs dagster/dbt/airbyte packages
│   ├── dagster.yaml              # SQLite-backed storage config
│   ├── workspace.yaml            # Points to /opt/dagster/app/pipelines/definitions.py
│   └── pipelines/
│       └── definitions.py        # Dagster Definitions: assets, jobs, schedules, resources
├── dbt/
│   ├── dbt_project.yml           # Project config (model materializations per schema)
│   ├── profiles.yml              # Postgres connection (uses env vars)
│   └── models/
│       ├── bronze/               # Views over raw Airbyte tables
│       ├── silver/               # Incremental cleaned models
│       └── schema.yml            # Column docs + tests (unique, not_null)
├── init-scripts/
│   └── 01-init-scripts.sql       # Creates schemas, roles, permissions on first boot
├── prometheus/
│   └── prometheus.yml            # Scrape configs (self + postgres-exporter)
├── grafana/
│   └── provisioning/datasources/ # Auto-provisions Prometheus + PostgreSQL datasources
├── scripts/
│   ├── bronze_schema.py          # Introspects and exports bronze schema to CSV
│   ├── golden_user_record.sql    # SQL for building the golden user record
│   └── schema_output/            # CSV exports of bronze schema + sample rows
└── documentation/
    ├── architecture-doc.md       # This document
    ├── bronze-layer-guide.md
    ├── silver-layer-guide.md
    ├── gold-layer-guide.md
    ├── docker-setup-guide.md
    └── data-pipeline-plan.md
```

## Key Service Ports

| Service | Port |
|---------|------|
| PostgreSQL | 5432 |
| Metabase | 3000 |
| Grafana | 3001 |
| Dagster | 3002 |
| pgAdmin | 5050 |
| Airbyte | 8000 |
| Prometheus | 9090 |

## Dagster ↔ Airbyte ↔ dbt Integration

Dagster orchestrates the pipeline using `dagster-airbyte` and `dagster-dbt`:

1. **Airbyte assets** — `airbyte_assets(connection_id=...)` triggers syncs, loads to bronze schema
2. **dbt assets** — `@dbt_assets(manifest_path=...)` runs dbt build (bronze→silver→gold)
3. **Schedules** — Cron-based (e.g., `0 6 * * *` daily at 6 AM)

Dagster connects to Airbyte at `host.docker.internal:8000`. dbt project is mounted at `/opt/dagster/dbt`.

## dbt Conventions

- Bronze models: `materialized='view'`, schema `bronze`
- Silver models: `materialized='incremental'`, schema `silver`, with `unique_key`
- Gold models: `materialized='table'`, schema `gold`
- All models documented in `schema.yml` with tests
- Profiles use `{{ env_var('POSTGRES_USER') }}` / `{{ env_var('POSTGRES_PASSWORD') }}`

## Common Commands

```bash
docker compose up -d                    # Start core stack
docker compose exec postgres psql -U warehouse -d data_warehouse
docker compose exec dagster dbt run --project-dir /opt/dagster/dbt
docker compose exec dagster dbt test --project-dir /opt/dagster/dbt
cd airbyte && ./run-ab-platform.sh -d   # Start Airbyte separately
./scripts/health_check.sh
./scripts/backup.sh
```

---

## Golden Record: Staff Identity Architecture

This section describes the platform's canonical approach to representing internal staff across all connected SaaS systems. The goal is a single, reliable "golden record" for every staff member that all other data references, avoiding duplication of common fields like name, email, and phone across SaaS tables.

### Design Principles

1. **Microsoft 365 (Microsoft Graph API) is the authoritative spine.** M365/Entra ID is the organization's identity provider. It is the most reliably maintained source of staff data because it gates login access. All staff records originate from M365.
2. **The legacy ERP enriches specific fields only.** The ERP is not a co-equal authority. It supplements fields that M365 lacks (e.g., `erp_employee_id`, `hire_date`). When the ERP is replaced, the enrichment join is updated in a single dbt model — no downstream changes required.
3. **`staff_id` is a platform-owned UUID.** It is not the M365 object ID or any source system key. This insulates every downstream FK from source system changes.
4. **Email (lowercased, trimmed) is the universal natural key** used to match staff across systems. All SaaS silver models resolve their native user identifiers to `staff_id` via email matching through the cross-reference table.
5. **SaaS silver tables do NOT duplicate common staff fields.** They store only source-specific business data plus a `staff_id` FK. Name, email, department, job title, and other common fields live exclusively in `silver.stg_staff`.

### Golden Record Tables

#### `silver.stg_staff` — The Golden Record

The single source of truth for staff identity. Built by a dbt incremental model that joins M365 bronze data with ERP bronze data, applying field-level COALESCE logic.

| Column | Type | Source | Notes |
|--------|------|--------|-------|
| `staff_id` | UUID PK | Generated | Platform-owned surrogate key. **This is the FK target for all other tables.** |
| `ms_graph_id` | VARCHAR(255) | M365 | Entra ID object ID. Unique. |
| `erp_employee_id` | VARCHAR(100) | ERP | Nullable — not all staff exist in ERP. |
| `email` | VARCHAR(320) | M365 | Lowercased, trimmed. Unique. Universal match key. |
| `first_name` | VARCHAR(150) | M365 | |
| `last_name` | VARCHAR(150) | M365 | |
| `display_name` | VARCHAR(300) | M365 | |
| `job_title` | VARCHAR(255) | COALESCE(ERP, M365) | ERP preferred if populated. |
| `department` | VARCHAR(255) | COALESCE(ERP, M365) | ERP preferred if populated. |
| `manager_staff_id` | UUID FK | M365 | Self-referencing FK to manager's `staff_id`. |
| `phone` | VARCHAR(50) | COALESCE(M365, ERP) | M365 preferred. |
| `is_active` | BOOLEAN | M365 | Derived from Entra ID account enabled flag. |
| `_source_updated_at` | TIMESTAMPTZ | Upstream | Most recent source system timestamp. |
| `_loaded_at` | TIMESTAMPTZ | dbt | First insert timestamp. |
| `_updated_at` | TIMESTAMPTZ | dbt | Last update timestamp. |

#### `silver.staff_source_xref` — Cross-Reference Map

Maps each `staff_id` to the native user ID in every connected SaaS system. One row per staff member per source system.

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID PK | Row surrogate key. |
| `staff_id` | UUID FK | References `silver.stg_staff.staff_id`. |
| `source_system` | VARCHAR(100) | Canonical source name (see naming conventions below). |
| `source_user_id` | VARCHAR(500) | The user's native ID in the source system. |
| `_loaded_at` | TIMESTAMPTZ | First insert timestamp. |
| `_updated_at` | TIMESTAMPTZ | Last update timestamp. |

**Unique constraints:**
- `(source_system, source_user_id)` — a source user ID cannot map to multiple staff records.
- `(staff_id, source_system)` — a staff member cannot have multiple entries for the same source.

#### `gold.dim_staff` — BI-Ready Staff Dimension

Denormalized view of `stg_staff` with resolved manager fields and derived convenience columns. Materialized as a dbt table model.

| Column | Type | Notes |
|--------|------|-------|
| All columns from `stg_staff` | | Carried forward. |
| `full_name` | VARCHAR(300) | Derived: `first_name \|\| ' ' \|\| last_name`. |
| `manager_display_name` | VARCHAR(300) | Resolved via self-join on `manager_staff_id`. |
| `manager_email` | VARCHAR(320) | Resolved via self-join on `manager_staff_id`. |

### Source System Naming Conventions

When registering a source system in `staff_source_xref.source_system`, use these canonical lowercase names. AI agents adding new SaaS integrations must follow this convention:

| Source System | `source_system` value | Typical `source_user_id` |
|---------------|-----------------------|--------------------------|
| Microsoft 365 | `microsoft_365` | Entra ID object ID (UUID) |
| Legacy ERP | `erp_legacy` | Employee ID string |
| HubSpot | `hubspot` | HubSpot owner ID |
| Salesforce | `salesforce` | Salesforce User ID (18-char) |
| Jira | `jira` | Atlassian account ID |
| Slack | `slack` | Slack member ID (e.g., `U0123ABCDEF`) |
| Zendesk | `zendesk` | Zendesk user ID |
| QuickBooks | `quickbooks` | QuickBooks employee ID |

When adding a new SaaS source not listed above, use the format `{product_name}` in lowercase with underscores (e.g., `google_workspace`, `asana`, `monday_com`). Register the mapping in the dbt xref model and add the canonical name to this table.

---

## Guide for AI Agents: Building SaaS Data Through the Medallion Layers

This section provides explicit instructions for AI agents building dbt models and Python scripts that integrate new SaaS data sources into the platform. Follow these rules precisely.

### Step 1: Bronze Layer — Raw Ingestion

Airbyte loads raw SaaS data into the `bronze` schema. Each Airbyte connection creates tables with a JSONB `_airbyte_data` column.

**Bronze dbt models** are `materialized='view'` and exist only to provide a stable interface over the raw Airbyte tables. They should:

- Reference the raw Airbyte table as a source in `schema.yml`.
- Extract fields from `_airbyte_data` using `_airbyte_data->>'field_name'` syntax.
- Apply no cleaning, casting, or deduplication. That is the silver layer's job.
- Follow the naming convention: `bronze_{source_system}_{entity}` (e.g., `bronze_hubspot_deals`, `bronze_jira_issues`).

### Step 2: Silver Layer — Clean, Type, Deduplicate, and Link to Staff

Silver models are `materialized='incremental'` with a `unique_key`. This is where data is cleaned and linked to the golden record.

**Critical rules for silver models involving user/staff data:**

1. **Do NOT include common staff fields in the silver table.** Do not carry `user_name`, `user_email`, `first_name`, `last_name`, `phone`, `department`, or `job_title` from the SaaS source into the silver model. These fields live exclusively in `silver.stg_staff`.

2. **Resolve the SaaS user to `staff_id`.** Join to `silver.staff_source_xref` on the SaaS system's native user ID to obtain the `staff_id` FK. Example:

    ```sql
    SELECT
        h.deal_id,
        h.deal_name,
        h.amount,
        h.stage,
        h.close_date,
        xref.staff_id AS owner_staff_id,   -- FK to stg_staff
        h._airbyte_extracted_at AS _source_updated_at,
        CURRENT_TIMESTAMP AS _loaded_at
    FROM {{ ref('bronze_hubspot_deals') }} h
    LEFT JOIN {{ ref('stg_staff_source_xref') }} xref
        ON xref.source_system = 'hubspot'
        AND xref.source_user_id = h.hubspot_owner_id
    ```

3. **If the xref entry does not yet exist**, the `LEFT JOIN` will produce a `NULL` `staff_id`. This is acceptable — it indicates a user mapping gap that should be investigated, not a data pipeline failure. **Never fall back to duplicating staff fields to fill the gap.**

4. **If a SaaS entity has multiple user references** (e.g., a Jira issue has `assignee`, `reporter`, and `creator`), resolve each one to a separate `staff_id` column:

    ```sql
    xref_assignee.staff_id AS assignee_staff_id,
    xref_reporter.staff_id AS reporter_staff_id,
    xref_creator.staff_id  AS creator_staff_id,
    ```

    Each requires its own join to `staff_source_xref`.

5. **Populate the xref table.** When building a new SaaS integration, create or update a dbt model that inserts rows into `staff_source_xref` for that source system. The model should:
    - Extract the native user ID and user email from the SaaS bronze data.
    - Match to `silver.stg_staff` on `LOWER(TRIM(email))`.
    - Insert `(staff_id, source_system, source_user_id)`.
    - Use `materialized='incremental'` with `unique_key=['source_system', 'source_user_id']`.

    Example pattern:

    ```sql
    SELECT
        staff.staff_id,
        'hubspot' AS source_system,
        hub_users.hubspot_owner_id AS source_user_id
    FROM {{ ref('bronze_hubspot_owners') }} hub_users
    INNER JOIN {{ ref('stg_staff') }} staff
        ON LOWER(TRIM(hub_users.email)) = staff.email
    ```

6. **Silver model naming convention:** `silver_{source_system}_{entity}` (e.g., `silver_hubspot_deals`, `silver_jira_issues`).

### Step 3: Gold Layer — Denormalize for BI

Gold models are `materialized='table'`. They join silver tables with `gold.dim_staff` to produce BI-ready, fully denormalized datasets.

**Rules for gold models:**

1. **Join to `gold.dim_staff`** (not `silver.stg_staff`) to resolve staff fields. `dim_staff` already contains resolved manager names and derived fields.

2. **Include the staff fields that BI users need** directly in the gold table. This is the appropriate place for denormalization. Example:

    ```sql
    SELECT
        d.deal_id,
        d.deal_name,
        d.amount,
        d.stage,
        d.close_date,
        staff.display_name AS deal_owner_name,
        staff.email        AS deal_owner_email,
        staff.department   AS deal_owner_department,
        staff.is_active    AS deal_owner_is_active
    FROM {{ ref('silver_hubspot_deals') }} d
    LEFT JOIN {{ ref('dim_staff') }} staff
        ON staff.staff_id = d.owner_staff_id
    ```

3. **Gold model naming convention:** `gold_{domain}_{entity}` (e.g., `gold_sales_deals`, `gold_support_tickets`). Group by business domain, not source system.

### Summary: Where Staff Data Lives at Each Layer

| Layer | Staff data handling |
|-------|---------------------|
| **Bronze** | Raw user fields from SaaS exist as-is in JSONB. No transformation. |
| **Silver** | Common staff fields are **stripped out**. Only `staff_id` FK is retained. Staff identity lives exclusively in `silver.stg_staff`. The xref table maps source user IDs → `staff_id`. |
| **Gold** | Staff fields are **denormalized back in** via joins to `gold.dim_staff`. BI consumers get self-contained tables with no joins required. |

### Common Mistakes to Avoid

- **Do not** store `user_email`, `user_name`, or other staff attributes in silver SaaS tables. Always use the `staff_id` FK.
- **Do not** join silver SaaS models directly to `silver.stg_staff` to resolve names. Use `staff_source_xref` to get the `staff_id`, and defer name resolution to the gold layer.
- **Do not** create a new staff/user table per SaaS source. All staff identity flows through `silver.stg_staff`.
- **Do not** use the M365 object ID or any source-native user ID as a foreign key in silver models. Always use the platform-owned `staff_id` UUID.
- **Do not** hard-code email matching in silver SaaS models. The xref table is the lookup mechanism. Build/update the xref model for the source, then join to xref in the silver entity model.
- **Do not** skip the `LEFT JOIN` to xref and substitute a direct email match in silver SaaS models. The xref exists to centralize and audit the mapping. Direct email matching in individual silver models creates fragile, inconsistent linkage logic.