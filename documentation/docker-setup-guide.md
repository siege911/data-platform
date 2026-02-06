# Docker Setup Guide: Data Pipeline Stack

This guide walks you through setting up the complete data pipeline infrastructure on your Ubuntu machine.

---

## Prerequisites Checklist

```bash
# Verify Docker is installed and running
docker --version
docker compose version

# Ensure your user is in the docker group (no sudo needed)
groups $USER | grep docker

# If not in docker group, add yourself and re-login:
sudo usermod -aG docker $USER
# Then log out and back in
```

---

## Step 1: Create Project Directory Structure

```bash
# Create the main project directory
mkdir -p ~/data-platform
cd ~/data-platform

# Create subdirectories
mkdir -p {secrets,backups,logs,scripts}
mkdir -p dbt/{models/{bronze,silver,gold},tests,macros,seeds}
mkdir -p dagster/pipelines
mkdir -p metabase
mkdir -p prometheus
mkdir -p grafana/provisioning/{dashboards,datasources}
mkdir -p nginx
mkdir -p docs/{adrs,runbooks}
mkdir -p init-scripts

# Verify structure
tree -L 2 .
```

Expected structure:
```
data-platform/
├── backups/
├── dagster/
│   └── pipelines/
├── dbt/
│   ├── macros/
│   ├── models/
│   ├── seeds/
│   └── tests/
├── docs/
│   ├── adrs/
│   └── runbooks/
├── grafana/
│   └── provisioning/
├── init-scripts/
├── logs/
├── metabase/
├── nginx/
├── prometheus/
├── scripts/
└── secrets/
```

---

## Step 2: Create Environment Variables File

```bash
cd ~/data-platform

# Generate secure passwords
POSTGRES_PW=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32)
GRAFANA_PW=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32)
PGADMIN_PW=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32)

# Create .env file
cat > .env << EOF
# ===========================================
# Data Platform Environment Variables
# Generated: $(date)
# ===========================================

# PostgreSQL (Data Warehouse)
POSTGRES_USER=warehouse
POSTGRES_PASSWORD=${POSTGRES_PW}
POSTGRES_DB=data_warehouse

# Metabase
MB_DB_USER=warehouse
MB_DB_PASS=${POSTGRES_PW}

# Grafana
GRAFANA_ADMIN_PASSWORD=${GRAFANA_PW}

# pgAdmin
PGADMIN_PASSWORD=${PGADMIN_PW}

# Airbyte
AIRBYTE_VERSION=0.64.0

# Network
DOCKER_NETWORK=data_platform_network
EOF

# Secure the file
chmod 600 .env

# Display passwords (save these somewhere secure!)
echo "==========================================="
echo "IMPORTANT: Save these passwords securely!"
echo "==========================================="
echo "PostgreSQL Password: ${POSTGRES_PW}"
echo "Grafana Password: ${GRAFANA_PW}"
echo "pgAdmin Password: ${PGADMIN_PW}"
echo "==========================================="
```

---

## Step 3: Create the Main Docker Compose File

