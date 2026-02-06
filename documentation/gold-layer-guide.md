# Gold Layer Aggregation Guide

## FreshService Tickets — Silver → Gold

**Audience:** New team members
**Scope:** Gold layer only — aggregated, denormalized, BI-ready tables built from silver data
**Prerequisite:** Completed the Silver Layer Transformation Guide; `silver.freshservice_tickets` is populated and passes all tests

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Step 1 — Identify Reporting Requirements](#step-1--identify-reporting-requirements)
4. [Step 2 — Design the Gold Models](#step-2--design-the-gold-models)
5. [Step 3 — Build the Ticket Summary Gold Model](#step-3--build-the-ticket-summary-gold-model)
6. [Step 4 — Build the Daily Metrics Gold Model](#step-4--build-the-daily-metrics-gold-model)
7. [Step 5 — Build the SLA Performance Gold Model](#step-5--build-the-sla-performance-gold-model)
8. [Step 6 — Add Schema Documentation and Tests](#step-6--add-schema-documentation-and-tests)
9. [Step 7 — Run and Validate All Gold Models](#step-7--run-and-validate-all-gold-models)
10. [Step 8 — Register in Dagster and Verify the Full Pipeline](#step-8--register-in-dagster-and-verify-the-full-pipeline)
11. [Step 9 — Connect Gold Models to Metabase](#step-9--connect-gold-models-to-metabase)
12. [Step 10 — End-to-End Validation](#step-10--end-to-end-validation)
13. [Appendix — AI Prompt Templates](#appendix--ai-prompt-templates)

---

## 1. Overview

The **gold schema** is the presentation layer. Gold models are purpose-built for specific reporting and analytics use cases. They are:

| Characteristic | Detail |
|---|---|
| **Aggregated** | Pre-computed metrics (counts, averages, sums) so dashboards don't calculate at query time |
| **Denormalized** | Joins across multiple silver tables are flattened into wide tables for simple BI queries |
| **Materialized as tables** | Full table rebuilds each run — no incremental complexity at this layer |
| **BI-optimized** | Column names are business-friendly, values are display-ready, no codes or IDs exposed without labels |

Gold models should answer a specific business question or power a specific dashboard. They are not generic "just in case" tables.

The flow for this guide:

```
silver.freshservice_tickets (table)
        ↓
   dbt table models (full rebuild)
        ↓
gold.freshservice_ticket_summary      — enriched ticket-level detail
gold.freshservice_daily_metrics       — daily operational KPIs
gold.freshservice_sla_performance     — SLA compliance analysis
        ↓
   Metabase dashboards
```

**What you will have at the end of this guide:**
- Three gold models covering the most common FreshService reporting needs
- Full test coverage and documentation in `schema.yml`
- Models visible in Dagster's asset graph with silver → gold dependencies
- Metabase connected to the gold tables with working queries

---

## 2. Prerequisites

| Requirement | How to verify |
|---|---|
| Silver guide is complete | `SELECT COUNT(*) FROM silver.freshservice_tickets;` returns rows |
| Silver tests pass | `dbt test --select silver.freshservice_tickets` — all green |
| Gold schema exists | `SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'gold';` |
| You've spoken with stakeholders | You have a list of reporting questions the dashboards need to answer |

---

## Step 1 — Identify Reporting Requirements

Gold models are driven by business needs, not by the data structure. Before writing any SQL, gather requirements from stakeholders.

### 1a. Standard FreshService reporting questions

Most IT service desk teams need answers to these questions. Use this as a starting point and adjust based on your organization's priorities.

**Operational visibility:**
- How many tickets are currently open, by priority and category?
- What is the average time to first response? To resolution?
- Which teams/groups have the highest ticket volume?
- What are the daily/weekly/monthly trends in ticket creation and resolution?

**SLA compliance:**
- What percentage of tickets meet the first response SLA?
- What percentage of tickets are resolved within the resolution SLA?
- Which groups or categories have the worst SLA compliance?
- How has SLA performance trended over time?

**Workload distribution:**
- How many tickets are assigned to each agent/group?
- What is the backlog (open + pending) per group?
- Which categories generate the most tickets?

### 1b. Map questions to gold models

Based on common requirements, this guide builds three gold models:

| Gold Model | Purpose | Primary Audience |
|---|---|---|
| `freshservice_ticket_summary` | One row per ticket with enriched fields, calculated durations, and SLA flags | Analysts who need ticket-level detail |
| `freshservice_daily_metrics` | One row per day with aggregated counts and averages | Dashboard tiles showing trends |
| `freshservice_sla_performance` | SLA compliance rates grouped by time period, group, and category | Management SLA review |

> **🤖 AI Prompt — Discovering additional reporting needs:**
>
> ```
> I'm building gold-layer dbt models for FreshService ticket data to
> power Metabase dashboards for our IT service desk team.
>
> Here are the columns available in our silver table:
>
> [paste output of: \d silver.freshservice_tickets]
>
> Our team has asked for dashboards covering:
> - Operational ticket volume and trends
> - SLA compliance tracking
> - Agent/group workload distribution
>
> I'm planning these three gold models:
> 1. freshservice_ticket_summary — enriched ticket-level detail
> 2. freshservice_daily_metrics — daily aggregated KPIs
> 3. freshservice_sla_performance — SLA compliance breakdowns
>
> Questions:
> 1. Are these three models sufficient, or do you recommend additional
>    gold models for common IT service desk reporting?
> 2. For each model, what columns and metrics should I include?
> 3. Are there any commonly requested FreshService metrics I might
>    be overlooking?
> ```

---

## Step 2 — Design the Gold Models

Before writing SQL, define the output schema for each gold model. This serves as the contract between the data team and the BI layer.

### 2a. `gold.freshservice_ticket_summary`

An enriched, wide table with one row per ticket. Adds calculated fields that don't exist in the raw data.

| Column | Type | Description |
|---|---|---|
| `ticket_id` | `INTEGER` | Primary key |
| `subject` | `TEXT` | Ticket title |
| `status_label` | `TEXT` | Open, Pending, Resolved, Closed |
| `priority_label` | `TEXT` | Low, Medium, High, Urgent |
| `source_label` | `TEXT` | Email, Portal, Phone, etc. |
| `ticket_type` | `TEXT` | Incident, Service Request, etc. |
| `category` | `TEXT` | |
| `sub_category` | `TEXT` | |
| `requester_id` | `INTEGER` | |
| `responder_id` | `INTEGER` | |
| `group_id` | `INTEGER` | |
| `department_id` | `INTEGER` | |
| `is_escalated` | `BOOLEAN` | |
| `created_at` | `TIMESTAMP` | |
| `created_date` | `DATE` | Truncated for easy grouping |
| `updated_at` | `TIMESTAMP` | |
| `due_by` | `TIMESTAMP` | Resolution SLA deadline |
| `first_response_due_by` | `TIMESTAMP` | First response SLA deadline |
| `hours_since_created` | `NUMERIC` | Ticket age in hours (for open tickets) |
| `is_resolution_sla_breached` | `BOOLEAN` | `TRUE` if open/pending and past `due_by` |
| `is_first_response_sla_breached` | `BOOLEAN` | `TRUE` if past `first_response_due_by` without response |
| `is_open` | `BOOLEAN` | Status is Open or Pending |
| `_gold_built_at` | `TIMESTAMP` | Model build time |

### 2b. `gold.freshservice_daily_metrics`

One row per calendar day with aggregated KPIs.

| Column | Type | Description |
|---|---|---|
| `metric_date` | `DATE` | Calendar day |
| `tickets_created` | `INTEGER` | Tickets created on this day |
| `tickets_resolved` | `INTEGER` | Tickets resolved on this day |
| `tickets_closed` | `INTEGER` | Tickets closed on this day |
| `avg_hours_to_resolution` | `NUMERIC` | Avg hours from creation to resolution for tickets resolved this day |
| `open_ticket_backlog` | `INTEGER` | Total open + pending tickets at end of day |
| `escalated_tickets_created` | `INTEGER` | Escalated tickets created this day |
| `high_urgent_tickets_created` | `INTEGER` | Priority High or Urgent tickets created this day |
| `pct_resolved_same_day` | `NUMERIC` | % of tickets created and resolved on the same day |
| `_gold_built_at` | `TIMESTAMP` | Model build time |

### 2c. `gold.freshservice_sla_performance`

SLA compliance rates sliced by different dimensions.

| Column | Type | Description |
|---|---|---|
| `period_start` | `DATE` | Start of the week/month |
| `period_type` | `TEXT` | 'weekly' or 'monthly' |
| `group_id` | `INTEGER` | Nullable; NULL = all groups |
| `category` | `TEXT` | Nullable; NULL = all categories |
| `total_tickets` | `INTEGER` | Tickets in this slice |
| `resolution_sla_met` | `INTEGER` | Tickets resolved within SLA |
| `resolution_sla_breached` | `INTEGER` | Tickets that breached resolution SLA |
| `resolution_sla_pct` | `NUMERIC` | % met resolution SLA |
| `first_response_sla_met` | `INTEGER` | Tickets responded within SLA |
| `first_response_sla_breached` | `INTEGER` | Tickets that breached first response SLA |
| `first_response_sla_pct` | `NUMERIC` | % met first response SLA |
| `_gold_built_at` | `TIMESTAMP` | Model build time |

> **🤖 AI Prompt — Reviewing gold model designs:**
>
> ```
> I'm designing three gold-layer dbt models for FreshService tickets.
> Here are my column specifications:
>
> Model 1 — freshservice_ticket_summary:
> [paste the 2a table]
>
> Model 2 — freshservice_daily_metrics:
> [paste the 2b table]
>
> Model 3 — freshservice_sla_performance:
> [paste the 2c table]
>
> Source: silver.freshservice_tickets with these columns:
> [paste \d silver.freshservice_tickets output]
>
> Please review:
> 1. Are the column definitions complete and useful for BI dashboards?
> 2. Any calculated fields I should add or remove?
> 3. Are the SLA breach calculations logically sound given that silver
>    only has due_by and first_response_due_by timestamps (we don't
>    have actual first_response_at from this API endpoint)?
> 4. For daily_metrics, is there a better way to calculate open_ticket_backlog
>    as a running total?
> ```

---

## Step 3 — Build the Ticket Summary Gold Model

Create `dbt/models/gold/freshservice_ticket_summary.sql`:

> **🤖 AI Prompt — Generating the ticket summary model:**
>
> ```
> I need a dbt gold model for an enriched FreshService ticket summary.
>
> Architecture context:
> - Source: silver.freshservice_tickets (referenced via {{ ref() }})
> - Target: gold.freshservice_ticket_summary
> - Database: PostgreSQL 15
> - dbt adapter: dbt-postgres
> - Gold models use: materialized='table', schema='gold'
>
> Output column spec:
>
> [paste the full 2a column specification table]
>
> Requirements:
> 1. Config: materialized='table', schema='gold'
> 2. Select all business-relevant columns from silver (drop _airbyte_emitted_at
>    and _silver_loaded_at — those are lineage columns for internal use)
> 3. Add created_date as DATE truncation of created_at
> 4. Calculate hours_since_created:
>    - EXTRACT(EPOCH FROM (NOW() - created_at)) / 3600
>    - Round to 1 decimal place
> 5. Calculate is_resolution_sla_breached:
>    - TRUE if due_by IS NOT NULL AND status is Open or Pending
>      AND NOW() > due_by
> 6. Calculate is_first_response_sla_breached:
>    - TRUE if first_response_due_by IS NOT NULL AND NOW() > first_response_due_by
>    - Note: we don't have actual first response timestamp from this
>      endpoint, so this is a best-effort flag
> 7. Add is_open: TRUE if status_label IN ('Open', 'Pending')
> 8. Add _gold_built_at = NOW()
> 9. CTE structure: source → enriched → final SELECT
> 10. Comment header explaining the model
>
> Generate the complete SQL file.
> ```

### 3a. Example ticket summary model

```sql
-- Gold model: FreshService Ticket Summary
-- Enriched ticket-level detail with calculated durations and SLA flags.
-- Full table rebuild on each run.

{{ config(
    materialized='table',
    schema='gold'
) }}

WITH source AS (

    SELECT * FROM {{ ref('freshservice_tickets') }}
    -- Note: ref resolves to silver.freshservice_tickets because the
    -- silver model is the terminal node named 'freshservice_tickets'
    -- in the dbt DAG. If this causes ambiguity with the bronze model
    -- of the same name, rename one of them (see troubleshooting below).

),

enriched AS (

    SELECT
        -- Identifiers
        ticket_id,
        subject,

        -- Classification
        status_label,
        priority_label,
        source_label,
        ticket_type,
        category,
        sub_category,

        -- Relationships
        requester_id,
        responder_id,
        group_id,
        department_id,

        -- Flags
        is_escalated,

        -- Timestamps
        created_at,
        created_at::DATE                                AS created_date,
        updated_at,
        due_by,
        first_response_due_by,

        -- Calculated: ticket age in hours
        ROUND(
            EXTRACT(EPOCH FROM (NOW() - created_at)) / 3600, 1
        )                                               AS hours_since_created,

        -- Calculated: is this ticket still open?
        status_label IN ('Open', 'Pending')             AS is_open,

        -- Calculated: resolution SLA breach
        CASE
            WHEN due_by IS NULL THEN FALSE
            WHEN status_label IN ('Open', 'Pending')
                 AND NOW() > due_by THEN TRUE
            ELSE FALSE
        END                                             AS is_resolution_sla_breached,

        -- Calculated: first response SLA breach (best-effort)
        CASE
            WHEN first_response_due_by IS NULL THEN FALSE
            WHEN NOW() > first_response_due_by THEN TRUE
            ELSE FALSE
        END                                             AS is_first_response_sla_breached,

        -- Metadata
        NOW()                                           AS _gold_built_at

    FROM source

)

SELECT * FROM enriched
```

> **Important note on `{{ ref() }}` ambiguity:**
>
> Both the bronze and silver directories contain a model named `freshservice_tickets`. dbt resolves `{{ ref('freshservice_tickets') }}` to the model it finds — and if both exist with the same name, dbt will raise an error.
>
> **Fix:** Rename the bronze model to `stg_freshservice_tickets.sql` (staging prefix convention) or use a two-argument ref: `{{ ref('silver', 'freshservice_tickets') }}` if you have configured dbt project-level namespacing. The AI prompts below assume you resolve this before running.

> **🤖 AI Prompt — Resolving dbt ref() ambiguity:**
>
> ```
> I have two dbt models with the same name in different directories:
>
> - dbt/models/bronze/freshservice_tickets.sql (materialized='view', schema='bronze')
> - dbt/models/silver/freshservice_tickets.sql (materialized='incremental', schema='silver')
>
> My gold model uses {{ ref('freshservice_tickets') }} and dbt raises
> a compilation error about duplicate model names.
>
> What is the best practice for resolving this? Options I'm considering:
> 1. Rename the bronze model to stg_freshservice_tickets
> 2. Use two-argument ref syntax
> 3. Use dbt project-level namespacing
>
> Our dbt_project.yml is:
>
> [paste dbt_project.yml]
>
> What do you recommend, and what files do I need to update?
> ```

---

## Step 4 — Build the Daily Metrics Gold Model

Create `dbt/models/gold/freshservice_daily_metrics.sql`:

> **🤖 AI Prompt — Generating the daily metrics model:**
>
> ```
> I need a dbt gold model for daily FreshService ticket metrics.
>
> Architecture context:
> - Source: silver.freshservice_tickets (via {{ ref() }})
> - Target: gold.freshservice_daily_metrics
> - Database: PostgreSQL 15
> - Config: materialized='table', schema='gold'
>
> Output column spec:
>
> [paste the full 2b column specification table]
>
> Requirements:
> 1. Generate a date spine from the earliest created_at to current_date
>    using generate_series() so every day has a row even if no tickets
>    were created
> 2. tickets_created: COUNT of tickets where created_at::DATE = metric_date
> 3. tickets_resolved: COUNT where status_label = 'Resolved' AND
>    updated_at::DATE = metric_date
>    (Note: updated_at is our best proxy for resolution date since
>    FreshService doesn't expose a separate resolved_at in the ticket
>    list endpoint)
> 4. tickets_closed: COUNT where status_label = 'Closed' AND
>    updated_at::DATE = metric_date
> 5. avg_hours_to_resolution: AVG of EXTRACT(EPOCH FROM
>    (updated_at - created_at)) / 3600 for tickets resolved on this day
>    Round to 1 decimal
> 6. open_ticket_backlog: COUNT of tickets where created_at::DATE <= metric_date
>    AND (status_label IN ('Open', 'Pending') OR updated_at::DATE > metric_date)
>    This is a snapshot approximation — explain the limitation in comments
> 7. escalated_tickets_created: COUNT where is_escalated = TRUE AND
>    created_at::DATE = metric_date
> 8. high_urgent_tickets_created: COUNT where priority_label IN ('High', 'Urgent')
>    AND created_at::DATE = metric_date
> 9. pct_resolved_same_day: % of tickets created on metric_date that were
>    also resolved on the same day. Handle division by zero.
> 10. _gold_built_at = NOW()
> 11. CTE structure: date_spine → daily_created → daily_resolved →
>     daily_closed → backlog → joined → final SELECT
> 12. Comment header with a note about the backlog approximation
>
> Generate the complete SQL file.
> ```

### 4a. Example daily metrics model structure

```sql
-- Gold model: FreshService Daily Metrics
-- One row per calendar day with aggregated ticket KPIs.
-- Full table rebuild on each run.
--
-- Note on backlog calculation: Since we only have current ticket state
-- (not historical status changes), the backlog is approximated. A ticket
-- is counted in a day's backlog if it was created on or before that day
-- and its current status is still open/pending. This undercounts historical
-- backlog for tickets that have since been resolved.

{{ config(
    materialized='table',
    schema='gold'
) }}

WITH date_spine AS (

    SELECT d::DATE AS metric_date
    FROM generate_series(
        (SELECT MIN(created_at)::DATE FROM {{ ref('freshservice_tickets') }}),
        CURRENT_DATE,
        '1 day'::INTERVAL
    ) AS d

),

tickets AS (

    SELECT
        *,
        created_at::DATE AS created_date,
        updated_at::DATE AS updated_date
    FROM {{ ref('freshservice_tickets') }}

),

daily_created AS (

    SELECT
        created_date AS metric_date,
        COUNT(*)                                                    AS tickets_created,
        COUNT(*) FILTER (WHERE is_escalated)                        AS escalated_tickets_created,
        COUNT(*) FILTER (WHERE priority_label IN ('High', 'Urgent'))AS high_urgent_tickets_created
    FROM tickets
    GROUP BY created_date

),

daily_resolved AS (

    SELECT
        updated_date AS metric_date,
        COUNT(*)     AS tickets_resolved,
        ROUND(
            AVG(EXTRACT(EPOCH FROM (updated_at - created_at)) / 3600), 1
        )            AS avg_hours_to_resolution
    FROM tickets
    WHERE status_label = 'Resolved'
    GROUP BY updated_date

),

daily_closed AS (

    SELECT updated_date AS metric_date, COUNT(*) AS tickets_closed
    FROM tickets
    WHERE status_label = 'Closed'
    GROUP BY updated_date

),

same_day_resolution AS (

    SELECT
        created_date AS metric_date,
        COUNT(*) FILTER (
            WHERE status_label IN ('Resolved', 'Closed')
              AND updated_date = created_date
        )                                                     AS resolved_same_day,
        COUNT(*)                                              AS total_created
    FROM tickets
    GROUP BY created_date

),

backlog AS (

    SELECT
        ds.metric_date,
        COUNT(*) FILTER (
            WHERE t.created_date <= ds.metric_date
              AND t.status_label IN ('Open', 'Pending')
        ) AS open_ticket_backlog
    FROM date_spine ds
    CROSS JOIN tickets t
    GROUP BY ds.metric_date

),

joined AS (

    SELECT
        ds.metric_date,
        COALESCE(dc.tickets_created, 0)                   AS tickets_created,
        COALESCE(dr.tickets_resolved, 0)                   AS tickets_resolved,
        COALESCE(dcl.tickets_closed, 0)                    AS tickets_closed,
        dr.avg_hours_to_resolution,
        COALESCE(b.open_ticket_backlog, 0)                 AS open_ticket_backlog,
        COALESCE(dc.escalated_tickets_created, 0)          AS escalated_tickets_created,
        COALESCE(dc.high_urgent_tickets_created, 0)        AS high_urgent_tickets_created,
        CASE
            WHEN COALESCE(sdr.total_created, 0) = 0 THEN 0
            ELSE ROUND(
                sdr.resolved_same_day::NUMERIC / sdr.total_created * 100, 1
            )
        END                                                AS pct_resolved_same_day,
        NOW()                                              AS _gold_built_at
    FROM date_spine ds
    LEFT JOIN daily_created dc ON ds.metric_date = dc.metric_date
    LEFT JOIN daily_resolved dr ON ds.metric_date = dr.metric_date
    LEFT JOIN daily_closed dcl ON ds.metric_date = dcl.metric_date
    LEFT JOIN same_day_resolution sdr ON ds.metric_date = sdr.metric_date
    LEFT JOIN backlog b ON ds.metric_date = b.metric_date

)

SELECT * FROM joined
ORDER BY metric_date
```

> **Performance note:** The backlog CTE uses a CROSS JOIN which can be expensive with large ticket volumes. If you experience slow build times, consider the alternative approach in prompt G7 in the appendix.

---

## Step 5 — Build the SLA Performance Gold Model

Create `dbt/models/gold/freshservice_sla_performance.sql`:

> **🤖 AI Prompt — Generating the SLA performance model:**
>
> ```
> I need a dbt gold model for FreshService SLA performance reporting.
>
> Architecture context:
> - Source: silver.freshservice_tickets (via {{ ref() }})
> - Target: gold.freshservice_sla_performance
> - Database: PostgreSQL 15
> - Config: materialized='table', schema='gold'
>
> Output column spec:
>
> [paste the full 2c column specification table]
>
> Requirements:
> 1. Generate rows at two granularities: weekly and monthly
>    - Weekly: DATE_TRUNC('week', created_at)
>    - Monthly: DATE_TRUNC('month', created_at)
> 2. For each period, generate rows at three group levels:
>    - Overall (group_id = NULL, category = NULL)
>    - By group_id (category = NULL)
>    - By category (group_id = NULL)
> 3. Resolution SLA logic:
>    - MET: status_label IN ('Resolved', 'Closed') AND
>      (due_by IS NULL OR updated_at <= due_by)
>    - BREACHED: status_label IN ('Resolved', 'Closed') AND
>      due_by IS NOT NULL AND updated_at > due_by
>    - Exclude open/pending tickets from resolution SLA counts
> 4. First response SLA logic:
>    - MET: first_response_due_by IS NULL OR NOW() <= first_response_due_by
>    - BREACHED: first_response_due_by IS NOT NULL AND NOW() > first_response_due_by
>    - Note: this is approximate since we lack actual first response timestamps
> 5. Calculate percentage as: met / (met + breached) * 100, handle zero division
> 6. UNION ALL the weekly and monthly CTEs
> 7. _gold_built_at = NOW()
> 8. Comment header noting the first response SLA limitation
>
> Generate the complete SQL file.
> ```

### 5a. Example SLA performance model structure

```sql
-- Gold model: FreshService SLA Performance
-- SLA compliance rates by week/month, overall and sliced by group/category.
-- Full table rebuild on each run.
--
-- Limitation: First response SLA is approximate. The FreshService ticket
-- list endpoint does not include an actual first_response_at timestamp.
-- We can only check if the SLA deadline has passed, not whether a response
-- was actually sent before it.

{{ config(
    materialized='table',
    schema='gold'
) }}

WITH resolved_tickets AS (

    SELECT
        *,
        DATE_TRUNC('week', created_at)::DATE    AS week_start,
        DATE_TRUNC('month', created_at)::DATE   AS month_start,

        -- Resolution SLA
        CASE
            WHEN due_by IS NULL THEN TRUE
            WHEN updated_at <= due_by THEN TRUE
            ELSE FALSE
        END AS resolution_sla_met,

        -- First response SLA (approximate)
        CASE
            WHEN first_response_due_by IS NULL THEN TRUE
            WHEN NOW() <= first_response_due_by THEN TRUE
            ELSE FALSE
        END AS first_response_sla_met

    FROM {{ ref('freshservice_tickets') }}
    WHERE status_label IN ('Resolved', 'Closed')

),

-- Weekly: overall
weekly_overall AS (
    SELECT
        week_start                          AS period_start,
        'weekly'::TEXT                      AS period_type,
        NULL::INTEGER                       AS group_id,
        NULL::TEXT                          AS category,
        COUNT(*)                            AS total_tickets,
        COUNT(*) FILTER (WHERE resolution_sla_met)       AS resolution_sla_met,
        COUNT(*) FILTER (WHERE NOT resolution_sla_met)   AS resolution_sla_breached,
        COUNT(*) FILTER (WHERE first_response_sla_met)   AS first_response_sla_met,
        COUNT(*) FILTER (WHERE NOT first_response_sla_met) AS first_response_sla_breached
    FROM resolved_tickets
    GROUP BY week_start
),

-- Weekly: by group
weekly_by_group AS (
    SELECT
        week_start, 'weekly'::TEXT, group_id, NULL::TEXT,
        COUNT(*),
        COUNT(*) FILTER (WHERE resolution_sla_met),
        COUNT(*) FILTER (WHERE NOT resolution_sla_met),
        COUNT(*) FILTER (WHERE first_response_sla_met),
        COUNT(*) FILTER (WHERE NOT first_response_sla_met)
    FROM resolved_tickets
    WHERE group_id IS NOT NULL
    GROUP BY week_start, group_id
),

-- Weekly: by category
weekly_by_category AS (
    SELECT
        week_start, 'weekly'::TEXT, NULL::INTEGER, category,
        COUNT(*),
        COUNT(*) FILTER (WHERE resolution_sla_met),
        COUNT(*) FILTER (WHERE NOT resolution_sla_met),
        COUNT(*) FILTER (WHERE first_response_sla_met),
        COUNT(*) FILTER (WHERE NOT first_response_sla_met)
    FROM resolved_tickets
    WHERE category IS NOT NULL
    GROUP BY week_start, category
),

-- Monthly: overall
monthly_overall AS (
    SELECT
        month_start, 'monthly'::TEXT, NULL::INTEGER, NULL::TEXT,
        COUNT(*),
        COUNT(*) FILTER (WHERE resolution_sla_met),
        COUNT(*) FILTER (WHERE NOT resolution_sla_met),
        COUNT(*) FILTER (WHERE first_response_sla_met),
        COUNT(*) FILTER (WHERE NOT first_response_sla_met)
    FROM resolved_tickets
    GROUP BY month_start
),

-- Monthly: by group
monthly_by_group AS (
    SELECT
        month_start, 'monthly'::TEXT, group_id, NULL::TEXT,
        COUNT(*),
        COUNT(*) FILTER (WHERE resolution_sla_met),
        COUNT(*) FILTER (WHERE NOT resolution_sla_met),
        COUNT(*) FILTER (WHERE first_response_sla_met),
        COUNT(*) FILTER (WHERE NOT first_response_sla_met)
    FROM resolved_tickets
    WHERE group_id IS NOT NULL
    GROUP BY month_start, group_id
),

-- Monthly: by category
monthly_by_category AS (
    SELECT
        month_start, 'monthly'::TEXT, NULL::INTEGER, category,
        COUNT(*),
        COUNT(*) FILTER (WHERE resolution_sla_met),
        COUNT(*) FILTER (WHERE NOT resolution_sla_met),
        COUNT(*) FILTER (WHERE first_response_sla_met),
        COUNT(*) FILTER (WHERE NOT first_response_sla_met)
    FROM resolved_tickets
    WHERE category IS NOT NULL
    GROUP BY month_start, category
),

combined AS (
    SELECT * FROM weekly_overall
    UNION ALL SELECT * FROM weekly_by_group
    UNION ALL SELECT * FROM weekly_by_category
    UNION ALL SELECT * FROM monthly_overall
    UNION ALL SELECT * FROM monthly_by_group
    UNION ALL SELECT * FROM monthly_by_category
),

final AS (
    SELECT
        period_start,
        period_type,
        group_id,
        category,
        total_tickets,
        resolution_sla_met,
        resolution_sla_breached,
        CASE
            WHEN total_tickets = 0 THEN 0
            ELSE ROUND(resolution_sla_met::NUMERIC / total_tickets * 100, 1)
        END AS resolution_sla_pct,
        first_response_sla_met,
        first_response_sla_breached,
        CASE
            WHEN total_tickets = 0 THEN 0
            ELSE ROUND(first_response_sla_met::NUMERIC / total_tickets * 100, 1)
        END AS first_response_sla_pct,
        NOW() AS _gold_built_at
    FROM combined
)

SELECT * FROM final
ORDER BY period_start DESC, period_type, group_id NULLS FIRST, category NULLS FIRST
```

---

## Step 6 — Add Schema Documentation and Tests

Add entries for all three gold models to `dbt/models/schema.yml`.

> **🤖 AI Prompt — Generating schema.yml for all gold models:**
>
> ```
> Generate dbt schema.yml entries for three gold FreshService models.
>
> Model 1: freshservice_ticket_summary
> Description: Enriched ticket-level detail with calculated durations and SLA flags.
> Columns: [paste 2a column spec]
> Tests:
> - ticket_id: unique, not_null
> - status_label: not_null, accepted_values [Open, Pending, Resolved, Closed]
> - priority_label: not_null, accepted_values [Low, Medium, High, Urgent]
> - created_at, created_date: not_null
> - _gold_built_at: not_null
>
> Model 2: freshservice_daily_metrics
> Description: Daily aggregated ticket KPIs with one row per calendar day.
> Columns: [paste 2b column spec]
> Tests:
> - metric_date: unique, not_null
> - tickets_created: not_null, >= 0 (use dbt_utils.expression_is_true
>   or a custom test)
> - _gold_built_at: not_null
>
> Model 3: freshservice_sla_performance
> Description: SLA compliance rates by period, group, and category.
> Columns: [paste 2c column spec]
> Tests:
> - Combination of (period_start, period_type, group_id, category): unique
>   (use dbt_utils.unique_combination_of_columns or surrogate key approach)
> - period_type: accepted_values [weekly, monthly]
> - resolution_sla_pct: between 0 and 100
> - _gold_built_at: not_null
>
> Format as valid YAML. Note if any tests require dbt_utils package.
> ```

---

## Step 7 — Run and Validate All Gold Models

### 7a. Build all gold models

```bash
# Run all gold models
docker compose exec dagster dbt run \
  --project-dir /opt/dagster/dbt \
  --select gold.*

# Run tests
docker compose exec dagster dbt test \
  --project-dir /opt/dagster/dbt \
  --select gold.*
```

### 7b. Validate each model

```bash
docker compose exec postgres psql -U warehouse -d data_warehouse
```

**Ticket summary:**

```sql
-- Row count should match silver
SELECT
    (SELECT COUNT(*) FROM silver.freshservice_tickets) AS silver_rows,
    (SELECT COUNT(*) FROM gold.freshservice_ticket_summary) AS gold_rows;

-- Verify calculated fields
SELECT
    ticket_id, status_label, hours_since_created,
    is_open, is_resolution_sla_breached, created_date
FROM gold.freshservice_ticket_summary
WHERE is_resolution_sla_breached = TRUE
LIMIT 10;

-- Sanity check: is_open should match status
SELECT status_label, is_open, COUNT(*)
FROM gold.freshservice_ticket_summary
GROUP BY status_label, is_open
ORDER BY status_label;
```

**Daily metrics:**

```sql
-- Check date range coverage
SELECT MIN(metric_date), MAX(metric_date), COUNT(*) AS total_days
FROM gold.freshservice_daily_metrics;

-- No gaps (total_days should equal date range + 1)
SELECT
    MAX(metric_date) - MIN(metric_date) + 1 AS expected_days,
    COUNT(*) AS actual_days
FROM gold.freshservice_daily_metrics;

-- Spot check a recent day
SELECT *
FROM gold.freshservice_daily_metrics
WHERE metric_date = CURRENT_DATE - INTERVAL '1 day';

-- Verify totals reconcile with silver
SELECT
    SUM(tickets_created) AS gold_total_created,
    (SELECT COUNT(*) FROM silver.freshservice_tickets) AS silver_total
FROM gold.freshservice_daily_metrics;
```

**SLA performance:**

```sql
-- Check row distribution
SELECT period_type, COUNT(*) AS rows
FROM gold.freshservice_sla_performance
GROUP BY period_type;

-- Verify percentages are within range
SELECT
    MIN(resolution_sla_pct) AS min_pct,
    MAX(resolution_sla_pct) AS max_pct
FROM gold.freshservice_sla_performance;

-- Sample overall weekly performance
SELECT period_start, total_tickets, resolution_sla_pct, first_response_sla_pct
FROM gold.freshservice_sla_performance
WHERE period_type = 'weekly' AND group_id IS NULL AND category IS NULL
ORDER BY period_start DESC
LIMIT 10;
```

> **🤖 AI Prompt — Diagnosing data mismatches:**
>
> ```
> My gold model row counts don't match expectations.
>
> Silver row count: [number]
> Gold ticket_summary row count: [number]
> Gold daily_metrics SUM(tickets_created): [number]
>
> Here is my gold model SQL:
>
> [paste the model]
>
> And here are some sample silver rows that might be missing from gold:
>
> [paste sample rows]
>
> Why might the counts differ, and how do I fix it?
> ```

---

## Step 8 — Register in Dagster and Verify the Full Pipeline

### 8a. Verify the asset graph

Since the gold models use `{{ ref('freshservice_tickets') }}`, Dagster will automatically detect the dependency chain through the dbt manifest.

Regenerate the manifest and restart:

```bash
docker compose exec dagster dbt compile --project-dir /opt/dagster/dbt
docker compose restart dagster
```

### 8b. Check the full asset graph

Open the **Dagster UI** at `http://localhost:3002` → **Assets** → **Asset Graph**.

You should see the complete pipeline:

```
[Airbyte: freshservice sync]
        ↓
[dbt: freshservice_tickets (bronze view)]
        ↓
[dbt: freshservice_tickets (silver incremental)]
        ↓
    ┌───────────────┬───────────────────────┐
    ↓               ↓                       ↓
[gold:          [gold:                  [gold:
 ticket_        daily_                  sla_
 summary]       metrics]                performance]
```

### 8c. Test a full pipeline run

1. In Dagster, select the **Airbyte FreshService asset**
2. Click **Materialize all** (this should cascade through the full chain)
3. Monitor each step: Airbyte sync → bronze → silver → all three gold models
4. Confirm all steps show green checkmarks

### 8d. Verify the schedule

Confirm the daily 6 AM schedule (configured in the Bronze guide) triggers the full chain. In Dagster UI → **Schedules**, verify the schedule includes all assets from Airbyte through gold.

> **🤖 AI Prompt — Configuring Dagster to run gold models:**
>
> ```
> My Dagster asset graph shows the bronze and silver dbt models but not
> the gold models.
>
> Current definitions.py:
> [paste contents]
>
> Gold model files:
> - dbt/models/gold/freshservice_ticket_summary.sql
> - dbt/models/gold/freshservice_daily_metrics.sql
> - dbt/models/gold/freshservice_sla_performance.sql
>
> All three use {{ ref('freshservice_tickets') }}.
>
> dbt_project.yml:
> [paste contents]
>
> I have already run dbt compile. What could cause the gold models
> to be missing from the Dagster graph?
> ```

---

## Step 9 — Connect Gold Models to Metabase

### 9a. Sync the schema

1. Open **Metabase** at `http://localhost:3000`
2. Go to **Admin** (gear icon) → **Databases**
3. Click your PostgreSQL database → **Sync database schema now**
4. Wait for the sync to complete (usually 30-60 seconds)

### 9b. Verify table visibility

1. Click **+ New** → **Question** (or **SQL query**)
2. Select the database → browse to the `gold` schema
3. You should see all three tables:
   - `freshservice_ticket_summary`
   - `freshservice_daily_metrics`
   - `freshservice_sla_performance`

### 9c. Create starter dashboard queries

Test each gold model with a simple Metabase query:

**Open tickets by priority (ticket_summary):**

```sql
SELECT priority_label, COUNT(*) AS open_tickets
FROM gold.freshservice_ticket_summary
WHERE is_open = TRUE
GROUP BY priority_label
ORDER BY open_tickets DESC;
```

**Weekly ticket trend (daily_metrics):**

```sql
SELECT
    DATE_TRUNC('week', metric_date)::DATE AS week,
    SUM(tickets_created) AS created,
    SUM(tickets_resolved) AS resolved
FROM gold.freshservice_daily_metrics
GROUP BY week
ORDER BY week DESC
LIMIT 12;
```

**Monthly SLA trend (sla_performance):**

```sql
SELECT period_start, resolution_sla_pct, first_response_sla_pct
FROM gold.freshservice_sla_performance
WHERE period_type = 'monthly'
  AND group_id IS NULL
  AND category IS NULL
ORDER BY period_start DESC
LIMIT 12;
```

> **🤖 AI Prompt — Building a Metabase dashboard:**
>
> ```
> I need to build a Metabase dashboard for FreshService ticket reporting.
> I have three gold tables available:
>
> 1. gold.freshservice_ticket_summary — one row per ticket with:
>    [paste column list]
>
> 2. gold.freshservice_daily_metrics — one row per day with:
>    [paste column list]
>
> 3. gold.freshservice_sla_performance — SLA rates by period with:
>    [paste column list]
>
> Please design a dashboard layout with:
> 1. A top row of KPI cards (open tickets, avg resolution time,
>    SLA compliance %, tickets created today)
> 2. A ticket volume trend chart (daily or weekly)
> 3. An SLA compliance trend chart
> 4. A breakdown table of open tickets by priority and group
> 5. A bar chart of top 10 categories by ticket volume
>
> For each dashboard element, provide:
> - The SQL query to use
> - The recommended Metabase visualization type
> - Any filters to add
> ```

---

## Step 10 — End-to-End Validation

| Check | Command / Action | Expected Result |
|---|---|---|
| All gold models build | `dbt run --select gold.*` | No errors |
| All gold tests pass | `dbt test --select gold.*` | All green |
| Ticket summary count matches silver | Compare `COUNT(*)` | Counts equal |
| Daily metrics has no date gaps | Compare expected vs actual day count | No gaps |
| SLA percentages are 0-100 | `MIN/MAX` on pct columns | Within range |
| No unexpected 'Unknown' values | Query for Unknown in label columns | 0 or known gaps |
| Dagster graph shows full chain | Asset Graph in Dagster UI | Airbyte → bronze → silver → 3 gold |
| Full pipeline materializes | Materialize all from Airbyte | All steps green |
| Schedule is active | Dagster Schedules tab | Daily 6 AM running |
| Gold tables visible in Metabase | Admin → Sync → New Question | 3 tables in gold schema |
| BI queries return data | Run starter queries in Metabase | Results displayed |
| `bi_readonly` has access | Test with read-only role | SELECT succeeds |

---

## Appendix — AI Prompt Templates

### G1. Discovering reporting requirements

```
I'm building gold-layer dbt models for FreshService ticket data to power
Metabase dashboards for our IT service desk.

Silver table columns:
[paste \d silver.freshservice_tickets]

Dashboard requirements: operational volume, SLA tracking, workload distribution.

Planned gold models:
1. freshservice_ticket_summary — ticket-level enriched detail
2. freshservice_daily_metrics — daily aggregated KPIs
3. freshservice_sla_performance — SLA compliance breakdowns

Questions:
1. Are three models sufficient or should I add more?
2. What columns and metrics for each?
3. Any common IT service desk metrics I'm missing?
```

### G2. Reviewing gold model designs

```
I'm designing three gold dbt models. Here are my column specs:

Model 1: [paste 2a table]
Model 2: [paste 2b table]
Model 3: [paste 2c table]

Source silver columns: [paste]

Review:
1. Are definitions complete and useful for BI?
2. Any calculated fields to add or remove?
3. Are SLA calculations logically sound?
4. Better approaches for backlog calculation?
```

### G3. Generating the ticket summary model

```
I need a dbt gold model for enriched FreshService ticket summary.
Source: silver.freshservice_tickets via {{ ref() }}
Target: gold.freshservice_ticket_summary
Config: materialized='table', schema='gold'
Output columns: [paste 2a spec]

[paste the full requirements list from Step 3]

Generate the complete SQL file.
```

### G4. Generating the daily metrics model

```
I need a dbt gold model for daily FreshService ticket metrics.
Source: silver.freshservice_tickets via {{ ref() }}
Target: gold.freshservice_daily_metrics
Config: materialized='table', schema='gold'
Output columns: [paste 2b spec]

[paste the full requirements list from Step 4]

Generate the complete SQL file.
```

### G5. Generating the SLA performance model

```
I need a dbt gold model for FreshService SLA performance.
Source: silver.freshservice_tickets via {{ ref() }}
Target: gold.freshservice_sla_performance
Config: materialized='table', schema='gold'
Output columns: [paste 2c spec]

[paste the full requirements list from Step 5]

Generate the complete SQL file.
```

### G6. Generating schema.yml for gold models

```
Generate dbt schema.yml entries for three gold FreshService models.

[paste the full prompt from Step 6]

Format as valid YAML.
```

### G7. Optimizing the backlog CROSS JOIN

```
My gold daily metrics model uses a CROSS JOIN between a date_spine
and the full tickets table to calculate daily backlog. With [X] tickets
and [Y] days, this produces [X * Y] rows and takes [time] to build.

Current SQL:
[paste the backlog CTE]

How can I optimize this? Options I'm considering:
1. Window function approach (running count)
2. Pre-aggregating ticket open/close events
3. Materializing a separate backlog snapshot model

Which approach is best for PostgreSQL 15, and can you generate the SQL?
```

### G8. Building Metabase dashboards

```
I need to build a Metabase dashboard for FreshService ticket reporting.
Gold tables available:

1. gold.freshservice_ticket_summary: [columns]
2. gold.freshservice_daily_metrics: [columns]
3. gold.freshservice_sla_performance: [columns]

Design a dashboard with:
1. KPI cards (open tickets, avg resolution time, SLA %, tickets today)
2. Volume trend chart
3. SLA compliance trend
4. Open tickets by priority/group table
5. Top 10 categories bar chart

Provide SQL queries and recommended Metabase visualization types.
```

### G9. Debugging data mismatches between layers

```
My gold model row counts don't match expectations.
Silver row count: [number]
Gold ticket_summary count: [number]
Gold daily_metrics SUM(tickets_created): [number]

Gold model SQL: [paste]
Sample silver rows that might be missing: [paste]

Why might counts differ and how do I fix it?
```

### G10. Resolving dbt ref() ambiguity

```
I have two dbt models with the same name in different directories:
- dbt/models/bronze/freshservice_tickets.sql (view, bronze schema)
- dbt/models/silver/freshservice_tickets.sql (incremental, silver schema)

My gold model uses {{ ref('freshservice_tickets') }} and dbt raises a
compilation error about duplicate model names.

dbt_project.yml: [paste]

What is the best practice for resolving this? What files need updating?
```

### G11. Adding a new gold model for a different use case

```
I have a working silver.freshservice_tickets table and three gold models
(ticket_summary, daily_metrics, sla_performance).

A stakeholder has requested a new report showing:
[describe the reporting need]

Should this be a new gold model, or can it be served by the existing
ones? If new, generate the full dbt model SQL and schema.yml entry
following our conventions (materialized='table', schema='gold',
CTE structure, _gold_built_at column).
```
