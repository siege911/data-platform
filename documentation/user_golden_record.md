# User Golden Record — Architecture Document

**Single Source of Truth for Internal Staff Identity**
**Medallion Architecture: Bronze → Silver → Gold**

Source: Microsoft Entra ID (Microsoft Graph API) via Airbyte
Transformation: dbt Core (dbt-postgres) | Orchestration: Dagster

---

## 1. Purpose

This document describes the architecture of the User Golden Record — the single source of truth for internal staff identity across the entire data platform. Every person who works for the organization is represented exactly once in this record, and every other data source that references a user points back to it.

The golden record eliminates the problem of staff data being duplicated and inconsistently maintained across dozens of SaaS systems. Instead of each system carrying its own copy of a user's name, email, department, and title, those fields live in one place and are joined in at the gold layer for BI consumption.

---

## 2. Design Principles

**Entra ID is the authoritative spine.** Microsoft Entra ID (formerly Azure AD) is the organization's identity provider. It is the most reliably maintained source of staff data because it controls login access. Every staff record originates from Entra ID.

**staff_id is a platform-owned UUID.** The golden record generates its own surrogate key that is independent of any source system. This insulates every downstream foreign key from changes in Entra ID, the ERP, or any other upstream system.

**Email is the universal natural key.** Lowercased and trimmed, the email address is used to match staff across all connected SaaS systems via the cross-reference table.

**SaaS silver tables never duplicate staff fields.** Downstream silver models store only a staff_id foreign key. Name, email, department, phone, and other common fields live exclusively in stg_staff. Denormalization happens in the gold layer.

**The ERP enriches, not replaces.** The legacy ERP supplements fields that Entra ID lacks (such as a legacy employee ID). When the ERP is replaced, only one dbt model changes — no downstream impact.

---

## 3. Data Flow Overview

| Layer | Object | Type | Purpose |
|---|---|---|---|
| Bronze | `bronze.bronze_entraid_users` | dbt view | Snake_case interface over the raw Airbyte table. No transformation. |
| Silver | `silver.stg_staff` | dbt incremental | Golden record. Filtered, deduplicated, typed, one row per internal staff. |
| Silver | `silver.staff_source_xref` | dbt incremental | Cross-reference mapping staff_id to native user IDs per SaaS system. |
| Gold | `gold.dim_staff` | dbt table | BI-ready dimension with resolved manager names and derived fields. |

The pipeline is orchestrated by Dagster. On each scheduled run (daily at 6:00 AM), Dagster triggers the Airbyte sync for Entra ID, then runs the dbt models in dependency order: bronze view → stg_staff → staff_source_xref.

---

## 4. Bronze Layer: Raw Ingestion

### 4.1 Source System

Airbyte connects to the Microsoft Graph API using the Entra ID source connector. It syncs user data into the bronze schema of the PostgreSQL data warehouse. The Airbyte connection uses the newer flat-column format, meaning each Graph API field lands as its own PostgreSQL column (rather than a single JSONB blob).

### 4.2 Raw Airbyte Table

**Table:** `bronze.entra_idusers`

This table is managed entirely by Airbyte. It is append-only — each sync adds new rows, potentially creating duplicates for updated users. The dbt bronze view sits on top of this table to provide stable, snake_case column names.

### 4.3 Bronze View Columns

**dbt Model:** `bronze_entraid_users` | **Materialized as:** view | **Schema:** bronze

| Bronze Column | Source Column | Type | Description |
|---|---|---|---|
| `_airbyte_raw_id` | _airbyte_raw_id | VARCHAR | Airbyte internal UUID per record |
| `_airbyte_extracted_at` | _airbyte_extracted_at | TIMESTAMPTZ | When Airbyte extracted this record |
| `user_id` | id | VARCHAR | Entra ID object ID (Microsoft Graph user ID) |
| `given_name` | givenName | VARCHAR | User's first name |
| `surname` | surname | VARCHAR | User's last name |
| `display_name` | displayName | VARCHAR | Full display name |
| `mail` | mail | VARCHAR | Primary SMTP email address |
| `user_principal_name` | userPrincipalName | VARCHAR | UPN — login identifier in Entra ID |
| `mail_nickname` | mailNickname | VARCHAR | Mail alias |
| `job_title` | jobTitle | VARCHAR | Job title |
| `department` | department | VARCHAR | Department |
| `company_name` | companyName | VARCHAR | Company name field |
| `employee_id` | employeeId | VARCHAR | Employee ID if populated in Entra ID |
| `office_location` | officeLocation | VARCHAR | Office location |
| `mobile_phone` | mobilePhone | VARCHAR | Mobile phone number |
| `business_phones` | businessPhones | JSONB | Array of business phone numbers |
| `street_address` | streetAddress | VARCHAR | Street address |
| `city` | city | VARCHAR | City |
| `state` | state | VARCHAR | State or province |
| `postal_code` | postalCode | VARCHAR | Postal/ZIP code |
| `country` | country | VARCHAR | Country |
| `user_type` | userType | VARCHAR | Member or Guest |
| `account_enabled` | accountEnabled | VARCHAR | Whether the account is enabled (text: true/false) |
| `created_date_time` | createdDateTime | VARCHAR | Account creation timestamp |
| `last_password_change` | lastPasswordChangeDateTime | VARCHAR | Last password change timestamp |
| `preferred_language` | preferredLanguage | VARCHAR | Preferred language |
| `identities` | identities | JSONB | Array of identity objects (sign-in methods) |

