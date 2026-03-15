"""
Hydrosat data pipeline assets.

Demonstrates a realistic satellite / geospatial ML pipeline:
  raw_satellite_data → validated_data → feature_engineered_data → ml_predictions → report

Each asset is independently materializable, observable, and emits Prometheus
metrics for end-to-end pipeline observability.
"""

import os
import time
import random
import logging
from datetime import datetime, timezone

import numpy as np
import pandas as pd

from dagster import (
    AssetExecutionContext,
    AssetMaterialization,
    MetadataValue,
    Output,
    RetryPolicy,
    Backoff,
    Jitter,
    asset,
    AssetCheckResult,
    AssetCheckSpec,
    asset_check,
)

from .resources import (
    HydrosatS3Resource,
    RECORDS_PROCESSED,
    PROCESSING_DURATION,
    DATA_QUALITY_SCORE,
)

logger = logging.getLogger(__name__)

# ── Asset group: ingestion ────────────────────────────────────────────────────

@asset(
    group_name="ingestion",
    description="Simulates ingestion of raw satellite imagery metadata from an upstream API.",
    compute_kind="python",
    metadata={
        "owner": "data-platform@hydrosat.com",
        "sla_minutes": 30,
    },
    retry_policy=RetryPolicy(
        max_retries=2,
        delay=30,
        backoff=Backoff.EXPONENTIAL,
        jitter=Jitter.PLUS_MINUS,
    ),
)
def raw_satellite_data(context: AssetExecutionContext) -> pd.DataFrame:
    """
    In production this would call the Hydrosat satellite data API or read from
    an S3 landing zone. Here we generate realistic synthetic data to demonstrate
    the pipeline structure.
    """
    start = time.monotonic()
    job_name = context.job_name or "manual"

    context.log.info("Ingesting raw satellite data...")

    # Allow forced failure via env var for alerting pipeline testing
    # Usage: kubectl set env deployment/dagster-dagster-user-deployments FORCE_FAILURE=true -n dagster
    if os.getenv("FORCE_FAILURE", "false").lower() == "true":
        RECORDS_PROCESSED.labels(
            job_name=job_name,
            asset_name="raw_satellite_data",
            status="failed",
        ).inc()
        raise RuntimeError(
            "Forced failure triggered by FORCE_FAILURE=true env var — "
            "testing alerting pipeline. Unset FORCE_FAILURE to restore normal operation."
        )

    # Simulate potential transient failure (configurable rate) to test alerting
    failure_rate = float(os.getenv("FAILURE_RATE", "0.10"))
    if random.random() < failure_rate:
        RECORDS_PROCESSED.labels(
            job_name=job_name,
            asset_name="raw_satellite_data",
            status="failed",
        ).inc()
        raise RuntimeError(
            "Upstream satellite API returned 503 — simulated transient failure. "
            "Check runbook: https://wiki.hydrosat.com/runbooks/satellite-api-unavailable"
        )

    n_records = 1000
    df = pd.DataFrame(
        {
            "scene_id": [f"SCENE_{i:06d}" for i in range(n_records)],
            "acquisition_date": pd.date_range(
                start="2024-01-01", periods=n_records, freq="1h"
            ),
            "latitude": np.random.uniform(-90, 90, n_records),
            "longitude": np.random.uniform(-180, 180, n_records),
            "cloud_cover_pct": np.random.uniform(0, 100, n_records),
            "ndvi": np.random.uniform(-1, 1, n_records),
            "surface_temp_kelvin": np.random.normal(288, 15, n_records),
            "soil_moisture": np.random.uniform(0, 1, n_records),
            "ingested_at": datetime.now(timezone.utc).isoformat(),
        }
    )

    elapsed = time.monotonic() - start
    PROCESSING_DURATION.labels(
        job_name=job_name, asset_name="raw_satellite_data"
    ).observe(elapsed)
    RECORDS_PROCESSED.labels(
        job_name=job_name, asset_name="raw_satellite_data", status="success"
    ).inc(n_records)

    context.add_output_metadata(
        {
            "num_records": MetadataValue.int(len(df)),
            "date_range_start": MetadataValue.text(str(df["acquisition_date"].min())),
            "date_range_end": MetadataValue.text(str(df["acquisition_date"].max())),
            "processing_seconds": MetadataValue.float(elapsed),
            "preview": MetadataValue.md(df.head(5).to_markdown()),
        }
    )

    context.log.info(f"Ingested {len(df)} records in {elapsed:.2f}s")
    return df


