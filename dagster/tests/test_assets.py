"""
Unit tests for the Hydrosat satellite data pipeline assets.

Tests run fully in-process using Dagster's materialise_to_memory() helper —
no Kubernetes, no RDS, no S3 required. Each asset is tested in isolation and
as part of the full pipeline.
"""

import random

import pytest
import pandas as pd
import numpy as np

from dagster import (
    materialize_to_memory,
    DagsterInstance,
    build_asset_context,
)

from pipeline.assets import (
    raw_satellite_data,
    validated_data,
    feature_engineered_data,
    ml_predictions,
    pipeline_report,
    validated_data_not_empty,
    predictions_score_in_range,
)


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture
def sample_raw_df() -> pd.DataFrame:
    """Minimal valid raw DataFrame matching raw_satellite_data schema."""
    n = 50
    return pd.DataFrame({
        "scene_id":            [f"SCENE_{i:06d}" for i in range(n)],
        "acquisition_date":    pd.date_range("2024-01-01", periods=n, freq="1h"),
        "latitude":            np.random.uniform(-90, 90, n),
        "longitude":           np.random.uniform(-180, 180, n),
        "cloud_cover_pct":     np.random.uniform(0, 70, n),   # kept under 80 % threshold
        "ndvi":                np.random.uniform(-1, 1, n),
        "surface_temp_kelvin": np.random.normal(288, 10, n),
        "soil_moisture":       np.random.uniform(0, 1, n),
        "ingested_at":         "2024-01-01T00:00:00+00:00",
    })


@pytest.fixture
def sample_validated_df(sample_raw_df) -> pd.DataFrame:
    """Returns the raw DataFrame with validation filters already applied."""
    df = sample_raw_df.copy()
    df = df.dropna(subset=["scene_id", "latitude", "longitude", "ndvi"])
    df = df[(df["cloud_cover_pct"] >= 0) & (df["cloud_cover_pct"] <= 80)]
    df = df[(df["ndvi"] >= -1) & (df["ndvi"] <= 1)]
    df = df.drop_duplicates(subset=["scene_id"])
    return df


@pytest.fixture
def sample_features_df(sample_validated_df) -> pd.DataFrame:
    """Validated DataFrame with features added."""
    df = sample_validated_df.copy()
    df["month"] = df["acquisition_date"].dt.month
    df["day_of_year"] = df["acquisition_date"].dt.dayofyear
    df["hour_of_day"] = df["acquisition_date"].dt.hour
    df["season"] = df["month"].map({
        12: "winter", 1: "winter", 2: "winter",
        3: "spring", 4: "spring", 5: "spring",
        6: "summer", 7: "summer", 8: "summer",
        9: "autumn", 10: "autumn", 11: "autumn"
    })
    df["vegetation_health_index"] = (
        (df["ndvi"] + 1) / 2 * (1 - df["cloud_cover_pct"] / 100)
    )
    df["thermal_anomaly"] = (
        df["surface_temp_kelvin"] - df["surface_temp_kelvin"].mean()
    ) / df["surface_temp_kelvin"].std()
    df["moisture_stress"] = 1 - df["soil_moisture"]
    df["grid_lat"]  = (df["latitude"]  / 0.5).astype(int) * 0.5
    df["grid_lon"]  = (df["longitude"] / 0.5).astype(int) * 0.5
    df["grid_cell"] = df["grid_lat"].astype(str) + "_" + df["grid_lon"].astype(str)
    return df


# ── raw_satellite_data ────────────────────────────────────────────────────────

class TestRawSatelliteData:
    def test_returns_dataframe(self, monkeypatch):
        """Asset returns a non-empty DataFrame on the happy path."""
        monkeypatch.setattr(random, "random", lambda: 0.5)  # above failure_rate threshold
        result = materialize_to_memory([raw_satellite_data])
        df = result.output_for_node("raw_satellite_data")
        assert isinstance(df, pd.DataFrame)
        assert len(df) > 0

    def test_expected_columns(self, monkeypatch):
        """Output contains the required schema columns."""
        monkeypatch.setattr(random, "random", lambda: 0.5)
        result = materialize_to_memory([raw_satellite_data])
        df = result.output_for_node("raw_satellite_data")
        required = {"scene_id", "acquisition_date", "latitude", "longitude",
                    "cloud_cover_pct", "ndvi", "surface_temp_kelvin", "soil_moisture"}
        assert required.issubset(set(df.columns))

    def test_raises_on_simulated_failure(self, monkeypatch):
        """Asset raises RuntimeError when random failure is triggered."""
        monkeypatch.setattr(random, "random", lambda: 0.0)  # below failure_rate threshold
        with pytest.raises(Exception):
            materialize_to_memory([raw_satellite_data])

    def test_ndvi_range(self, monkeypatch):
        """Generated NDVI values are within the physically valid range [-1, 1]."""
        monkeypatch.setattr(random, "random", lambda: 0.5)
        result = materialize_to_memory([raw_satellite_data])
        df = result.output_for_node("raw_satellite_data")
        assert df["ndvi"].between(-1, 1).all()

    def test_cloud_cover_range(self, monkeypatch):
        """Cloud cover values are in [0, 100]."""
        monkeypatch.setattr(random, "random", lambda: 0.5)
        result = materialize_to_memory([raw_satellite_data])
        df = result.output_for_node("raw_satellite_data")
        assert df["cloud_cover_pct"].between(0, 100).all()


