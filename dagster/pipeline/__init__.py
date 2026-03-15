"""
Hydrosat Dagster Pipeline

Definitions entry point — Dagster discovers all assets, jobs, sensors,
and schedules from this module via the gRPC code server.
"""

import os
from dagster import (
    Definitions,
    load_assets_from_modules,
)
from dagster_aws.s3 import S3Resource

from . import assets
from .jobs import satellite_pipeline_job, ingestion_job, ml_inference_job
from .sensors import hourly_satellite_pipeline, daily_ml_inference, s3_new_data_sensor, run_failure_alert_sensor
from .resources import HydrosatS3Resource, PostgresResource

# ── Load all assets from the assets module ─────────────────────────────────────

all_assets = load_assets_from_modules([assets])

# ── Resource configuration ─────────────────────────────────────────────────────

resources = {
    "s3": HydrosatS3Resource(
        bucket_name=os.getenv("HYDROSAT_S3_BUCKET", "hydrosat-data-prod"),
        region_name=os.getenv("AWS_REGION", "us-east-1"),
    ),
    "postgres": PostgresResource(
        host=os.getenv("DAGSTER_POSTGRES_HOST", "localhost"),
        port=int(os.getenv("DAGSTER_POSTGRES_PORT", "5432")),
        database=os.getenv("DAGSTER_POSTGRES_DB", "dagster"),
        username=os.getenv("DAGSTER_POSTGRES_USER", "dagster"),
        password=os.getenv("DAGSTER_POSTGRES_PASSWORD", ""),
    ),
}

# ── Top-level Definitions object ───────────────────────────────────────────────

defs = Definitions(
    assets=all_assets,
    jobs=[
        satellite_pipeline_job,
        ingestion_job,
        ml_inference_job,
    ],
    schedules=[
        hourly_satellite_pipeline,
        daily_ml_inference,
    ],
    sensors=[
        s3_new_data_sensor,
        run_failure_alert_sensor,
    ],
    resources=resources,
)
