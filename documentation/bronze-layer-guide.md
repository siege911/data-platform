# Bronze Layer Ingestion Guide

## FreshService Ticket Data → PostgreSQL (Bronze Schema)

**Audience:** New team members  
**Scope:** Bronze layer only — raw data landing from FreshService API into PostgreSQL via Airbyte  
**Architecture Reference:** See `architecture-doc.md` in the repo root

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Step 1 — Obtain FreshService API Credentials](#step-1--obtain-freshservice-api-credentials)
4. [Step 2 — Verify the API Connection Locally](#step-2--verify-the-api-connection-locally)
5. [Step 3 — Configure the Airbyte Source (FreshService)](#step-3--configure-the-airbyte-source-freshservice)
6. [Step 4 — Configure the Airbyte Destination (PostgreSQL)](#step-4--configure-the-airbyte-destination-postgresql)
7. [Step 5 — Create the Airbyte Connection](#step-5--create-the-airbyte-connection)
8. [Step 6 — Run an Initial Sync and Validate](#step-6--run-an-initial-sync-and-validate)
9. [Step 7 — Register the Connection in Dagster](#step-7--register-the-connection-in-dagster)
10. [Step 8 — Create the dbt Bronze Model](#step-8--create-the-dbt-bronze-model)
11. [Step 9 — End-to-End Validation](#step-9--end-to-end-validation)
12. [Appendix — AI Prompt Templates](#appendix--ai-prompt-templates)

---

## 1. Overview

In our medallion architecture the **bronze schema** is the raw landing zone. Data arrives here exactly as the source API provides it — no transformations, no deduplication. Airbyte handles extraction and loading; dbt provides a thin view on top for downstream consumption.

The flow for this guide:

```
FreshService API  →  Airbyte (extract & load)  →  PostgreSQL bronze schema  →  dbt bronze view
                                                        ↑
                                                  Dagster orchestrates
```

**What you will have at the end of this guide:**
- A working Airbyte connection syncing FreshService ticket data into `bronze._airbyte_raw_tickets`
- A Dagster asset that triggers the sync on schedule
- A dbt bronze view (`bronze.freshservice_tickets`) exposing the raw JSONB data

---

## 2. Prerequisites

Before starting, confirm the following:

| Requirement | How to verify |
|---|---|
| Docker Compose stack is running | `docker compose ps` — all services should show `Up` |
| Airbyte is running | `cd airbyte && docker compose ps` — or open `http://localhost:8000` |
| You have access to the `.env` file | `cat .env` in the repo root — you'll need `POSTGRES_PASSWORD` |
| You have a FreshService admin account | You need permission to generate API keys |
| You can reach pgAdmin | Open `http://localhost:5050` and log in |

If any service is down, start the stack:

```bash
# Core services
docker compose up -d

# Airbyte (separate compose)
cd airbyte && ./run-ab-platform.sh -d
```

---

## Step 1 — Obtain FreshService API Credentials

FreshService uses API key authentication (passed as the username in HTTP Basic Auth, with `X` as the password).

1. **Log into your FreshService portal** at `https://<your-domain>.freshservice.com`
2. Click your **profile icon** (top right) → **Profile Settings**
3. On the right side of the profile page, locate **Your API Key**
4. Click **Show API Key** and copy it
5. Store the key securely. You will need two values going forward:

| Value | Example |
|---|---|
| **API Key** | `abcDEF123ghiJKL456` |
| **Domain** | `yourcompany` (from `yourcompany.freshservice.com`) |

> **Security note:** Never commit API keys to the repository. They will be entered directly into Airbyte's encrypted credential store.

---

## Step 2 — Verify the API Connection Locally

Before configuring Airbyte, confirm that the API key works and you can see ticket data. This helps isolate problems early.

Open a terminal and run:

```bash
curl -u "YOUR_API_KEY:X" \
  "https://YOUR_DOMAIN.freshservice.com/api/v2/tickets?per_page=2" \
  | python3 -m json.tool
```

Replace `YOUR_API_KEY` and `YOUR_DOMAIN` with your actual values.

**Expected result:** A JSON response containing a `tickets` array with ticket objects. If you get a `401` error, your API key is incorrect. If you get a `404`, check your domain.

Take note of the fields returned in each ticket object (e.g., `id`, `subject`, `status`, `priority`, `created_at`, `updated_at`). You will reference these later when building the dbt bronze model.

> **🤖 AI Prompt — Exploring the API response:**
>
> Use the following prompt if you want help understanding what the API returned:
>
> ```
> I just called the FreshService API endpoint GET /api/v2/tickets
> and received the following JSON response:
>
> [paste a sample ticket object here]
>
> Can you list every field, its data type, and a brief description
> of what it represents in FreshService? Also flag any fields that
> would be useful as a unique key or for incremental sync.
> ```

---

## Step 3 — Configure the Airbyte Source (FreshService)

1. Open the **Airbyte UI** at `http://localhost:8000`
2. In the left sidebar, click **Sources** → **+ New source**
3. Search for **"Freshservice"** in the connector catalog and select it
4. Fill in the configuration form:

| Field | Value |
|---|---|
| **Source name** | `freshservice-production` |
| **API Key** | *(paste your API key from Step 1)* |
| **Domain Name** | `yourcompany` *(just the subdomain, not the full URL)* |
| **Start Date** | Choose a reasonable historical start, e.g., `2023-01-01T00:00:00Z` |

5. Click **Set up source**
6. Airbyte will run a **connection check**. Wait for the green checkmark confirming the connection succeeded.

**If the check fails:**
- Verify the API key is correct (re-test with the curl command from Step 2)
- Verify you entered only the subdomain, not the full URL
- Check that the Airbyte container can reach the internet (`docker exec -it airbyte-worker curl https://google.com`)

---

## Step 4 — Configure the Airbyte Destination (PostgreSQL)

If a PostgreSQL destination already exists in Airbyte (check **Destinations** in the sidebar), you can reuse it. If not, create one:

1. Click **Destinations** → **+ New destination**
2. Select **PostgreSQL**
3. Fill in the configuration:

| Field | Value |
|---|---|
| **Destination name** | `data-warehouse-postgres` |
| **Host** | `host.docker.internal` |
| **Port** | `5432` |
| **Database** | `data_warehouse` |
| **Default Schema** | `bronze` |
| **Username** | `warehouse` *(or the value of `POSTGRES_USER` in your `.env`)* |
| **Password** | *(value of `POSTGRES_PASSWORD` in your `.env`)* |
| **SSL Mode** | `disable` *(internal Docker network)* |

4. Click **Set up destination** and wait for the connection check to succeed.

**Troubleshooting:**
- If the connection fails with "connection refused," verify PostgreSQL is running: `docker compose ps postgres`
- If it fails with "authentication failed," double-check credentials against the `.env` file
- The host `host.docker.internal` allows Airbyte's Docker network to reach the main Compose stack's PostgreSQL. If this doesn't resolve on your OS, you may need to use the actual Docker bridge IP.

> **🤖 AI Prompt — Troubleshooting connection issues:**
>
> ```
> I'm trying to connect Airbyte (running in its own Docker Compose)
> to PostgreSQL (running in a separate Docker Compose on the same server).
>
> Airbyte destination config:
> - Host: host.docker.internal
> - Port: 5432
> - Database: data_warehouse
> - User: warehouse
>
> The connection test fails with this error:
>
> [paste the exact error message]
>
> Both stacks are on the same Linux server. How do I fix this?
> ```

---

## Step 5 — Create the Airbyte Connection

This step links the FreshService source to the PostgreSQL destination and defines what data gets synced.

1. Click **Connections** → **+ New connection**
2. Select your **source** (`freshservice-production`) and **destination** (`data-warehouse-postgres`)
3. Configure the connection:

| Setting | Value | Notes |
|---|---|---|
| **Connection name** | `freshservice-tickets-to-bronze` | Descriptive name |
| **Replication frequency** | `Manual` | We'll trigger via Dagster later; set to manual for now |
| **Destination namespace** | `Custom format` → `bronze` | Forces all tables into the `bronze` schema |
| **Destination stream prefix** | `freshservice_` | Tables will be named `freshservice_<stream>` |

4. In the **streams** list, you will see all available FreshService objects (tickets, agents, requesters, etc.). For this guide, **enable only `tickets`**:
   - Toggle `tickets` to **enabled**
   - Set sync mode to **Incremental | Append** (preferred) or **Full Refresh | Overwrite** if incremental isn't available for this stream
   - If incremental is available, set the **cursor field** to `updated_at`

5. Disable all other streams (you can enable them later as separate connections or add to this one)
6. Click **Set up connection**

**What this creates in PostgreSQL:**

After the first sync, Airbyte will create a table in the `bronze` schema. The exact table name follows this pattern:

```
bronze._airbyte_raw_freshservice_tickets
```

This table contains three columns:
- `_airbyte_ab_id` — Airbyte's internal UUID for each record
- `_airbyte_data` — JSONB column with the complete raw ticket object
- `_airbyte_emitted_at` — Timestamp of when Airbyte extracted the record

> **Important:** The `_airbyte_data` JSONB column contains the *entire* API response per ticket. This is the raw, unmodified source of truth for the bronze layer. No fields are dropped or altered.

---

## Step 6 — Run an Initial Sync and Validate

### 6a. Trigger the sync

1. In the Airbyte UI, go to **Connections** → `freshservice-tickets-to-bronze`
2. Click **Sync now**
3. Monitor the sync progress. The first sync will perform a full historical load from your configured start date.
4. Wait for the status to show **Succeeded**

### 6b. Validate the data in PostgreSQL

Connect to the database:

```bash
docker compose exec postgres psql -U warehouse -d data_warehouse
```

Run these validation queries:

```sql
-- 1. Confirm the table exists in the bronze schema
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'bronze'
  AND table_name LIKE '%freshservice%ticket%';

-- 2. Count total records loaded
SELECT COUNT(*)
FROM bronze._airbyte_raw_freshservice_tickets;

-- 3. Preview the raw JSONB data (first 3 records)
SELECT _airbyte_ab_id,
       _airbyte_emitted_at,
       _airbyte_data
FROM bronze._airbyte_raw_freshservice_tickets
LIMIT 3;

-- 4. Inspect available fields inside the JSONB
SELECT DISTINCT jsonb_object_keys(_airbyte_data) AS field_name
FROM bronze._airbyte_raw_freshservice_tickets
LIMIT 50;

-- 5. Spot-check a specific ticket by ID
SELECT _airbyte_data->>'id' AS ticket_id,
       _airbyte_data->>'subject' AS subject,
       _airbyte_data->>'status' AS status,
       _airbyte_data->>'created_at' AS created_at
FROM bronze._airbyte_raw_freshservice_tickets
WHERE (_airbyte_data->>'id')::int = 1;
```

**What to look for:**
- Row count should roughly match the number of tickets in FreshService
- The JSONB data should contain recognizable ticket fields
- Timestamps should look reasonable (not all null, not in the future)

If the table is empty or missing, go back to the Airbyte UI and check the sync logs for errors.

> **🤖 AI Prompt — Generating validation queries:**
>
> ```
> I just completed an Airbyte sync of FreshService tickets into
> PostgreSQL. The data landed in:
>
>   Table: bronze._airbyte_raw_freshservice_tickets
>   Columns: _airbyte_ab_id (uuid), _airbyte_data (jsonb), _airbyte_emitted_at (timestamp)
>
> The _airbyte_data column contains the raw FreshService ticket JSON.
> Here are the fields inside _airbyte_data:
>
> [paste output from the jsonb_object_keys query]
>
> Write me a comprehensive set of SQL validation queries to check:
> 1. Total row count
> 2. Date range of tickets
> 3. Distribution of ticket statuses
> 4. Any null or missing critical fields (id, subject, created_at)
> 5. Duplicate check on ticket id
> ```

---

## Step 7 — Register the Connection in Dagster

Now that the Airbyte connection works, register it in Dagster so it runs on a schedule alongside the rest of the pipeline.

### 7a. Get the Airbyte connection ID

1. In the Airbyte UI, go to **Connections** → `freshservice-tickets-to-bronze`
2. Look at the URL in your browser. It will look like:
   ```
   http://localhost:8000/workspaces/<workspace-id>/connections/<connection-id>
   ```
3. Copy the `<connection-id>` (a UUID like `a1b2c3d4-e5f6-7890-abcd-ef1234567890`)

### 7b. Update the Dagster definitions

Open `dagster/pipelines/definitions.py` in your editor. You need to add the FreshService Airbyte assets.

> **🤖 AI Prompt — Generating the Dagster code:**
>
> ```
> I need to add a new Airbyte connection to our Dagster definitions.
>
> Current setup:
> - Dagster definitions file: dagster/pipelines/definitions.py
> - Dagster connects to Airbyte at: host.docker.internal:8000
> - We use dagster-airbyte's `load_assets_from_airbyte_instance` or
>   `build_airbyte_assets` pattern
> - We use dagster-dbt's `@dbt_assets` for dbt models
> - The dbt project is mounted at /opt/dagster/dbt
>
> I need to:
> 1. Add a new Airbyte connection with ID: "<paste-your-connection-id>"
>    for FreshService tickets loading to the bronze schema
> 2. The asset should be in a group called "bronze_freshservice"
> 3. Include it in a daily schedule at 6:00 AM UTC
> 4. The dbt assets already exist and should depend on this Airbyte
>    asset (the dbt models run after the sync completes)
>
> Here is my current definitions.py file:
>
> [paste the current contents of definitions.py]
>
> Please update the file to include the new FreshService connection.
> Keep all existing definitions intact.
> ```

### 7c. Apply the changes

Restart the Dagster container to pick up the new definitions:

```bash
docker compose restart dagster
```

### 7d. Verify in the Dagster UI

1. Open **Dagster** at `http://localhost:3002`
2. Go to the **Assets** tab
3. You should see the new FreshService Airbyte asset in the `bronze_freshservice` group
4. Click on the asset and select **Materialize** to trigger a test run
5. Confirm the run succeeds and data appears in PostgreSQL

---

## Step 8 — Create the dbt Bronze Model

The dbt bronze model is a **view** on top of the raw Airbyte table. It doesn't transform the data — it just provides a clean, named interface that silver models can reference.

### 8a. Create the model file

Create a new file at `dbt/models/bronze/freshservice_tickets.sql`:

> **🤖 AI Prompt — Generating the dbt bronze model:**
>
> ```
> I need a dbt bronze model for FreshService ticket data.
>
> Context:
> - dbt project is at: dbt/
> - Bronze models are materialized as views in the "bronze" schema
> - Source table: bronze._airbyte_raw_freshservice_tickets
> - Columns in source: _airbyte_ab_id (uuid), _airbyte_data (jsonb),
>   _airbyte_emitted_at (timestamp)
>
> The _airbyte_data JSONB contains these fields from the FreshService API:
>
> [paste the field list from your jsonb_object_keys query in Step 6]
>
> Requirements:
> 1. Create a dbt model that selects from the raw table
> 2. Extract each JSONB field into its own column using the ->> operator
> 3. Keep the original _airbyte_ab_id and _airbyte_emitted_at columns
> 4. Do NOT cast types — the bronze layer keeps everything as raw text
>    (type casting happens in silver)
> 5. Add a dbt config block at the top: materialized='view', schema='bronze'
> 6. Add a comment header explaining this is a bronze model
>
> Also generate the corresponding schema.yml entry with:
> - A description of the model
> - Column descriptions for all fields
> - A test for unique and not_null on the ticket id field
> ```

### 8b. Example bronze model

For reference, a typical bronze model looks like this (your AI-generated version may differ based on actual fields):

```sql
-- Bronze model: FreshService Tickets
-- Raw extraction from Airbyte JSONB. No type casting or transformation.

{{ config(
    materialized='view',
    schema='bronze'
) }}

SELECT
    _airbyte_ab_id,
    _airbyte_emitted_at,
    _airbyte_data->>'id'              AS ticket_id,
    _airbyte_data->>'subject'         AS subject,
    _airbyte_data->>'description'     AS description,
    _airbyte_data->>'status'          AS status,
    _airbyte_data->>'priority'        AS priority,
    _airbyte_data->>'source'          AS source,
    _airbyte_data->>'requester_id'    AS requester_id,
    _airbyte_data->>'responder_id'    AS responder_id,
    _airbyte_data->>'group_id'        AS group_id,
    _airbyte_data->>'department_id'   AS department_id,
    _airbyte_data->>'category'        AS category,
    _airbyte_data->>'sub_category'    AS sub_category,
    _airbyte_data->>'item_category'   AS item_category,
    _airbyte_data->>'type'            AS type,
    _airbyte_data->>'created_at'      AS created_at,
    _airbyte_data->>'updated_at'      AS updated_at,
    _airbyte_data->>'due_by'          AS due_by,
    _airbyte_data->>'fr_due_by'       AS fr_due_by,
    _airbyte_data->>'is_escalated'    AS is_escalated,
    _airbyte_data->>'spam'            AS spam,
    _airbyte_data                     AS _raw_json
FROM bronze._airbyte_raw_freshservice_tickets
```

### 8c. Add the schema entry

Open `dbt/models/schema.yml` and add an entry for the new model under the bronze section. Include descriptions and tests.

### 8d. Run and test the model

```bash
# Build the bronze model
docker compose exec dagster dbt run \
  --project-dir /opt/dagster/dbt \
  --select freshservice_tickets

# Run tests on it
docker compose exec dagster dbt test \
  --project-dir /opt/dagster/dbt \
  --select freshservice_tickets
```

Verify the view was created:

```bash
docker compose exec postgres psql -U warehouse -d data_warehouse \
  -c "SELECT ticket_id, subject, status, created_at
      FROM bronze.freshservice_tickets
      LIMIT 5;"
```

---

## Step 9 — End-to-End Validation

Run through this final checklist to confirm everything is wired up correctly.

| Check | Command / Action | Expected Result |
|---|---|---|
| Airbyte sync works | Airbyte UI → Connection → Sync now | Status: Succeeded |
| Raw data exists | `SELECT COUNT(*) FROM bronze._airbyte_raw_freshservice_tickets;` | Row count > 0 |
| dbt model runs | `dbt run --select freshservice_tickets` | No errors |
| dbt tests pass | `dbt test --select freshservice_tickets` | All tests pass |
| Bronze view works | `SELECT * FROM bronze.freshservice_tickets LIMIT 5;` | Readable columns |
| Dagster asset visible | Dagster UI → Assets | `freshservice_tickets` asset present |
| Dagster can trigger sync | Materialize the Airbyte asset in Dagster | Run succeeds |
| Schedule is active | Dagster UI → Schedules | Daily 6 AM schedule running |

Once all checks pass, the bronze layer for FreshService tickets is complete. The silver layer team can now build incremental models on top of `bronze.freshservice_tickets`.

---

## Appendix — AI Prompt Templates

Below is a summary of all AI prompts referenced in this guide, plus additional utility prompts.

### A1. Exploring a new API response

```
I just called the FreshService API endpoint GET /api/v2/tickets and received
the following JSON response:

[paste a sample ticket object]

Can you list every field, its data type, and a brief description of what it
represents in FreshService? Also flag any fields that would be useful as a
unique key or for incremental sync.
```

### A2. Troubleshooting Airbyte-to-Postgres connectivity

```
I'm trying to connect Airbyte (running in its own Docker Compose) to PostgreSQL
(running in a separate Docker Compose on the same server).

Airbyte destination config:
- Host: host.docker.internal
- Port: 5432
- Database: data_warehouse
- User: warehouse

The connection test fails with this error:

[paste the exact error message]

Both stacks are on the same Linux server. How do I fix this?
```

### A3. Generating SQL validation queries

```
I just completed an Airbyte sync of FreshService tickets into PostgreSQL.
The data landed in:

  Table: bronze._airbyte_raw_freshservice_tickets
  Columns: _airbyte_ab_id (uuid), _airbyte_data (jsonb), _airbyte_emitted_at (timestamp)

The _airbyte_data column contains the raw FreshService ticket JSON.
Here are the fields inside _airbyte_data:

[paste output from the jsonb_object_keys query]

Write me a comprehensive set of SQL validation queries to check:
1. Total row count
2. Date range of tickets
3. Distribution of ticket statuses
4. Any null or missing critical fields (id, subject, created_at)
5. Duplicate check on ticket id
```

### A4. Generating Dagster definitions

```
I need to add a new Airbyte connection to our Dagster definitions.

Current setup:
- Dagster definitions file: dagster/pipelines/definitions.py
- Dagster connects to Airbyte at: host.docker.internal:8000
- We use dagster-airbyte's load_assets_from_airbyte_instance or
  build_airbyte_assets pattern
- We use dagster-dbt's @dbt_assets for dbt models
- The dbt project is mounted at /opt/dagster/dbt

I need to:
1. Add a new Airbyte connection with ID: "<paste-your-connection-id>"
   for FreshService tickets loading to the bronze schema
2. The asset should be in a group called "bronze_freshservice"
3. Include it in a daily schedule at 6:00 AM UTC
4. The dbt assets already exist and should depend on this Airbyte
   asset (the dbt models run after the sync completes)

Here is my current definitions.py file:

[paste the current contents of definitions.py]

Please update the file to include the new FreshService connection.
Keep all existing definitions intact.
```

### A5. Generating the dbt bronze model

```
I need a dbt bronze model for FreshService ticket data.

Context:
- dbt project is at: dbt/
- Bronze models are materialized as views in the "bronze" schema
- Source table: bronze._airbyte_raw_freshservice_tickets
- Columns: _airbyte_ab_id (uuid), _airbyte_data (jsonb), _airbyte_emitted_at (timestamp)

The _airbyte_data JSONB contains these fields:

[paste the field list from your jsonb_object_keys query]

Requirements:
1. Create a dbt model that selects from the raw table
2. Extract each JSONB field into its own column using ->>
3. Keep the original _airbyte_ab_id and _airbyte_emitted_at columns
4. Do NOT cast types — bronze keeps everything as raw text
5. Add config: materialized='view', schema='bronze'
6. Also generate the corresponding schema.yml entry with column
   descriptions and tests for unique/not_null on ticket id
```

### A6. Debugging a failed Airbyte sync

```
My Airbyte sync for FreshService tickets failed. Here are the details:

- Source: Freshservice connector
- Destination: PostgreSQL (bronze schema)
- Sync mode: Incremental | Append
- Error from the Airbyte logs:

[paste the error logs]

What is causing this failure and how do I fix it?
```

### A7. Adding a new FreshService stream to an existing connection

```
I already have a working Airbyte connection syncing FreshService tickets to
the bronze schema. I now want to add the following additional streams to the
same connection:

- agents
- requesters
- departments
- groups

For each stream, what should I set as:
1. Sync mode (incremental vs full refresh)
2. Cursor field (if incremental)
3. Primary key

Also, what new dbt bronze models will I need to create? Give me the file
names and a template for each.
```
