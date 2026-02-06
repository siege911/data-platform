# Open Source Data Pipeline Strategy Plan
## For Small Teams Using Medallion Architecture

---

## Executive Summary

This plan outlines a pragmatic approach to building a SaaS data pipeline using open-source tools optimized for a small team (1-2 people). The focus is on low-code/no-code solutions, self-documenting systems, and sustainable maintenance.

**Key Principles:**
- Minimize custom code in favor of configuration-driven tools
- Prioritize tools with visual interfaces and built-in documentation
- Design for "bus factor" resilience (knowledge shouldn't leave with a person)
- Start simple, add complexity only when needed

---

## 1. Recommended Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        INFRASTRUCTURE LAYER                              │
│                    Docker Compose on Single VM/Server                    │
│                    (or Managed Kubernetes if budget allows)              │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
        ┌───────────────────────────┼───────────────────────────┐
        ▼                           ▼                           ▼
┌───────────────┐          ┌───────────────┐          ┌───────────────┐
│   INGESTION   │          │  ORCHESTRATION │          │   STORAGE     │
│               │          │                │          │               │
│   Airbyte     │◄────────►│    Dagster     │◄────────►│  PostgreSQL   │
│   (UI-based)  │          │    (UI+Code)   │          │  (Bronze/     │
│               │          │                │          │   Silver)     │
└───────────────┘          └───────────────┘          │               │
                                    │                  │  DuckDB       │
                                    │                  │  (Analytics)  │
                                    ▼                  └───────────────┘
                           ┌───────────────┐                   │
                           │ TRANSFORMATION │                   │
                           │                │                   │
                           │   dbt Core     │◄──────────────────┘
                           │   (SQL-based)  │
                           └───────────────┘
                                    │
        ┌───────────────────────────┼───────────────────────────┐
        ▼                           ▼                           ▼
┌───────────────┐          ┌───────────────┐          ┌───────────────┐
│      BI       │          │   AI/ML       │          │  MONITORING   │
│               │          │               │          │               │
│   Metabase    │          │ Evidence.dev  │          │   Prometheus  │
│   or Apache   │          │ + Claude API  │          │   + Grafana   │
│   Superset    │          │               │          │               │
└───────────────┘          └───────────────┘          └───────────────┘
```

---

## 2. Infrastructure Recommendations

### Option A: Single Server with Docker Compose (Recommended for Start)

**Why:** Simplest to manage, lowest cost, sufficient for small-medium data volumes.

**Specifications:**
- **VM Size:** 8-16 GB RAM, 4-8 vCPUs, 500GB-1TB SSD storage
- **OS:** Ubuntu 22.04 LTS or Rocky Linux 9
- **Container Runtime:** Docker with Docker Compose

**Estimated Monthly Cost:** $50-150/month (cloud) or one-time hardware investment

**Pros:**
- Single point of management
- All services communicate locally (fast, secure)
- Easy backup strategy (snapshot entire VM)
- Simple networking

**Cons:**
- Single point of failure (mitigate with automated backups)
- Limited horizontal scaling

### Option B: Managed Kubernetes (Future Growth)

**When to Consider:**
- Data volume exceeds 100GB/day
- Need high availability
- Team grows to 3+ people

**Recommended Platforms:**
- DigitalOcean Kubernetes (simplest)
- Linode Kubernetes Engine
- Self-hosted K3s (lightweight Kubernetes)

---

## 3. Software Stack Selection

### 3.1 Data Ingestion: **Airbyte** (Primary Recommendation)

**Why Airbyte:**
- ✅ Full UI-based configuration (no code required for most connectors)
- ✅ 300+ pre-built connectors for SaaS APIs
- ✅ Automatic schema detection and evolution
- ✅ Built-in change data capture (CDC)
- ✅ Configurations stored as YAML (version controllable)
- ✅ Self-documenting: UI shows exactly what's configured

**How It Works:**
1. Add source (your SaaS app) via UI
2. Add destination (your database) via UI
3. Configure sync frequency and mode
4. Airbyte handles API pagination, rate limiting, error retry

**Alternative:** Meltano (more Python-native, steeper learning curve)

### 3.2 Data Storage

#### Bronze Layer: **PostgreSQL**

**Why PostgreSQL:**
- ✅ Rock-solid reliability
- ✅ Excellent tooling ecosystem
- ✅ JSON/JSONB support for semi-structured data
- ✅ Your team likely already knows SQL
- ✅ Free, open source, massive community

**Schema Strategy:**
```sql
-- Bronze layer: raw data, append-only
CREATE SCHEMA bronze;

-- Each source gets a table
CREATE TABLE bronze.salesforce_contacts (
    _airbyte_raw_id UUID PRIMARY KEY,
    _airbyte_extracted_at TIMESTAMP,
    _airbyte_loaded_at TIMESTAMP,
    _airbyte_data JSONB  -- Raw API response
);
```

#### Silver Layer: **PostgreSQL** (same instance, different schema)

```sql
-- Silver layer: cleaned, typed, deduplicated
CREATE SCHEMA silver;

CREATE TABLE silver.contacts (
    contact_id VARCHAR PRIMARY KEY,
    email VARCHAR,
    first_name VARCHAR,
    last_name VARCHAR,
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    _dbt_loaded_at TIMESTAMP
);
```

#### Analytics/Gold Layer: **DuckDB** (Optional, Recommended)

**Why DuckDB:**
- ✅ Blazing fast analytical queries
- ✅ Zero configuration
- ✅ Can query Parquet files directly
- ✅ Integrates with Python seamlessly
- ✅ Perfect for AI/ML data preparation

### 3.3 Transformation: **dbt Core**

**Why dbt:**
- ✅ SQL-based (accessible to non-engineers)
- ✅ Self-documenting (generates docs automatically)
- ✅ Built-in data lineage visualization
- ✅ Version controllable
- ✅ Industry standard

**Example dbt Model (Silver Layer):**
```sql
-- models/silver/contacts.sql

{{ config(
    materialized='incremental',
    unique_key='contact_id'
) }}

SELECT
    _airbyte_data->>'Id' AS contact_id,
    _airbyte_data->>'Email' AS email,
    _airbyte_data->>'FirstName' AS first_name,
    _airbyte_data->>'LastName' AS last_name,
    (_airbyte_data->>'CreatedDate')::timestamp AS created_at,
    (_airbyte_data->>'LastModifiedDate')::timestamp AS updated_at,
    CURRENT_TIMESTAMP AS _dbt_loaded_at
FROM {{ source('bronze', 'salesforce_contacts') }}

{% if is_incremental() %}
WHERE _airbyte_extracted_at > (SELECT MAX(_dbt_loaded_at) FROM {{ this }})
{% endif %}
```

### 3.4 Orchestration: **Dagster** (Primary Recommendation)

**Why Dagster:**
- ✅ Beautiful UI for monitoring and triggering jobs
- ✅ Native integrations with Airbyte and dbt
- ✅ Asset-based mental model (easier to understand)
- ✅ Built-in data lineage
- ✅ Excellent documentation
- ✅ Python-based but low-code for simple workflows

**Alternative:** Apache Airflow (more mature but steeper learning curve)

**Example Dagster Pipeline:**
```python
# pipelines/daily_sync.py

from dagster import (
    Definitions, 
    asset,
    AssetExecutionContext,
    ScheduleDefinition
)
from dagster_airbyte import AirbyteResource, airbyte_assets
from dagster_dbt import DbtCliResource, dbt_assets

# Airbyte sync - defined entirely in Airbyte UI
salesforce_sync = airbyte_assets(
    connection_id="your-airbyte-connection-id",
    name="salesforce_bronze"
)

# dbt transformations
@dbt_assets(manifest_path="path/to/dbt/manifest.json")
def my_dbt_assets(context: AssetExecutionContext, dbt: DbtCliResource):
    yield from dbt.cli(["build"], context=context).stream()

# Schedule: run daily at 6 AM
daily_schedule = ScheduleDefinition(
    job_name="daily_data_sync",
    cron_schedule="0 6 * * *"
)

defs = Definitions(
    assets=[salesforce_sync, my_dbt_assets],
    schedules=[daily_schedule],
    resources={
        "airbyte": AirbyteResource(host="localhost", port="8000"),
        "dbt": DbtCliResource(project_dir="path/to/dbt")
    }
)
```

### 3.5 Business Intelligence: **Metabase**

**Why Metabase:**
- ✅ Most user-friendly open-source BI tool
- ✅ No-code query builder
- ✅ Beautiful dashboards out of the box
- ✅ Non-technical users can self-serve
- ✅ Embeddable charts

**Alternative:** Apache Superset (more powerful, steeper learning curve)

### 3.6 AI/ML Integration

**Recommended Approach: Evidence.dev + Claude API**

**Evidence.dev:**
- Markdown-based BI reports
- Version controllable
- Can embed Python/SQL analysis

**Claude API Integration:**
```python
# ai_insights/generate_report.py

import anthropic
import duckdb

def generate_insights(query_results: dict) -> str:
    client = anthropic.Anthropic()
    
    message = client.messages.create(
        model="claude-sonnet-4-20250514",
        max_tokens=1024,
        messages=[
            {
                "role": "user",
                "content": f"""Analyze this business data and provide 
                3-5 key insights:
                
                {query_results}
                
                Focus on trends, anomalies, and actionable recommendations."""
            }
        ]
    )
    return message.content[0].text
```

---

## 4. Pipeline Process Flow

### Daily Operations Flow

```
┌──────────────────────────────────────────────────────────────────┐
│                     DAILY PIPELINE EXECUTION                      │
│                      (Orchestrated by Dagster)                    │
└──────────────────────────────────────────────────────────────────┘

06:00 AM ──► STEP 1: Airbyte Sync Triggered
             │
             ├── Salesforce API → bronze.salesforce_*
             ├── HubSpot API → bronze.hubspot_*
             ├── Stripe API → bronze.stripe_*
             └── [Other SaaS sources]
             │
             ▼
07:00 AM ──► STEP 2: dbt Bronze → Silver Transformations
             │
             ├── Clean and type raw data
             ├── Deduplicate records
             ├── Apply business logic
             └── Update silver.* tables
             │
             ▼
07:30 AM ──► STEP 3: dbt Silver → Gold Transformations (if needed)
             │
             ├── Build aggregations
             ├── Create denormalized views
             └── Prepare ML features
             │
             ▼
08:00 AM ──► STEP 4: dbt Tests & Documentation
             │
             ├── Run data quality tests
             ├── Generate updated docs
             └── Alert on failures
             │
             ▼
08:15 AM ──► STEP 5: AI Insights Generation (Weekly)
             │
             ├── Query key metrics
             ├── Send to Claude API
             └── Store insights report
             │
             ▼
08:30 AM ──► STEP 6: Metabase Cache Refresh
             │
             └── Dashboard data updated
```

### Error Handling Flow

```
Pipeline Step Fails
        │
        ▼
┌───────────────────┐
│ Dagster Detects   │
│ Failure           │
└───────────────────┘
        │
        ├──► Automatic Retry (3 attempts with backoff)
        │
        ├──► If still failing:
        │    ├── Send Slack/Email alert
        │    ├── Log detailed error
        │    └── Mark downstream assets as "stale"
        │
        └──► On recovery:
             └── Resume from failed step (not full restart)
```

---

## 5. Workload & Staffing Approach

### Recommended Team Structure (1-2 People)

**Role: Data Platform Owner (Primary)**
- Responsibilities:
  - Monitor daily pipeline runs (15 min/day)
  - Respond to alerts
  - Add new data sources via Airbyte UI
  - Write/modify dbt models
  - Create Metabase dashboards
  
**Role: Technical Backup (Secondary)**
- Responsibilities:
  - Understand overall architecture
  - Can restart services and read logs
  - Emergency contact for infrastructure

### AI-Assisted Development Strategy

**Recommended Tools:**
1. **Claude Code** (Anthropic): For writing dbt models, Dagster pipelines, and troubleshooting
2. **GitHub Copilot**: For in-IDE Python/SQL assistance
3. **Cursor IDE**: AI-native code editor

**Workflow:**
```
New Requirement (e.g., "Add Zendesk data")
        │
        ▼
┌───────────────────────────────────────┐
│ 1. Configure in Airbyte UI (no code)  │
│    - Add Zendesk source              │
│    - Add PostgreSQL destination      │
│    - Configure sync schedule         │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│ 2. Generate dbt model with AI        │
│                                       │
│ Prompt: "Write a dbt model that      │
│ transforms bronze.zendesk_tickets    │
│ into silver.support_tickets with     │
│ fields: ticket_id, subject, status,  │
│ priority, created_at, resolved_at"   │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│ 3. Review, test, deploy              │
│    - Human reviews AI output         │
│    - Run dbt test                    │
│    - Commit to Git                   │
└───────────────────────────────────────┘
```

### When to Consider External Help

| Scenario | Recommendation |
|----------|----------------|
| Initial setup | Consider 20-40 hours of consultant time |
| Complex API integrations | Custom Airbyte connector development |
| Advanced ML models | Fractional data scientist (contract) |
| Infrastructure issues | Managed services or DevOps consultant |

---

## 6. Self-Documentation Strategy

### Automated Documentation (Built into Tools)

| Tool | Documentation Feature |
|------|----------------------|
| **Airbyte** | UI shows all connections, schemas, sync history |
| **dbt** | `dbt docs generate` creates full data dictionary and lineage |
| **Dagster** | Asset catalog shows all pipelines and dependencies |
| **Metabase** | Dashboard descriptions and SQL comments |

### Required Manual Documentation

**Create and maintain these documents:**

1. **Architecture Decision Records (ADRs)**
   ```markdown
   # ADR-001: Choice of Airbyte over Meltano
   
   ## Context
   We need a data ingestion tool for our SaaS pipeline.
   
   ## Decision
   We chose Airbyte because [reasons].
   
   ## Consequences
   - Positive: [list]
   - Negative: [list]
   ```

2. **Runbook: Common Operations**
   ```markdown
   # Runbook: Data Pipeline Operations
   
   ## How to add a new data source
   1. Log into Airbyte at https://airbyte.yourcompany.com
   2. Click "Sources" → "New Source"
   3. [Screenshots and steps]
   
   ## How to restart a failed job
   1. Open Dagster at https://dagster.yourcompany.com
   2. Navigate to "Runs" → find failed run
   3. [Steps]
   ```

3. **Emergency Recovery Procedures**
   ```markdown
   # Emergency: Database Won't Start
   
   1. SSH into server: ssh user@pipeline-server
   2. Check Docker logs: docker logs postgres
   3. If disk full: [steps]
   4. If corruption: Restore from backup [steps]
   ```

### Git Repository Structure

```
data-platform/
├── README.md                    # Overview and quick start
├── docs/
│   ├── architecture.md          # System design
│   ├── adrs/                    # Architecture decisions
│   ├── runbooks/                # Operational procedures
│   └── onboarding.md            # New team member guide
├── airbyte/
│   └── connections/             # Exported Airbyte configs (YAML)
├── dbt/
│   ├── models/
│   │   ├── bronze/              # Raw data models
│   │   ├── silver/              # Cleaned data models
│   │   └── gold/                # Aggregated models
│   ├── tests/                   # Data quality tests
│   └── dbt_project.yml
├── dagster/
│   ├── pipelines/               # Orchestration definitions
│   └── dagster.yaml
├── metabase/
│   └── dashboards/              # Exported dashboard definitions
├── docker-compose.yml           # Infrastructure as code
└── scripts/
    ├── backup.sh                # Automated backup script
    └── restore.sh               # Recovery script
```

---

## 7. Security & Compliance

### Data Protection

```yaml
# docker-compose.yml security settings

services:
  postgres:
    environment:
      - POSTGRES_PASSWORD_FILE=/run/secrets/db_password
    secrets:
      - db_password
    networks:
      - internal  # Not exposed to internet
      
  airbyte:
    networks:
      - internal
    # Accessed via reverse proxy only

secrets:
  db_password:
    file: ./secrets/db_password.txt
```

### Access Control

| System | Authentication | Authorization |
|--------|---------------|---------------|
| Airbyte | Built-in auth or SSO | Admin/User roles |
| Dagster | Built-in auth | Viewer/Editor/Admin |
| Metabase | Built-in auth or SSO | Data permissions per table |
| PostgreSQL | Role-based | Schema-level grants |

### Backup Strategy

```bash
#!/bin/bash
# scripts/backup.sh

# Daily PostgreSQL backup
pg_dump -h localhost -U postgres data_warehouse | \
  gzip > /backups/postgres/dw_$(date +%Y%m%d).sql.gz

# Keep 30 days of backups
find /backups/postgres -mtime +30 -delete

# Weekly: Copy to offsite storage
aws s3 sync /backups s3://your-backup-bucket/data-platform/
```

---

## 8. Implementation Roadmap

### Phase 1: Foundation (Weeks 1-2)

**Goal:** Basic infrastructure running with one data source

| Task | Time | Owner |
|------|------|-------|
| Set up VM/server | 2 hours | You |
| Install Docker Compose stack | 4 hours | You |
| Configure first Airbyte source | 2 hours | You |
| Verify data in PostgreSQL | 1 hour | You |
| Set up automated backups | 2 hours | You |
| **Total** | **~11 hours** | |

**Deliverables:**
- [ ] Running Docker Compose environment
- [ ] One SaaS source syncing to Bronze layer
- [ ] Daily automated backups

### Phase 2: Transformation Layer (Weeks 3-4)

**Goal:** dbt transforming Bronze to Silver

| Task | Time | Owner |
|------|------|-------|
| Set up dbt project structure | 2 hours | You |
| Write first Silver models (AI-assisted) | 4 hours | You |
| Add dbt tests | 2 hours | You |
| Generate and review dbt docs | 1 hour | You |
| **Total** | **~9 hours** | |

**Deliverables:**
- [ ] dbt project with Bronze → Silver transformations
- [ ] Data quality tests passing
- [ ] Generated documentation

### Phase 3: Orchestration (Weeks 5-6)

**Goal:** Dagster orchestrating full pipeline

| Task | Time | Owner |
|------|------|-------|
| Install and configure Dagster | 3 hours | You |
| Connect Airbyte and dbt to Dagster | 4 hours | You |
| Set up schedules and alerts | 2 hours | You |
| Test failure scenarios | 2 hours | You |
| **Total** | **~11 hours** | |

**Deliverables:**
- [ ] Dagster orchestrating daily syncs
- [ ] Slack/email alerts on failure
- [ ] Visible data lineage

### Phase 4: Business Intelligence (Weeks 7-8)

**Goal:** Self-serve dashboards for stakeholders

| Task | Time | Owner |
|------|------|-------|
| Install Metabase | 1 hour | You |
| Connect to Silver/Gold tables | 1 hour | You |
| Build 2-3 initial dashboards | 4 hours | You |
| Train stakeholders on self-service | 2 hours | You |
| **Total** | **~8 hours** | |

**Deliverables:**
- [ ] Metabase connected to data warehouse
- [ ] Initial dashboards live
- [ ] Users trained on basic usage

### Phase 5: AI Integration (Weeks 9-10)

**Goal:** Automated insights generation

| Task | Time | Owner |
|------|------|-------|
| Set up Claude API integration | 2 hours | You |
| Build insights generation script | 4 hours | You |
| Schedule weekly insights | 1 hour | You |
| Review and refine prompts | 2 hours | You |
| **Total** | **~9 hours** | |

**Deliverables:**
- [ ] Weekly AI-generated insights report
- [ ] Natural language query capability (optional)

---

## 9. Estimated Costs

### Monthly Operating Costs

| Item | Low Estimate | High Estimate |
|------|-------------|---------------|
| **Infrastructure** | | |
| VM (cloud) | $50 | $150 |
| Backup storage | $10 | $30 |
| **Software** | | |
| All tools (open source) | $0 | $0 |
| **AI/API** | | |
| Claude API (for insights) | $20 | $100 |
| **Total Monthly** | **$80** | **$280** |

### One-Time Setup Costs

| Item | Low Estimate | High Estimate |
|------|-------------|---------------|
| Staff time (internal) | 40 hours | 80 hours |
| External consultant (optional) | $0 | $5,000 |
| **Total Setup** | **40 hours** | **80 hours + $5K** |

---

## 10. Risk Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Key person leaves | Medium | High | Self-documenting tools, runbooks, Git history |
| Data loss | Low | Critical | Daily backups, offsite copies, tested restores |
| API rate limiting | Medium | Medium | Airbyte handles automatically; configure conservative sync windows |
| Tool becomes unmaintained | Low | Medium | All tools are popular with large communities; alternatives exist |
| Security breach | Low | High | Internal network only, secrets management, access controls |

---

## Appendix A: Docker Compose Template

```yaml
# docker-compose.yml
version: '3.8'

services:
  # === DATA STORAGE ===
  postgres:
    image: postgres:15
    environment:
      POSTGRES_USER: warehouse
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: data_warehouse
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    networks:
      - data_network
    restart: unless-stopped

  # === DATA INGESTION ===
  airbyte-server:
    image: airbyte/server:latest
    environment:
      DATABASE_URL: postgres://warehouse:${POSTGRES_PASSWORD}@postgres:5432/airbyte
    depends_on:
      - postgres
    ports:
      - "8001:8001"
    networks:
      - data_network
    restart: unless-stopped

  # Note: Full Airbyte requires additional services (scheduler, worker, etc.)
  # Use their official docker-compose for production:
  # https://github.com/airbytehq/airbyte/blob/master/docker-compose.yaml

  # === TRANSFORMATION ===
  # dbt runs as a CLI tool, typically in Dagster or CI/CD

  # === ORCHESTRATION ===
  dagster-webserver:
    image: dagster/dagster-k8s:latest
    environment:
      DAGSTER_HOME: /opt/dagster/dagster_home
    volumes:
      - ./dagster:/opt/dagster/app
      - ./dbt:/opt/dagster/dbt
    ports:
      - "3000:3000"
    networks:
      - data_network
    restart: unless-stopped

  # === BUSINESS INTELLIGENCE ===
  metabase:
    image: metabase/metabase:latest
    environment:
      MB_DB_TYPE: postgres
      MB_DB_HOST: postgres
      MB_DB_PORT: 5432
      MB_DB_DBNAME: metabase
      MB_DB_USER: warehouse
      MB_DB_PASS: ${POSTGRES_PASSWORD}
    ports:
      - "3001:3000"
    networks:
      - data_network
    depends_on:
      - postgres
    restart: unless-stopped

  # === MONITORING ===
  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml
    ports:
      - "9090:9090"
    networks:
      - data_network
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    environment:
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_PASSWORD}
    volumes:
      - grafana_data:/var/lib/grafana
    ports:
      - "3002:3000"
    networks:
      - data_network
    restart: unless-stopped

