# Dagster pipeline definitions
# Loads dbt assets from the dbt project and schedules daily runs.

import os
from pathlib import Path

from dagster import Definitions, define_asset_job, ScheduleDefinition, AssetExecutionContext
from dagster_dbt import DbtCliResource, dbt_assets, DbtProject

# ── dbt project configuration ─────────────────────────────
DBT_PROJECT_DIR = Path("/opt/dagster/dbt")
DBT_PROFILES_DIR = Path("/opt/dagster/dbt")

dbt_project = DbtProject(
    project_dir=DBT_PROJECT_DIR,
    profiles_dir=DBT_PROFILES_DIR,
)

# ── dbt assets ─────────────────────────────────────────────
@dbt_assets(manifest=dbt_project.manifest_path)
def all_dbt_assets(context: AssetExecutionContext, dbt: DbtCliResource):
    yield from dbt.cli(["build"], context=context).stream()

# ── Jobs ───────────────────────────────────────────────────
dbt_build_job = define_asset_job(
    name="dbt_build_job",
    selection="*",
)

# ── Schedules ──────────────────────────────────────────────
daily_schedule = ScheduleDefinition(
    job=dbt_build_job,
    cron_schedule="0 6 * * *",  # 6 AM daily
)

# ── Main Definitions ───────────────────────────────────────
defs = Definitions(
    assets=[all_dbt_assets],
    jobs=[dbt_build_job],
    schedules=[daily_schedule],
    resources={
        "dbt": DbtCliResource(
            project_dir=DBT_PROJECT_DIR,
            profiles_dir=DBT_PROFILES_DIR,
        ),
    },
)