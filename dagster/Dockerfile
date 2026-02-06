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

# Copy configuration files
COPY dagster.yaml $DAGSTER_HOME/dagster.yaml
COPY workspace.yaml /opt/dagster/workspace.yaml

EXPOSE 3002

# Updated CMD to reference the workspace file
CMD ["dagster-webserver", "-h", "0.0.0.0", "-p", "3002", "-w", "/opt/dagster/workspace.yaml"]