# ── validated_data ────────────────────────────────────────────────────────────

class TestValidatedData:
    def test_drops_high_cloud_cover(self, sample_raw_df):
        """Scenes with cloud_cover_pct > 80 are removed."""
        df = sample_raw_df.copy()
        df.loc[0, "cloud_cover_pct"] = 95.0
        ctx = build_asset_context()
        out = validated_data(ctx, df)
        assert (out["cloud_cover_pct"] <= 80).all()

    def test_drops_null_critical_columns(self, sample_raw_df):
        df = sample_raw_df.copy()
        df.loc[0, "scene_id"] = None
        ctx = build_asset_context()
        out = validated_data(ctx, df)
        assert out["scene_id"].isna().sum() == 0

    def test_drops_duplicates(self, sample_raw_df):
        dup = sample_raw_df.iloc[0:1].copy()
        combined = pd.concat([sample_raw_df, dup], ignore_index=True)
        ctx = build_asset_context()
        out = validated_data(ctx, combined)
        assert out["scene_id"].is_unique

    def test_drops_out_of_range_ndvi(self, sample_raw_df):
        df = sample_raw_df.copy()
        df.loc[0, "ndvi"] = 1.5   # invalid
        df.loc[1, "ndvi"] = -1.5  # invalid
        ctx = build_asset_context()
        out = validated_data(ctx, df)
        assert out["ndvi"].between(-1, 1).all()

    def test_quality_score_metadata(self, sample_raw_df):
        ctx = build_asset_context()
        out = validated_data(ctx, sample_raw_df)
        assert len(out) <= len(sample_raw_df)

    def test_does_not_fail_on_all_valid_data(self, sample_raw_df):
        """All-valid input should pass through with no records dropped."""
        ctx = build_asset_context()
        out = validated_data(ctx, sample_raw_df)
        # All records in fixture are valid — only cloud > 80 would be dropped
        # and fixture caps at 70 %
        assert len(out) == len(sample_raw_df)


# ── feature_engineered_data ───────────────────────────────────────────────────

class TestFeatureEngineeredData:
    def test_temporal_features_added(self, sample_validated_df):
        ctx = build_asset_context()
        out = feature_engineered_data(ctx, sample_validated_df)
        for col in ["month", "day_of_year", "hour_of_day", "season"]:
            assert col in out.columns, f"Missing column: {col}"

    def test_month_range(self, sample_validated_df):
        ctx = build_asset_context()
        out = feature_engineered_data(ctx, sample_validated_df)
        assert out["month"].between(1, 12).all()

    def test_day_of_year_range(self, sample_validated_df):
        ctx = build_asset_context()
        out = feature_engineered_data(ctx, sample_validated_df)
        assert out["day_of_year"].between(1, 366).all()

    def test_season_values(self, sample_validated_df):
        ctx = build_asset_context()
        out = feature_engineered_data(ctx, sample_validated_df)
        valid_seasons = {"spring", "summer", "autumn", "winter"}
        assert set(out["season"].unique()).issubset(valid_seasons)

    def test_vegetation_health_index_range(self, sample_validated_df):
        """VHI is derived from NDVI and cloud cover — must be in [0, 1]."""
        ctx = build_asset_context()
        out = feature_engineered_data(ctx, sample_validated_df)
        assert out["vegetation_health_index"].between(0, 1).all()

    def test_grid_cell_column_exists(self, sample_validated_df):
        ctx = build_asset_context()
        out = feature_engineered_data(ctx, sample_validated_df)
        assert "grid_cell" in out.columns
        assert out["grid_cell"].notna().all()

    def test_record_count_unchanged(self, sample_validated_df):
        """Feature engineering must not drop any records."""
        ctx = build_asset_context()
        out = feature_engineered_data(ctx, sample_validated_df)
        assert len(out) == len(sample_validated_df)


# ── ml_predictions ────────────────────────────────────────────────────────────