```bash
cat > docker-compose.yml << 'EOF'
version: "3.8"

# ===========================================
# Data Platform Docker Compose
# ===========================================

services:
  # -----------------------------------------
  # PostgreSQL - Data Warehouse
  # -----------------------------------------
  postgres:
    image: postgres:15-alpine
    container_name: data_warehouse
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init-scripts:/docker-entrypoint-initdb.d:ro
    ports:
      - "5432:5432"
    networks:
      - data_network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  # -----------------------------------------
  # pgAdmin - PostgreSQL UI
  # -----------------------------------------
  pgadmin:
    image: dpage/pgadmin4:latest
    container_name: pgadmin
    environment:
      PGADMIN_DEFAULT_EMAIL: admin@example.com
      PGADMIN_DEFAULT_PASSWORD: ${PGADMIN_PASSWORD}
      PGADMIN_CONFIG_SERVER_MODE: "False"
    volumes:
      - pgadmin_data:/var/lib/pgadmin
    ports:
      - "5050:80"
    networks:
      - data_network
    depends_on:
      postgres:
        condition: service_healthy
    restart: unless-stopped

  # -----------------------------------------
  # Metabase - Business Intelligence
  # -----------------------------------------
  metabase:
    image: metabase/metabase:latest
    container_name: metabase
    environment:
      MB_DB_TYPE: postgres
      MB_DB_DBNAME: metabase
      MB_DB_PORT: 5432
      MB_DB_USER: ${MB_DB_USER}
      MB_DB_PASS: ${MB_DB_PASS}
      MB_DB_HOST: postgres
      JAVA_OPTS: "-Xmx2g"
    ports:
      - "3000:3000"
    networks:
      - data_network
    depends_on:
      postgres:
        condition: service_healthy
    restart: unless-stopped

  # -----------------------------------------
  # Dagster - Orchestration
  # -----------------------------------------
  dagster:
    build:
      context: ./dagster
      dockerfile: Dockerfile
    container_name: dagster
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      AIRBYTE_HOST: host.docker.internal
      AIRBYTE_PORT: 8000
    volumes:
      - ./dagster:/opt/dagster/app
      - ./dbt:/opt/dagster/dbt
      - ./dagster/workspace.yaml:/opt/dagster/workspace.yaml:ro
    ports:
      - "3002:3002"
    networks:
      - data_network
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on:
      postgres:
        condition: service_healthy
    restart: unless-stopped

  # -----------------------------------------
  # Prometheus - Metrics Collection
  # -----------------------------------------
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
    ports:
      - "9090:9090"
    networks:
      - data_network
    restart: unless-stopped

  # -----------------------------------------
  # Grafana - Monitoring Dashboards
  # -----------------------------------------
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}
      GF_USERS_ALLOW_SIGN_UP: "false"
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    ports:
      - "3001:3000"
    networks:
      - data_network
    depends_on:
      - prometheus
    restart: unless-stopped

  # -----------------------------------------
  # PostgreSQL Exporter - Database Metrics
  # -----------------------------------------
  postgres-exporter:
    image: prometheuscommunity/postgres-exporter:latest
    container_name: postgres_exporter
    environment:
      DATA_SOURCE_NAME: "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}?sslmode=disable"
    ports:
      - "9187:9187"
    networks:
      - data_network
    depends_on:
      postgres:
        condition: service_healthy
    restart: unless-stopped

# -----------------------------------------
# Volumes
# -----------------------------------------
volumes:
  postgres_data:
    name: data_platform_postgres
  prometheus_data:
    name: data_platform_prometheus
  grafana_data:
    name: data_platform_grafana
  pgadmin_data:
    name: data_platform_pgadmin

# -----------------------------------------
# Networks
# -----------------------------------------
networks:
  data_network:
    name: data_platform_network
    driver: bridge
EOF
```

---

## Step 4: Create Database Initialization Script

```bash
cat > init-scripts/01-init-schemas.sql << 'EOF'
-- ===========================================
-- Initialize Data Warehouse Schemas
-- ===========================================

-- Create schemas for Medallion architecture
CREATE SCHEMA IF NOT EXISTS bronze;
CREATE SCHEMA IF NOT EXISTS silver;
CREATE SCHEMA IF NOT EXISTS gold;

-- Create schema for Airbyte raw data
CREATE SCHEMA IF NOT EXISTS airbyte_internal;

-- Create schema for dbt artifacts
CREATE SCHEMA IF NOT EXISTS dbt_artifacts;

-- Create separate database for Metabase metadata
CREATE DATABASE metabase;

-- Create separate database for Dagster metadata
CREATE DATABASE dagster;

-- Grant permissions
GRANT ALL PRIVILEGES ON SCHEMA bronze TO warehouse;
GRANT ALL PRIVILEGES ON SCHEMA silver TO warehouse;
GRANT ALL PRIVILEGES ON SCHEMA gold TO warehouse;
GRANT ALL PRIVILEGES ON SCHEMA airbyte_internal TO warehouse;
GRANT ALL PRIVILEGES ON SCHEMA dbt_artifacts TO warehouse;

-- Create read-only role for BI tools
CREATE ROLE bi_readonly;
GRANT USAGE ON SCHEMA silver TO bi_readonly;
GRANT USAGE ON SCHEMA gold TO bi_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA silver TO bi_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA gold TO bi_readonly;

-- Set default privileges for future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA silver 
    GRANT SELECT ON TABLES TO bi_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA gold 
    GRANT SELECT ON TABLES TO bi_readonly;

-- Log completion
DO $$ 
BEGIN 
    RAISE NOTICE 'Database initialization complete!';
END $$;
EOF
```