# ── Asset group: validation ───────────────────────────────────────────────────

@asset(
    group_name="validation",
    description="Validates raw data quality: range checks, nulls, duplicates.",
    compute_kind="python",
    deps=[raw_satellite_data],
)
def validated_data(
    context: AssetExecutionContext,
    raw_satellite_data: pd.DataFrame,
) -> pd.DataFrame:
    """
    Applies data quality rules. Logs quality metrics to Prometheus so Grafana
    dashboards can show the health of each pipeline run over time.
    """
    start = time.monotonic()
    job_name = context.job_name or "manual"
    initial_count = len(raw_satellite_data)

    # ── Quality checks ────────────────────────────────────────────────────────

    # Drop rows with null values in critical columns
    critical_cols = ["scene_id", "latitude", "longitude", "ndvi"]
    df = raw_satellite_data.dropna(subset=critical_cols)
    null_dropped = initial_count - len(df)

    # Drop rows with out-of-range cloud cover
    df = df[(df["cloud_cover_pct"] >= 0) & (df["cloud_cover_pct"] <= 100)]

    # Filter high cloud cover scenes (>80 % unusable for vegetation analysis)
    df = df[df["cloud_cover_pct"] <= 80]

    # Drop duplicate scene IDs
    duplicates = df.duplicated(subset=["scene_id"]).sum()
    df = df.drop_duplicates(subset=["scene_id"])

    # NDVI must be in [-1, 1]
    df = df[(df["ndvi"] >= -1) & (df["ndvi"] <= 1)]

    # Compute data quality score
    passed = len(df)
    quality_score = passed / max(initial_count, 1)
    DATA_QUALITY_SCORE.labels(asset_name="validated_data").set(quality_score)

    elapsed = time.monotonic() - start
    PROCESSING_DURATION.labels(
        job_name=job_name, asset_name="validated_data"
    ).observe(elapsed)
    RECORDS_PROCESSED.labels(
        job_name=job_name, asset_name="validated_data", status="success"
    ).inc(passed)

    context.add_output_metadata(
        {
            "input_records": MetadataValue.int(initial_count),
            "output_records": MetadataValue.int(passed),
            "null_dropped": MetadataValue.int(null_dropped),
            "duplicates_dropped": MetadataValue.int(int(duplicates)),
            "quality_score": MetadataValue.float(round(quality_score, 4)),
            "processing_seconds": MetadataValue.float(elapsed),
        }
    )

    # Warn if quality drops below 70 %
    if quality_score < 0.70:
        context.log.warning(
            f"Data quality score {quality_score:.2%} is below threshold 70 %. "
            f"Check upstream ingestion pipeline."
        )

    context.log.info(
        f"Validation: {passed}/{initial_count} records passed "
        f"(quality={quality_score:.2%}) in {elapsed:.2f}s"
    )
    return df


# ── Asset group: feature_engineering ─────────────────────────────────────────