volumes:
  postgres_data:
  grafana_data:

networks:
  data_network:
    driver: bridge
```

---

## Appendix B: Quick Reference Commands

```bash
# Start all services
docker compose up -d

# View logs
docker compose logs -f airbyte-server
docker compose logs -f dagster-webserver

# Restart a specific service
docker compose restart metabase

# Run dbt manually
docker compose exec dagster-webserver dbt run --project-dir /opt/dagster/dbt

# Backup database
docker compose exec postgres pg_dump -U warehouse data_warehouse > backup.sql

# Restore database
cat backup.sql | docker compose exec -T postgres psql -U warehouse data_warehouse

# Check disk usage
docker system df

# Clean up unused Docker resources
docker system prune -a
```

---

## Appendix C: Glossary

| Term | Definition |
|------|------------|
| **Bronze Layer** | Raw data exactly as received from source systems |
| **Silver Layer** | Cleaned, typed, deduplicated data |
| **Gold Layer** | Aggregated, business-ready data |
| **ELT** | Extract, Load, Transform (transform after loading) |
| **CDC** | Change Data Capture (track incremental changes) |
| **dbt** | Data Build Tool (SQL-based transformation) |
| **Orchestration** | Scheduling and coordinating pipeline tasks |
| **Data Lineage** | Tracking data from source to destination |