---

## Step 5: Create Prometheus Configuration

```bash
cat > prometheus/prometheus.yml << 'EOF'
# Prometheus Configuration
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  # Prometheus self-monitoring
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # PostgreSQL metrics
  - job_name: 'postgres'
    static_configs:
      - targets: ['postgres-exporter:9187']
EOF
```

---

## Step 6: Create Grafana Data Source Configuration

```bash
cat > grafana/provisioning/datasources/datasources.yml << 'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false

  - name: PostgreSQL
    type: postgres
    url: postgres:5432
    database: data_warehouse
    user: warehouse
    secureJsonData:
      password: ${POSTGRES_PASSWORD}
    jsonData:
      sslmode: disable
      maxOpenConns: 10
      maxIdleConns: 5
    editable: false
EOF
```

---

## Step 7: Create Dagster Configuration Files

### Create Dockerfile

```bash
cat > dagster/Dockerfile << 'EOF'
FROM python:3.11-slim

WORKDIR /opt/dagster

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Python packages
RUN pip install --no-cache-dir \
    dagster \
    dagster-webserver \
    dagster-postgres \
    dagster-dbt \
    dagster-airbyte \
    dbt-postgres \
    psycopg2-binary

# Create dagster home and storage directories
ENV DAGSTER_HOME=/opt/dagster/dagster_home
RUN mkdir -p $DAGSTER_HOME/storage $DAGSTER_HOME/logs

# Copy configuration
COPY dagster.yaml $DAGSTER_HOME/dagster.yaml

EXPOSE 3002

# Reference the workspace file (mounted as volume)
CMD ["dagster-webserver", "-h", "0.0.0.0", "-p", "3002", "-w", "/opt/dagster/workspace.yaml"]
EOF
```

### Create dagster.yaml

```bash
cat > dagster/dagster.yaml << 'EOF'
# Dagster instance configuration
# Using local SQLite storage for simplicity

run_storage:
  module: dagster.core.storage.runs
  class: SqliteRunStorage
  config:
    base_dir: /opt/dagster/dagster_home/storage

event_log_storage:
  module: dagster.core.storage.event_log
  class: SqliteEventLogStorage
  config:
    base_dir: /opt/dagster/dagster_home/storage

schedule_storage:
  module: dagster.core.storage.schedules
  class: SqliteScheduleStorage
  config:
    base_dir: /opt/dagster/dagster_home/storage

compute_logs:
  module: dagster.core.storage.local_compute_log_manager
  class: LocalComputeLogManager
  config:
    base_dir: /opt/dagster/dagster_home/logs
EOF
```

### Create workspace.yaml (with absolute path)

```bash
cat > dagster/workspace.yaml << 'EOF'
# Dagster workspace configuration
# Using absolute path to avoid path resolution issues
load_from:
  - python_file: /opt/dagster/app/pipelines/definitions.py
EOF
```

### Create pipeline definitions

```bash
cat > dagster/pipelines/definitions.py << 'EOF'
# Dagster pipeline definitions
# This is the entry point for all your data pipelines

from dagster import Definitions, asset, define_asset_job, ScheduleDefinition
import os

# Example asset - replace with real assets later
@asset
def example_asset():
    """A simple example asset to verify Dagster is working."""
    return "Hello from Dagster!"

@asset
def another_example_asset(example_asset):
    """An asset that depends on example_asset."""
    return f"Received: {example_asset}"

# Define a job that materializes all assets
all_assets_job = define_asset_job(
    name="all_assets_job",
    selection="*"
)

# Example schedule (commented out until you have real assets)
# daily_schedule = ScheduleDefinition(
#     job=all_assets_job,
#     cron_schedule="0 6 * * *",  # 6 AM daily
# )

# Main Definitions object - Dagster's entry point
defs = Definitions(
    assets=[example_asset, another_example_asset],
    jobs=[all_assets_job],
    # schedules=[daily_schedule],
)
EOF
```

