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