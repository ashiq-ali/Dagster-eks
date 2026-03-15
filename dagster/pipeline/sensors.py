"""
Dagster sensors and schedules.

Sensors react to external state; schedules fire on a cron cadence.
Both are managed by the Dagster daemon running in the EKS cluster.
"""

import json
import os
import boto3
from datetime import datetime
from functools import lru_cache

from dagster import (
    DagsterRunStatus,
    RunRequest,
    RunsFilter,
    SensorEvaluationContext,
    SensorResult,
    SkipReason,
    sensor,
    ScheduleDefinition,
    DefaultScheduleStatus,
)

from .jobs import satellite_pipeline_job, ml_inference_job


# ── Helpers ───────────────────────────────────────────────────────────────────

def _aws_region() -> str:
    return os.getenv("AWS_REGION", "us-east-1")


@lru_cache(maxsize=1)
def _aws_account_id() -> str:
    """Resolves the current AWS account ID once and caches it."""
    return boto3.client("sts", region_name=_aws_region()).get_caller_identity()["Account"]


def _sns_topic_arn() -> str:
    # Prefer the full ARN (injected by Terraform) to avoid account-ID resolution at runtime.
    full_arn = os.getenv("DAGSTER_SNS_TOPIC_ARN", "")
    if full_arn:
        return full_arn
    # Fallback: construct from topic name (requires STS call)
    topic_name = os.getenv("DAGSTER_SNS_TOPIC", "hydrosat-dagster-alerts")
    return f"arn:aws:sns:{_aws_region()}:{_aws_account_id()}:{topic_name}"


# ── Schedule: hourly pipeline ─────────────────────────────────────────────────

hourly_satellite_pipeline = ScheduleDefinition(
    job=satellite_pipeline_job,
    cron_schedule="0 * * * *",       # Every hour at :00
    default_status=DefaultScheduleStatus.RUNNING,
    name="hourly_satellite_pipeline",
    description="Trigger full satellite pipeline every hour.",
    tags={
        "trigger": "schedule",
        "cron": "0 * * * *",
    },
)

# ── Schedule: daily ML re-scoring ─────────────────────────────────────────────

daily_ml_inference = ScheduleDefinition(
    job=ml_inference_job,
    cron_schedule="0 6 * * *",       # Every day at 06:00 UTC
    default_status=DefaultScheduleStatus.RUNNING,
    name="daily_ml_inference",
    description="Re-score features with the latest model daily at 06:00 UTC.",
    tags={
        "trigger": "schedule",
        "cron": "0 6 * * *",
    },
)


# ── Sensor: S3 landing zone → trigger pipeline when new data arrives ───────────

@sensor(
    job=satellite_pipeline_job,
    name="s3_new_data_sensor",
    description=(
        "Polls an S3 prefix for new satellite data files. "
        "When a new object appears, triggers a pipeline run with the file key as config."
    ),
    minimum_interval_seconds=60,  # Poll every 60 seconds
)
def s3_new_data_sensor(context: SensorEvaluationContext) -> SensorResult:
    """
    Checks s3://hydrosat-landing/incoming/ for new Parquet files.
    Tracks the last seen key via the sensor cursor to avoid re-processing.

    In production this could also be triggered by an S3 Event Notification
    → SQS → this sensor (event-driven, lower latency than polling).
    """
    bucket = os.getenv("HYDROSAT_LANDING_BUCKET", "hydrosat-landing-prod")
    prefix = "incoming/"

    s3 = boto3.client("s3", region_name=_aws_region())

    cursor = context.cursor  # Last processed S3 key
    new_keys = []

    try:
        paginator = s3.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
            for obj in page.get("Contents", []):
                key = obj["Key"]
                if not key.endswith(".parquet"):
                    continue
                if cursor is None or key > cursor:
                    new_keys.append(key)
    except Exception as e:
        context.log.warning(f"S3 sensor poll failed: {e}")
        return SensorResult(skip_reason=SkipReason(f"S3 poll error: {e}"))

    if not new_keys:
        return SensorResult(skip_reason=SkipReason("No new files in S3 landing zone."))

    run_requests = [
        RunRequest(
            run_key=key,  # Idempotent — same key never triggers twice
            tags={"source_key": key, "trigger": "s3_sensor"},
        )
        for key in sorted(new_keys)
    ]

    # Advance cursor to the latest key processed
    new_cursor = max(new_keys)
    context.log.info(f"Sensor triggered {len(run_requests)} runs for new S3 files.")

    return SensorResult(run_requests=run_requests, cursor=new_cursor)


# ── Sensor: Dagster run failure → alert via SNS ────────────────────────────────

@sensor(
    job=None,
    name="run_failure_alert_sensor",
    description=(
        "Monitors completed runs. On failure, publishes an SNS notification "
        "as a secondary alerting path alongside Prometheus/Alertmanager."
    ),
    minimum_interval_seconds=30,
)
def run_failure_alert_sensor(context: SensorEvaluationContext) -> SensorResult:
    """
    Provides a Dagster-native alerting path (SNS) as a belt-and-suspenders
    complement to the Prometheus/Alertmanager stack. This ensures alerts fire
    even if the monitoring stack is itself degraded.

    Uses public Dagster APIs only (RunsFilter, DagsterRunStatus) for
    compatibility across Dagster minor versions.
    """
    # Public API — stable across Dagster 1.x
    recent_failed = context.instance.get_runs(
        filters=RunsFilter(statuses=[DagsterRunStatus.FAILURE]),
        limit=10,
    )

    if not recent_failed:
        return SensorResult(skip_reason=SkipReason("No failed runs detected."))

    sns = boto3.client("sns", region_name=_aws_region())
    topic_arn = _sns_topic_arn()

    try:
        cursor_data = json.loads(context.cursor or "{}")
        if not isinstance(cursor_data, dict):
            cursor_data = {}
    except (json.JSONDecodeError, ValueError):
        context.log.warning("Cursor was invalid JSON — resetting to empty.")
        cursor_data = {}
    alerted_runs: list = cursor_data.get("alerted_runs", [])
    if not isinstance(alerted_runs, list):
        alerted_runs = []
    newly_alerted: list = []

    for run in recent_failed:
        # Idempotency — only alert once per run_id
        if run.run_id in alerted_runs:
            continue

        message = {
            "alert": "DagsterJobFailed",
            "run_id": run.run_id,
            "job_name": run.job_name,
            "status": run.status.value,
            "tags": dict(run.tags),
            "timestamp": datetime.utcnow().isoformat(),
            "dagit_url": f"{os.getenv('DAGIT_URL', 'http://localhost:3000')}/runs/{run.run_id}",
        }

        try:
            sns.publish(
                TopicArn=topic_arn,
                Subject=f"[CRITICAL] Dagster job failed: {run.job_name}",
                Message=json.dumps(message, indent=2),
                MessageAttributes={
                    "severity": {"DataType": "String", "StringValue": "critical"},
                    "job_name": {"DataType": "String", "StringValue": run.job_name},
                },
            )
            context.log.info(f"SNS alert sent for run {run.run_id} to {topic_arn}")
            newly_alerted.append(run.run_id)
        except Exception as e:
            context.log.error(f"Failed to publish SNS alert for run {run.run_id}: {e}")

    # Update cursor — keep last 100 alerted run IDs to bound cursor size
    updated_cursor = json.dumps({"alerted_runs": (alerted_runs + newly_alerted)[-100:]})
    return SensorResult(
        skip_reason=SkipReason(f"Processed {len(newly_alerted)} alert(s)."),
        cursor=updated_cursor,
    )