---

## Step 8: Initialize dbt Project

```bash
# Create dbt project file
cat > dbt/dbt_project.yml << 'EOF'
name: 'data_warehouse'
version: '1.0.0'
config-version: 2

profile: 'data_warehouse'

model-paths: ["models"]
analysis-paths: ["analyses"]
test-paths: ["tests"]
seed-paths: ["seeds"]
macro-paths: ["macros"]
snapshot-paths: ["snapshots"]

clean-targets:
  - "target"
  - "dbt_packages"

models:
  data_warehouse:
    bronze:
      +schema: bronze
      +materialized: view
    silver:
      +schema: silver
      +materialized: incremental
    gold:
      +schema: gold
      +materialized: table
EOF

# Create dbt profiles
cat > dbt/profiles.yml << 'EOF'
data_warehouse:
  target: dev
  outputs:
    dev:
      type: postgres
      host: postgres
      port: 5432
      user: "{{ env_var('POSTGRES_USER') }}"
      password: "{{ env_var('POSTGRES_PASSWORD') }}"
      dbname: data_warehouse
      schema: dbt_artifacts
      threads: 4
EOF

# Create example Bronze model
cat > dbt/models/bronze/bronze_example.sql << 'EOF'
-- Example bronze model
-- Bronze layer: raw data views, no transformations

{{ config(
    materialized='view',
    schema='bronze'
) }}

-- This is a placeholder
-- Replace with actual source tables from Airbyte
SELECT 
    1 as id,
    'example' as name,
    CURRENT_TIMESTAMP as loaded_at
EOF

# Create example Silver model
cat > dbt/models/silver/silver_example.sql << 'EOF'
-- Example silver model
-- Silver layer: cleaned, typed, deduplicated data

{{ config(
    materialized='incremental',
    schema='silver',
    unique_key='id'
) }}

SELECT 
    id,
    TRIM(name) as name,
    loaded_at,
    CURRENT_TIMESTAMP as transformed_at
FROM {{ ref('bronze_example') }}

{% if is_incremental() %}
WHERE loaded_at > (SELECT MAX(loaded_at) FROM {{ this }})
{% endif %}
EOF

# Create schema documentation
cat > dbt/models/schema.yml << 'EOF'
version: 2

models:
  - name: bronze_example
    description: "Example bronze layer model - raw data placeholder"
    columns:
      - name: id
        description: "Primary identifier"
        tests:
          - unique
          - not_null
      - name: name
        description: "Record name"
      - name: loaded_at
        description: "Timestamp when data was loaded"

  - name: silver_example
    description: "Example silver layer model - cleaned data"
    columns:
      - name: id
        description: "Primary identifier"
        tests:
          - unique
          - not_null
      - name: name
        description: "Cleaned record name"
      - name: loaded_at
        description: "Original load timestamp"
      - name: transformed_at
        description: "Transformation timestamp"
EOF
```

---

## Step 9: Build and Start All Services

```bash
cd ~/data-platform

# Pull all images first (takes a few minutes)
docker compose pull

# Build custom images (Dagster)
docker compose build

# Start services in detached mode
docker compose up -d

# Watch the logs to ensure everything starts correctly
docker compose logs -f

# Press Ctrl+C to exit logs after services are healthy
```

---

## Step 10: Verify All Services

