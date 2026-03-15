"""
Dagster resources for the Hydrosat pipeline.

Resources are injectable, environment-aware dependencies — S3, database
connections, external APIs — wired at deploy time via resource config.
"""

import os
import boto3
from dagster import (
    ConfigurableResource,
)
from dagster_aws.s3 import S3Resource
from prometheus_client import Counter, Gauge, Histogram


# ── Prometheus metrics ────────────────────────────────────────────────────────
# These are registered at module load time and exported via the built-in
# /metrics endpoint exposed by dagster-prometheus.

RECORDS_PROCESSED = Counter(
    "hydrosat_records_processed_total",
    "Total number of data records processed by the pipeline",
    ["job_name", "asset_name", "status"],
)

PROCESSING_DURATION = Histogram(
    "hydrosat_asset_processing_duration_seconds",
    "Time taken to materialise an asset",
    ["job_name", "asset_name"],
    buckets=[1, 5, 10, 30, 60, 120, 300, 600],
)

PIPELINE_ACTIVE_RUNS = Gauge(
    "hydrosat_pipeline_active_runs",
    "Number of currently active Dagster runs",
    ["job_name"],
)

DATA_QUALITY_SCORE = Gauge(
    "hydrosat_data_quality_score",
    "Data quality score (0-1) for the latest pipeline output",
    ["asset_name"],
)


# ── S3 Resource ───────────────────────────────────────────────────────────────

class HydrosatS3Resource(ConfigurableResource):
    """Thin wrapper around boto3 S3 client with built-in observability."""

    bucket_name: str
    region_name: str = "us-east-1"

    def get_client(self):
        return boto3.client("s3", region_name=self.region_name)

    def upload_dataframe(self, df, key: str) -> str:
        """Upload a pandas DataFrame as Parquet to S3."""
        import io
        import pyarrow as pa
        import pyarrow.parquet as pq

        buf = io.BytesIO()
        table = pa.Table.from_pandas(df)
        pq.write_table(table, buf, compression="snappy")
        buf.seek(0)

        client = self.get_client()
        client.put_object(Bucket=self.bucket_name, Key=key, Body=buf.getvalue())
        return f"s3://{self.bucket_name}/{key}"

    def read_parquet(self, key: str):
        """Read a Parquet file from S3 into a pandas DataFrame."""
        import io
        import pandas as pd

        client = self.get_client()
        response = client.get_object(Bucket=self.bucket_name, Key=key)
        return pd.read_parquet(io.BytesIO(response["Body"].read()))


# ── Postgres Resource ─────────────────────────────────────────────────────────

class PostgresResource(ConfigurableResource):
    """Direct PostgreSQL connection resource for pipeline queries."""

    host: str
    port: int = 5432
    database: str
    username: str
    password: str

    def get_connection(self):
        import psycopg2

        return psycopg2.connect(
            host=self.host,
            port=self.port,
            dbname=self.database,
            user=self.username,
            password=self.password,
            connect_timeout=10,
        )