**Key point:** The bronze view applies zero transformation. Every column remains as raw text or JSONB. Type casting, filtering, and cleaning happen exclusively in the silver layer.

---

## 5. Silver Layer: The Golden Record

### 5.1 Transformations Applied

The stg_staff model takes the raw bronze view as input and applies five categories of transformation to produce the canonical staff record:

| Transformation | What It Does | Why |
|---|---|---|
| Guest filtering | Removes rows where userPrincipalName contains `#EXT#` or userType = `Guest` | External/guest accounts are not internal staff and should not pollute the golden record |
| Deduplication | `ROW_NUMBER()` partitioned by user_id, ordered by _airbyte_extracted_at DESC. Keeps only row_num = 1 | Airbyte append mode creates duplicates across syncs. Only the most recent version of each user is retained |
| Email derivation | `LOWER(TRIM(COALESCE(mail, userPrincipalName)))` | The mail field is the proper SMTP address; UPN is the fallback. Lowercasing and trimming ensures consistent matching across all SaaS systems |
| Phone extraction | `COALESCE(mobilePhone, businessPhones[0])` | Prefers mobile phone; falls back to the first entry in the business phones JSONB array |
| Type casting | accountEnabled text → BOOLEAN, empty strings → NULL via NULLIF, UUID generation for staff_id | Converts raw text into proper SQL types for downstream querying and indexing |

### 5.2 Incremental Strategy

The model uses dbt's incremental materialization with a merge strategy. On the first run, all records are processed (full load). On subsequent runs, only records with `_airbyte_extracted_at` newer than the most recent `_source_updated_at` in the existing silver table are processed. The merge is keyed on `ms_graph_id`, so updated users replace their existing row while preserving their `staff_id`.

**⚠️ Critical: Never run `dbt run --full-refresh` on stg_staff.** This regenerates all staff_id UUIDs, which breaks every downstream foreign key that references them.

### 5.3 CTE Pipeline

The dbt model is structured as a chain of Common Table Expressions (CTEs), each performing one step:

| CTE | Purpose |
|---|---|
| `source` | Selects all columns from the bronze_entraid_users view |
| `filtered` | On incremental runs, restricts to rows newer than the latest _source_updated_at already in silver. On full load, passes everything through |
| `deduplicated` | Adds ROW_NUMBER() partitioned by user_id, ordered by _airbyte_extracted_at DESC |
| `internal_users` | Keeps only row_num = 1, removes nulls on user_id, filters out #EXT# UPNs and Guest user types |
| `typed` | Applies all type casting, email derivation, phone extraction, NULLIF cleaning, UUID generation, and metadata timestamps |

### 5.4 stg_staff Column Reference

**dbt Model:** `stg_staff` | **Materialized as:** incremental (merge) | **Schema:** silver | **Unique key:** ms_graph_id

| Silver Column | Source | Type | Nullable | Description |
|---|---|---|---|---|
| `staff_id` | Generated | UUID | No | Platform-owned surrogate key. FK target for all downstream tables. |
| `ms_graph_id` | user_id | VARCHAR | No | Entra ID object ID. Natural key from Microsoft Graph. |
| `erp_employee_id` | employee_id | VARCHAR | Yes | Employee ID from Entra ID or future ERP integration. |
| `email` | mail → UPN | VARCHAR | No | Lowercased, trimmed. Prefers mail field, falls back to UPN. |
| `first_name` | given_name | VARCHAR | Yes | Given name. NULL for service accounts. |
| `last_name` | surname | VARCHAR | Yes | Surname. NULL for service accounts. |
| `display_name` | display_name | VARCHAR | No | Full display name from Entra ID. |
| `job_title` | job_title | VARCHAR | Yes | Job title from Entra ID. |
| `department` | department | VARCHAR | Yes | Department from Entra ID. |
| `manager_staff_id` | — | UUID | Yes | Self-referencing FK to manager. Currently NULL (requires Graph API manager expansion). |
| `phone` | mobile_phone → business_phones[0] | VARCHAR | Yes | Prefers mobile phone, falls back to first business phone. |
| `is_active` | account_enabled | BOOLEAN | No | TRUE if accountEnabled = true; FALSE if false; defaults TRUE if null. |
| `_source_updated_at` | _airbyte_extracted_at | TIMESTAMPTZ | No | Most recent Airbyte extraction timestamp. |
| `_loaded_at` | NOW() | TIMESTAMPTZ | No | When the record was first inserted by dbt. |
| `_updated_at` | NOW() | TIMESTAMPTZ | No | When the record was last updated by dbt. |

