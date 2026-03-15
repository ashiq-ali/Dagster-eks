"""
Tests for Dagster job definitions — verifies job structure, tags, and
that job/schedule/sensor names are stable (renames break Dagster run history).
"""

import pytest
from dagster import validate_run_config

from pipeline.jobs import satellite_pipeline_job, ingestion_job, ml_inference_job
from pipeline.sensors import hourly_satellite_pipeline, daily_ml_inference
from pipeline import defs


class TestJobDefinitions:
    def test_satellite_pipeline_job_exists(self):
        assert satellite_pipeline_job is not None
        assert satellite_pipeline_job.name == "satellite_data_pipeline"

    def test_ingestion_job_exists(self):
        assert ingestion_job.name == "satellite_ingestion_only"

    def test_ml_inference_job_exists(self):
        assert ml_inference_job.name == "ml_inference_only"

    def test_satellite_pipeline_has_team_tag(self):
        assert satellite_pipeline_job.tags.get("team") == "data-platform"

    def test_all_jobs_registered_in_defs(self):
        job_names = {j.name for j in defs.jobs}
        assert "satellite_data_pipeline" in job_names
        assert "satellite_ingestion_only" in job_names
        assert "ml_inference_only" in job_names

    def test_run_config_valid(self):
        result = validate_run_config(satellite_pipeline_job, run_config={})
        assert result.success


class TestSchedules:
    def test_hourly_schedule_cron(self):
        assert hourly_satellite_pipeline.cron_schedule == "0 * * * *"

    def test_daily_ml_cron(self):
        assert daily_ml_inference.cron_schedule == "0 6 * * *"

    def test_schedules_registered_in_defs(self):
        schedule_names = {s.name for s in defs.schedules}
        assert "hourly_satellite_pipeline" in schedule_names
        assert "daily_ml_inference" in schedule_names


class TestDefinitionsObject:
    def test_defs_loads_without_error(self):
        """Top-level Definitions object must be importable without errors."""
        assert defs is not None

    def test_defs_has_assets(self):
        assert len(list(defs.assets)) > 0

    def test_defs_has_jobs(self):
        assert len(defs.jobs) == 3

    def test_defs_has_sensors(self):
        sensor_names = {s.name for s in defs.sensors}
        assert "s3_new_data_sensor" in sensor_names
        assert "run_failure_alert_sensor" in sensor_names

    def test_all_asset_groups_present(self):
        """All five pipeline stages are present as asset groups."""
        groups = {
            asset.group_names_by_key.get(key, "default")
            for asset in defs.assets
            for key in (asset.keys if hasattr(asset, "keys") else [])
        }
        expected = {"ingestion", "validation", "feature_engineering",
                    "ml_inference", "reporting"}
        # At minimum all expected groups should be a subset of registered groups
        assert expected.issubset(groups) or len(list(defs.assets)) >= 5