@asset(
    group_name="feature_engineering",
    description="Engineers features for ML model: temporal, spatial, derived vegetation indices.",
    compute_kind="python",
    deps=[validated_data],
)
def feature_engineered_data(
    context: AssetExecutionContext,
    validated_data: pd.DataFrame,
) -> pd.DataFrame:
    """
    Generates ML features from the validated satellite dataset:
    - Temporal features (month, day-of-year, season)
    - Derived spectral indices
    - Spatial grid cell assignments
    """
    start = time.monotonic()
    job_name = context.job_name or "manual"

    df = validated_data.copy()

    # Temporal features
    df["month"] = df["acquisition_date"].dt.month
    df["day_of_year"] = df["acquisition_date"].dt.dayofyear
    df["hour_of_day"] = df["acquisition_date"].dt.hour
    df["season"] = df["month"].map(
        {12: "winter", 1: "winter", 2: "winter",
         3: "spring", 4: "spring", 5: "spring",
         6: "summer", 7: "summer", 8: "summer",
         9: "autumn", 10: "autumn", 11: "autumn"}
    )

    # Derived vegetation indices
    # EVI-proxy (simplified — real EVI needs band reflectances)
    df["vegetation_health_index"] = (
        (df["ndvi"] + 1) / 2 * (1 - df["cloud_cover_pct"] / 100)
    )
    df["thermal_anomaly"] = (
        df["surface_temp_kelvin"] - df["surface_temp_kelvin"].mean()
    ) / df["surface_temp_kelvin"].std()

    # Soil moisture stress index
    df["moisture_stress"] = 1 - df["soil_moisture"]

    # Spatial grid (0.5° × 0.5° cells)
    df["grid_lat"] = (df["latitude"] / 0.5).astype(int) * 0.5
    df["grid_lon"] = (df["longitude"] / 0.5).astype(int) * 0.5
    df["grid_cell"] = df["grid_lat"].astype(str) + "_" + df["grid_lon"].astype(str)

    elapsed = time.monotonic() - start
    PROCESSING_DURATION.labels(
        job_name=job_name, asset_name="feature_engineered_data"
    ).observe(elapsed)
    RECORDS_PROCESSED.labels(
        job_name=job_name, asset_name="feature_engineered_data", status="success"
    ).inc(len(df))

    context.add_output_metadata(
        {
            "num_features": MetadataValue.int(len(df.columns)),
            "feature_names": MetadataValue.text(", ".join(df.columns.tolist())),
            "num_records": MetadataValue.int(len(df)),
            "processing_seconds": MetadataValue.float(elapsed),
        }
    )

    context.log.info(f"Feature engineering: {len(df.columns)} features for {len(df)} records in {elapsed:.2f}s")
    return df


# ── Asset group: ml_inference ─────────────────────────────────────────────────

@asset(
    group_name="ml_inference",
    description="Runs ML model inference to predict crop health / yield risk per grid cell.",
    compute_kind="python",
    deps=[feature_engineered_data],
)
def ml_predictions(
    context: AssetExecutionContext,
    feature_engineered_data: pd.DataFrame,
) -> pd.DataFrame:
    """
    In production this would load a trained model from MLflow or SageMaker.
    Here we use a deterministic rule-based scoring proxy to demonstrate the
    pipeline structure without requiring a trained model artefact.
    """
    start = time.monotonic()
    job_name = context.job_name or "manual"

    df = feature_engineered_data.copy()

    # Rule-based risk score proxy (0 = healthy, 1 = severe stress)
    df["crop_health_score"] = (
        0.4 * df["vegetation_health_index"]
        + 0.3 * (1 - df["moisture_stress"])
        + 0.2 * np.clip(-df["thermal_anomaly"], 0, 1)
        + 0.1 * (1 - df["cloud_cover_pct"] / 100)
    ).clip(0, 1)

    df["risk_category"] = pd.cut(
        1 - df["crop_health_score"],
        bins=[0, 0.25, 0.50, 0.75, 1.0],
        labels=["low", "moderate", "high", "severe"],
    )

    df["prediction_timestamp"] = datetime.now(timezone.utc).isoformat()
    df["model_version"] = "v1.0.0-deterministic"

    elapsed = time.monotonic() - start
    PROCESSING_DURATION.labels(
        job_name=job_name, asset_name="ml_predictions"
    ).observe(elapsed)
    RECORDS_PROCESSED.labels(
        job_name=job_name, asset_name="ml_predictions", status="success"
    ).inc(len(df))

    context.add_output_metadata(
        {
            "num_predictions": MetadataValue.int(len(df)),
            "mean_health_score": MetadataValue.float(float(df["crop_health_score"].mean())),
            "risk_distribution": MetadataValue.md(
                df["risk_category"].value_counts().to_markdown()
            ),
            "processing_seconds": MetadataValue.float(elapsed),
        }
    )

    context.log.info(
        f"Inference complete: {len(df)} predictions, "
        f"mean health score = {df['crop_health_score'].mean():.3f} in {elapsed:.2f}s"
    )
    return df


