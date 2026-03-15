from setuptools import find_packages, setup

setup(
    name="hydrosat-pipeline",
    version="0.1.0",
    author="Hydrosat Platform Engineering",
    description="Dagster data pipeline for Hydrosat geospatial / ML processing",
    packages=find_packages(exclude=["tests*"]),
    install_requires=[
        "dagster>=1.7.0,<2.0.0",
        "dagster-postgres>=0.23.0",
        "dagster-k8s>=0.23.0",
        "dagster-aws>=0.23.0",
        "dagster-prometheus>=0.23.0",
        "boto3>=1.34.0",
        "pandas>=2.2.0",
        "numpy>=1.26.0",
        "pyarrow>=15.0.0",
        "psycopg2-binary>=2.9.9",
        "prometheus-client>=0.20.0",
    ],
    extras_require={
        "dev": [
            "dagster-webserver>=1.7.0",
            "pytest>=8.0.0",
            "pytest-dagster>=0.23.0",
        ]
    },
    entry_points={
        "console_scripts": [
            "dagster-dev=dagster.cli:main",
        ]
    },
)