```bash
# Check all containers are running
docker compose ps

# Expected output:
# NAME                STATUS              PORTS
# dagster             Up                  0.0.0.0:3002->3002/tcp
# data_warehouse      Up (healthy)        0.0.0.0:5432->5432/tcp
# grafana             Up                  0.0.0.0:3001->3000/tcp
# metabase            Up                  0.0.0.0:3000->3000/tcp
# pgadmin             Up                  0.0.0.0:5050->80/tcp
# postgres_exporter   Up                  0.0.0.0:9187->9187/tcp
# prometheus          Up                  0.0.0.0:9090->9090/tcp

# Test PostgreSQL connection and verify schemas
docker compose exec postgres psql -U warehouse -d data_warehouse -c "\dn"

# Expected output: list of schemas (bronze, silver, gold, etc.)
```

---

## Step 11: Install Airbyte (Separate Compose File)

Airbyte has its own complex Docker setup. We'll run it alongside our stack.

```bash
# Create Airbyte directory
mkdir -p ~/data-platform/airbyte
cd ~/data-platform/airbyte

# Download Airbyte's official docker-compose
curl -L https://raw.githubusercontent.com/airbytehq/airbyte/master/run-ab-platform.sh -o run-ab-platform.sh
chmod +x run-ab-platform.sh

# Run Airbyte setup (this downloads their compose file)
./run-ab-platform.sh -d

# Airbyte will be available at http://localhost:8000
# Default credentials: 
#   Email: any email
#   Password: password (change this after first login!)
```

---

## Step 12: Configure Services

### pgAdmin Setup

1. Open **http://localhost:5050**
2. Login with:
   - Email: `admin@example.com`
   - Password: (PGADMIN_PASSWORD from your .env file)
3. Add your PostgreSQL server:
   - Right-click "Servers" → "Register" → "Server"
   - **General tab:**
     - Name: `Data Warehouse`
   - **Connection tab:**
     - Host: `postgres`
     - Port: `5432`
     - Database: `data_warehouse`
     - Username: `warehouse`
     - Password: (POSTGRES_PASSWORD from .env)
     - Check "Save password"
   - Click "Save"

### Metabase Setup

1. Open **http://localhost:3000**
2. Create admin account
3. Add database connection:
   - Type: PostgreSQL
   - Host: `postgres`
   - Port: `5432`
   - Database: `data_warehouse`
   - Username: `warehouse`
   - Password: (POSTGRES_PASSWORD from .env)

### Airbyte Setup