# ── Asset group: reporting ────────────────────────────────────────────────────

@asset(
    group_name="reporting",
    description="Aggregates predictions into a grid-cell level summary report.",
    compute_kind="python",
    deps=[ml_predictions],
)
def pipeline_report(
    context: AssetExecutionContext,
    ml_predictions: pd.DataFrame,
) -> pd.DataFrame:
    """
    Aggregates per-scene predictions to grid-cell level. In production this
    would be written to S3 (Parquet), a PostGIS table, or sent to a downstream
    API for dashboard consumption.
    """
    start = time.monotonic()
    job_name = context.job_name or "manual"

    report = (
        ml_predictions.groupby("grid_cell")
        .agg(
            scene_count=("scene_id", "count"),
            mean_health_score=("crop_health_score", "mean"),
            min_health_score=("crop_health_score", "min"),
            mean_ndvi=("ndvi", "mean"),
            mean_soil_moisture=("soil_moisture", "mean"),
            high_risk_scenes=("risk_category", lambda x: (x == "high").sum()),
            severe_risk_scenes=("risk_category", lambda x: (x == "severe").sum()),
        )
        .reset_index()
        .sort_values("mean_health_score", ascending=True)
    )

    report["report_generated_at"] = datetime.now(timezone.utc).isoformat()
    report["pipeline_run_id"] = context.run_id

    elapsed = time.monotonic() - start
    PROCESSING_DURATION.labels(
        job_name=job_name, asset_name="pipeline_report"
    ).observe(elapsed)
    DATA_QUALITY_SCORE.labels(asset_name="pipeline_report").set(
        float(report["mean_health_score"].mean())
    )

    context.add_output_metadata(
        {
            "num_grid_cells": MetadataValue.int(len(report)),
            "top_10_at_risk": MetadataValue.md(
                report[["grid_cell", "mean_health_score", "severe_risk_scenes"]]
                .head(10)
                .to_markdown()
            ),
            "processing_seconds": MetadataValue.float(elapsed),
            "run_id": MetadataValue.text(context.run_id),
        }
    )

    context.log.info(
        f"Report: {len(report)} grid cells, "
        f"global health = {report['mean_health_score'].mean():.3f} in {elapsed:.2f}s"
    )
    return report


# ── Asset checks ──────────────────────────────────────────────────────────────

@asset_check(asset=validated_data)
def validated_data_not_empty(validated_data: pd.DataFrame) -> AssetCheckResult:
    """Fails the run if validation drops all records."""
    return AssetCheckResult(
        passed=len(validated_data) > 0,
        metadata={"record_count": MetadataValue.int(len(validated_data))},
        description="validated_data must contain at least one record",
    )


@asset_check(asset=ml_predictions)
def predictions_score_in_range(ml_predictions: pd.DataFrame) -> AssetCheckResult:
    """Ensures all crop health scores are in [0, 1]."""
    oob = ml_predictions[
        (ml_predictions["crop_health_score"] < 0)
        | (ml_predictions["crop_health_score"] > 1)
    ]
    return AssetCheckResult(
        passed=len(oob) == 0,
        metadata={"out_of_range_count": MetadataValue.int(len(oob))},
        description="All crop_health_score values must be between 0 and 1",
    )