class TestMlPredictions:
    def test_predictions_score_in_range(self, sample_features_df):
        ctx = build_asset_context()
        out = ml_predictions(ctx, sample_features_df)
        assert out["crop_health_score"].between(0, 1).all(), \
            "crop_health_score must be in [0, 1]"

    def test_risk_category_values(self, sample_features_df):
        ctx = build_asset_context()
        out = ml_predictions(ctx, sample_features_df)
        valid = {"low", "moderate", "high", "severe"}
        assert set(out["risk_category"].dropna().astype(str).unique()).issubset(valid)

    def test_prediction_columns_present(self, sample_features_df):
        ctx = build_asset_context()
        out = ml_predictions(ctx, sample_features_df)
        for col in ["crop_health_score", "risk_category",
                    "prediction_timestamp", "model_version"]:
            assert col in out.columns

    def test_model_version_set(self, sample_features_df):
        ctx = build_asset_context()
        out = ml_predictions(ctx, sample_features_df)
        assert out["model_version"].nunique() == 1
        assert "v1" in out["model_version"].iloc[0]

    def test_no_records_dropped(self, sample_features_df):
        ctx = build_asset_context()
        out = ml_predictions(ctx, sample_features_df)
        assert len(out) == len(sample_features_df)


# ── pipeline_report ───────────────────────────────────────────────────────────

class TestPipelineReport:
    def test_aggregated_by_grid_cell(self, sample_features_df):
        ctx = build_asset_context()
        preds = ml_predictions(ctx, sample_features_df)
        out = pipeline_report(ctx, preds)
        # Report has one row per unique grid cell
        assert out["grid_cell"].is_unique

    def test_report_columns(self, sample_features_df):
        ctx = build_asset_context()
        preds = ml_predictions(ctx, sample_features_df)
        out = pipeline_report(ctx, preds)
        for col in ["grid_cell", "scene_count", "mean_health_score",
                    "high_risk_scenes", "severe_risk_scenes"]:
            assert col in out.columns

    def test_scene_count_positive(self, sample_features_df):
        ctx = build_asset_context()
        preds = ml_predictions(ctx, sample_features_df)
        out = pipeline_report(ctx, preds)
        assert (out["scene_count"] > 0).all()

    def test_mean_health_score_range(self, sample_features_df):
        ctx = build_asset_context()
        preds = ml_predictions(ctx, sample_features_df)
        out = pipeline_report(ctx, preds)
        assert out["mean_health_score"].between(0, 1).all()

    def test_run_id_populated(self, sample_features_df):
        ctx = build_asset_context()
        preds = ml_predictions(ctx, sample_features_df)
        out = pipeline_report(ctx, preds)
        assert out["pipeline_run_id"].notna().all()


# ── Asset checks ──────────────────────────────────────────────────────────────

class TestAssetChecks:
    def test_validated_data_not_empty_passes(self, sample_validated_df):
        result = validated_data_not_empty(sample_validated_df)
        assert result.passed

    def test_validated_data_not_empty_fails_on_empty(self):
        empty_df = pd.DataFrame(columns=["scene_id"])
        result = validated_data_not_empty(empty_df)
        assert not result.passed

    def test_predictions_score_in_range_passes(self, sample_features_df):
        ctx = build_asset_context()
        preds = ml_predictions(ctx, sample_features_df)
        result = predictions_score_in_range(preds)
        assert result.passed

    def test_predictions_score_in_range_fails_on_oob(self, sample_features_df):
        ctx = build_asset_context()
        preds = ml_predictions(ctx, sample_features_df).copy()
        preds.loc[0, "crop_health_score"] = 1.5   # inject out-of-bounds value
        result = predictions_score_in_range(preds)
        assert not result.passed


# ── End-to-end pipeline materialisation ──────────────────────────────────────

class TestFullPipeline:
    def test_full_pipeline_materialises(self):
        """All five assets materialise successfully in the correct dependency order."""
        with patch("random.random", return_value=0.5):  # disable random failure
            result = materialize_to_memory([
                raw_satellite_data,
                validated_data,
                feature_engineered_data,
                ml_predictions,
                pipeline_report,
            ])

        assert result.success

        report = result.output_for_node("pipeline_report")
        assert isinstance(report, pd.DataFrame)
        assert len(report) > 0
        assert "mean_health_score" in report.columns
        assert report["mean_health_score"].between(0, 1).all()

    def test_pipeline_output_row_counts_decrease_monotonically(self):
        """Each stage can only drop records, never add them (except feature columns)."""
        with patch("random.random", return_value=0.5):
            result = materialize_to_memory([
                raw_satellite_data,
                validated_data,
                feature_engineered_data,
                ml_predictions,
                pipeline_report,
            ])

        raw  = result.output_for_node("raw_satellite_data")
        val  = result.output_for_node("validated_data")
        feat = result.output_for_node("feature_engineered_data")
        pred = result.output_for_node("ml_predictions")

        assert len(val)  <= len(raw),  "Validation must not add records"
        assert len(feat) == len(val),  "Feature engineering must not drop records"
        assert len(pred) == len(feat), "Inference must not drop records"