1. Open **http://localhost:8000**
2. Complete onboarding
3. Add your first source (SaaS app)
4. Add destination:
   - Type: Postgres
   - Host: `host.docker.internal` (or your machine's IP)
   - Port: `5432`
   - Database: `data_warehouse`
   - Schema: `bronze`
   - User: `warehouse`
   - Password: (POSTGRES_PASSWORD from .env)
5. Create connection and run first sync

### Grafana Setup

1. Open **http://localhost:3001**
2. Login: admin / (GRAFANA_ADMIN_PASSWORD from .env)
3. Prometheus datasource is pre-configured
4. Import dashboard ID `9628` for PostgreSQL monitoring

### Dagster Setup

1. Open **http://localhost:3002**
2. You should see the example assets in the UI
3. Click "Materialize all" to test the pipeline

---

## Step 13: Create Backup Script

```bash
cat > scripts/backup.sh << 'EOF'
#!/bin/bash
# ===========================================
# Data Platform Backup Script
# Run daily via cron
# ===========================================

set -e

BACKUP_DIR="$HOME/data-platform/backups"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=30

echo "[$(date)] Starting backup..."

cd ~/data-platform

# Backup PostgreSQL
echo "[$(date)] Backing up PostgreSQL..."
docker compose exec -T postgres pg_dumpall -U warehouse | \
    gzip > "${BACKUP_DIR}/postgres_${DATE}.sql.gz"

# Backup Airbyte configurations
echo "[$(date)] Backing up Airbyte configs..."
if [ -d ~/data-platform/airbyte ]; then
    tar -czf "${BACKUP_DIR}/airbyte_config_${DATE}.tar.gz" \
        -C ~/data-platform/airbyte .
fi

# Backup dbt project
echo "[$(date)] Backing up dbt project..."
tar -czf "${BACKUP_DIR}/dbt_${DATE}.tar.gz" \
    -C ~/data-platform dbt

# Clean old backups
echo "[$(date)] Cleaning backups older than ${RETENTION_DAYS} days..."
find "${BACKUP_DIR}" -type f -mtime +${RETENTION_DAYS} -delete

echo "[$(date)] Backup complete!"
ls -lh "${BACKUP_DIR}"
EOF

chmod +x scripts/backup.sh

# Create cron job for daily backups at 2 AM
(crontab -l 2>/dev/null; echo "0 2 * * * $HOME/data-platform/scripts/backup.sh >> $HOME/data-platform/logs/backup.log 2>&1") | crontab -
```

---

## Step 14: Create Health Check Script

```bash
cat > scripts/health_check.sh << 'EOF'
#!/bin/bash
# ===========================================
# Data Platform Health Check
# ===========================================

echo "========================================"
echo "Data Platform Health Check"
echo "$(date)"
echo "========================================"

cd ~/data-platform

# Check Docker containers
echo -e "\n📦 Container Status:"
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

# Check PostgreSQL
echo -e "\n🐘 PostgreSQL:"
if docker compose exec -T postgres pg_isready -U warehouse > /dev/null 2>&1; then
    echo "  ✅ PostgreSQL is healthy"
    
    # Check schema counts
    echo "  📊 Table counts by schema:"
    docker compose exec -T postgres psql -U warehouse -d data_warehouse -c "
        SELECT schemaname, COUNT(*) as tables 
        FROM pg_tables 
        WHERE schemaname IN ('bronze', 'silver', 'gold')
        GROUP BY schemaname
        ORDER BY schemaname;
    " 2>/dev/null || echo "  (No tables yet)"
else
    echo "  ❌ PostgreSQL is not responding"
fi

# Check Metabase
echo -e "\n📊 Metabase:"
if curl -s http://localhost:3000/api/health | grep -q "ok"; then
    echo "  ✅ Metabase is healthy"
else
    echo "  ⚠️  Metabase may still be starting..."
fi

# Check pgAdmin
echo -e "\n🔧 pgAdmin:"
if curl -s -o /dev/null -w "%{http_code}" http://localhost:5050 | grep -q "200\|302"; then
    echo "  ✅ pgAdmin is healthy"
else
    echo "  ⚠️  pgAdmin may still be starting..."
fi

# Check Airbyte
echo -e "\n🔄 Airbyte:"
if curl -s http://localhost:8000/api/v1/health | grep -q "available"; then
    echo "  ✅ Airbyte is healthy"
else
    echo "  ⚠️  Airbyte not responding (may need separate start)"
fi

# Check Dagster
echo -e "\n⚙️  Dagster:"
if curl -s http://localhost:3002/server_info > /dev/null 2>&1; then
    echo "  ✅ Dagster is healthy"
else
    echo "  ⚠️  Dagster may still be starting..."
fi

# Check Grafana
echo -e "\n📈 Grafana:"
if curl -s http://localhost:3001/api/health | grep -q "ok"; then
    echo "  ✅ Grafana is healthy"
else
    echo "  ⚠️  Grafana may still be starting..."
fi

# Check disk space
echo -e "\n💾 Disk Usage:"
df -h / | tail -1 | awk '{print "  Used: "$3" / "$2" ("$5")"}'

# Check Docker disk usage
echo -e "\n🐳 Docker Disk Usage:"
docker system df --format "table {{.Type}}\t{{.Size}}\t{{.Reclaimable}}"

echo -e "\n========================================"
echo "Health check complete!"
echo "========================================"
EOF

chmod +x scripts/health_check.sh
```

---

## Service Access URLs

| Service | URL | Default Credentials |
|---------|-----|---------------------|
| **Metabase** | http://localhost:3000 | Set on first login |
| **Grafana** | http://localhost:3001 | admin / (from .env) |
| **Dagster** | http://localhost:3002 | No auth by default |
| **pgAdmin** | http://localhost:5050 | admin@example.com / (from .env) |
| **Airbyte** | http://localhost:8000 | Email: any / Pass: password |
| **Prometheus** | http://localhost:9090 | No auth |
| **PostgreSQL** | localhost:5432 | warehouse / (from .env) |

---

## Quick Reference Commands

```bash
# Navigate to project
cd ~/data-platform

# Start all services
docker compose up -d

# Stop all services
docker compose down

# View logs (all services)
docker compose logs -f

# View logs (specific service)
docker compose logs -f dagster

# Restart a service
docker compose restart metabase

# Rebuild a service (after Dockerfile changes)
docker compose build dagster --no-cache
docker compose up -d dagster

# Run health check
./scripts/health_check.sh

# Run backup
./scripts/backup.sh

# Access PostgreSQL CLI
docker compose exec postgres psql -U warehouse -d data_warehouse

# Run dbt commands
docker compose exec dagster dbt run --project-dir /opt/dagster/dbt
docker compose exec dagster dbt test --project-dir /opt/dagster/dbt
docker compose exec dagster dbt docs generate --project-dir /opt/dagster/dbt

# Check resource usage
docker stats

# Start Airbyte (separate from main stack)
cd ~/data-platform/airbyte && ./run-ab-platform.sh -d

# Stop Airbyte
cd ~/data-platform/airbyte && docker compose down
```

---

## Troubleshooting

### Container won't start
```bash
# Check logs for the specific container
docker compose logs postgres

# Check if port is already in use
sudo lsof -i :5432
```

### Out of disk space
```bash
# Clean up Docker resources
docker system prune -a --volumes

# Check what's using space
docker system df -v
```

### PostgreSQL connection refused
```bash
# Verify PostgreSQL is healthy
docker compose exec postgres pg_isready -U warehouse

# Check if initialization completed
docker compose logs postgres | grep "database system is ready"
```

### Dagster can't find definitions.py
```bash
# Verify the file exists in the container
docker compose exec dagster ls -la /opt/dagster/app/pipelines/

# Check workspace.yaml has correct absolute path
docker compose exec dagster cat /opt/dagster/workspace.yaml

# Should show: python_file: /opt/dagster/app/pipelines/definitions.py
```

### Airbyte sync fails
```bash
# Check Airbyte logs
cd ~/data-platform/airbyte
docker compose logs -f worker

# Verify destination connectivity
docker compose exec airbyte-worker nc -zv host.docker.internal 5432
```

### pgAdmin can't connect to PostgreSQL
```bash
# Make sure to use 'postgres' as the hostname (Docker network name)
# NOT 'localhost' or '127.0.0.1'

# Verify PostgreSQL is accepting connections
docker compose exec postgres psql -U warehouse -d data_warehouse -c "SELECT 1"
```

### Re-run database initialization
```bash
# If schemas weren't created, run manually:
docker compose exec -T postgres psql -U warehouse -d data_warehouse < init-scripts/01-init-schemas.sql

# Or reset completely (WARNING: deletes all data):
docker compose down
docker volume rm data_platform_postgres
docker compose up -d
```

---

## File Structure Reference

After completing setup, your directory should look like this:

```
~/data-platform/
├── .env                          # Environment variables (passwords)
├── docker-compose.yml            # Main Docker Compose file
├── airbyte/                      # Airbyte installation
│   └── run-ab-platform.sh
├── backups/                      # Database backups
├── dagster/
│   ├── Dockerfile
│   ├── dagster.yaml
│   ├── workspace.yaml
│   └── pipelines/
│       └── definitions.py
├── dbt/
│   ├── dbt_project.yml
│   ├── profiles.yml
│   └── models/
│       ├── bronze/
│       │   └── bronze_example.sql
│       ├── silver/
│       │   └── silver_example.sql
│       ├── gold/
│       └── schema.yml
├── docs/
│   ├── adrs/
│   └── runbooks/
├── grafana/
│   └── provisioning/
│       └── datasources/
│           └── datasources.yml
├── init-scripts/
│   └── 01-init-schemas.sql
├── logs/
├── prometheus/
│   └── prometheus.yml
└── scripts/
    ├── backup.sh
    └── health_check.sh
```
