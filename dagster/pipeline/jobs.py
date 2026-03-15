"""
Dagster job definitions.

Jobs compose assets into executable units with explicit configs,
resource bindings, and retry policies.
"""

from dagster import (
    AssetSelection,
    define_asset_job,
    RetryPolicy,
    Backoff,
    Jitter,
    JobDefinition,
)

# ── Full pipeline job ─────────────────────────────────────────────────────────

satellite_pipeline_job: JobDefinition = define_asset_job(
    name="satellite_data_pipeline",
    description=(
        "End-to-end satellite data processing pipeline: "
        "ingestion → validation → feature engineering → ML inference → reporting."
    ),
    selection=AssetSelection.groups(
        "ingestion",
        "validation",
        "feature_engineering",
        "ml_inference",
        "reporting",
    ),
    tags={
        "team": "data-platform",
        "pipeline": "satellite",
        "environment": "prod",
    },
    # Retry policy applied at asset level (@asset decorator in assets.py).
    # RetryPolicy/Backoff/Jitter imported above for use in assets module.
)

# ── Ingestion-only job (for incremental / more frequent runs) ─────────────────

ingestion_job: JobDefinition = define_asset_job(
    name="satellite_ingestion_only",
    description="Runs only the ingestion asset — useful for debugging upstream API issues.",
    selection=AssetSelection.groups("ingestion"),
    tags={
        "team": "data-platform",
        "pipeline": "satellite-ingestion",
    },
)

# ── ML inference job (re-score existing features without re-ingesting) ─────────

ml_inference_job: JobDefinition = define_asset_job(
    name="ml_inference_only",
    description="Re-runs ML inference on already-featurised data (e.g., after model update).",
    selection=AssetSelection.groups("ml_inference", "reporting"),
    tags={
        "team": "data-platform",
        "pipeline": "ml-inference",
    },
)
