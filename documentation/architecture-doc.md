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
├── airbyte/                      # Separate Airbyte install (own compose via run-ab-platform.sh)
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
│       ├── gold/                 # Aggregated table models
│       └── schema.yml            # Column docs + tests (unique, not_null)
├── init-scripts/
│   └── 01-init-schemas.sql       # Creates schemas, roles, permissions on first boot
├── prometheus/
│   └── prometheus.yml            # Scrape configs (self + postgres-exporter)
├── grafana/
│   └── provisioning/datasources/ # Auto-provisions Prometheus + PostgreSQL datasources
├── scripts/
│   ├── backup.sh                 # Daily pg_dumpall + config tarballs, 30-day retention
│   └── health_check.sh           # Checks all service endpoints + disk usage
├── backups/
├── logs/
└── docs/
    ├── adrs/                     # Architecture Decision Records
    └── runbooks/                 # Operational procedures
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