---

## 6. Cross-Reference Table: staff_source_xref

The staff_source_xref table maps each staff_id to the native user identifier in every connected SaaS system. This is the lookup mechanism that all other silver models use to resolve a SaaS user to the golden record, without duplicating staff fields.

Currently, the table is seeded with `microsoft_365` entries (mapping staff_id to the Entra ID object ID). As new SaaS integrations are added, a new CTE and UNION ALL block is appended to this model for each source system.

### 6.1 Column Reference

| Column | Type | Description |
|---|---|---|
| `surrogate_key` | VARCHAR (MD5) | Deterministic key: MD5(source_system \|\| source_user_id). Used for incremental merge. |
| `id` | UUID | Row-level primary key. |
| `staff_id` | UUID (FK) | References stg_staff.staff_id. |
| `source_system` | VARCHAR(100) | Canonical source name: microsoft_365, hubspot, jira, salesforce, etc. |
| `source_user_id` | VARCHAR(500) | The user's native ID in the source system. |
| `_loaded_at` | TIMESTAMPTZ | When the row was first inserted. |
| `_updated_at` | TIMESTAMPTZ | When the row was last updated. |

### 6.2 How Downstream Models Use the Xref

When a new SaaS silver model needs to reference a user (for example, a FreshService ticket's agent), it joins to staff_source_xref on the source system name and the SaaS-native user ID to obtain the staff_id. It does NOT carry the user's name or email from the SaaS source — those fields are resolved in the gold layer by joining to gold.dim_staff.

---

## 7. Gold Layer: dim_staff (Planned)

The gold.dim_staff table is a fully denormalized, BI-ready view of the golden record. It will be materialized as a dbt table model that joins stg_staff to itself to resolve manager fields and adds derived convenience columns.

### 7.1 Additional Columns Beyond stg_staff

| Column | Type | Derivation |
|---|---|---|
| `full_name` | VARCHAR(300) | first_name \|\| ' ' \|\| last_name |
| `manager_display_name` | VARCHAR(300) | Self-join on manager_staff_id → display_name |
| `manager_email` | VARCHAR(320) | Self-join on manager_staff_id → email |

All other columns from stg_staff are carried forward unchanged. BI dashboards query dim_staff directly and never need to perform joins to resolve staff identity.

---

## 8. Source System Naming Conventions

When registering a new SaaS system in `staff_source_xref.source_system`, use these canonical lowercase names:

| Source System | source_system Value | Typical source_user_id |
|---|---|---|
| Microsoft 365 | `microsoft_365` | Entra ID object ID (UUID) |
| Legacy ERP | `erp_legacy` | Employee ID string |
| HubSpot | `hubspot` | HubSpot owner ID |
| Salesforce | `salesforce` | Salesforce User ID (18-char) |
| Jira | `jira` | Atlassian account ID |
| Slack | `slack` | Slack member ID (e.g., U0123ABCDEF) |
| FreshService | `freshservice` | FreshService agent/requester ID |
| Zendesk | `zendesk` | Zendesk user ID |
| QuickBooks | `quickbooks` | QuickBooks employee ID |

For systems not listed above, use the format `{product_name}` in lowercase with underscores (e.g., `google_workspace`, `asana`, `monday_com`).

---

## 9. Current Limitations

**manager_staff_id is NULL.** The Entra ID connector does not currently expand the manager relationship from the Graph API. When this is added to the Airbyte stream, the stg_staff model will resolve manager_staff_id via a self-join on ms_graph_id.

**No ERP enrichment yet.** The architecture supports COALESCE logic to prefer ERP values for job_title and department, but the ERP bronze/silver integration has not yet been built. The erp_employee_id field is currently populated only if Entra ID's employeeId field contains a value.

**Service accounts are included.** Some Entra ID accounts (e.g., shared mailboxes, service accounts) pass the #EXT# and Guest filters but are not real staff. These can be identified by missing first_name and last_name fields. A future enhancement may add explicit service account filtering.

---

## 10. Operational Notes

**Schedule:** Dagster runs the full pipeline (Airbyte sync → bronze → silver) daily at 6:00 AM via cron schedule.

**Incremental behavior:** After the initial full load, each run only processes users whose _airbyte_extracted_at is newer than the most recent _source_updated_at in silver. This keeps run times short.

**BI access:** The bi_readonly role has SELECT permission on all silver and gold tables. Metabase connects using this role.

**Custom schema macro:** A generate_schema_name macro in dbt/macros/ ensures models deploy to the exact schema specified (bronze, silver, gold) rather than dbt's default concatenation behavior.