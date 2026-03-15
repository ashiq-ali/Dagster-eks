# ── Stage 1: builder ──────────────────────────────────────────────────────────
FROM python:3.11-slim AS builder

WORKDIR /build

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    git \
    && rm -rf /var/lib/apt/lists/*

COPY setup.py .
COPY pipeline/ ./pipeline/

# Install dependencies into a prefix we can copy to the final image
RUN pip install --upgrade pip && \
    pip install --prefix=/install . && \
    pip install --prefix=/install dagster-webserver


# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM python:3.11-slim AS runtime

LABEL maintainer="platform@hydrosat.com"
LABEL description="Hydrosat Dagster pipeline code server"
LABEL org.opencontainers.image.source="https://github.com/hydrosat/dagster-platform"

# Runtime system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Non-root user for security
RUN groupadd -r dagster && useradd -r -g dagster -d /opt/dagster dagster

WORKDIR /opt/dagster/app

# Copy installed packages from builder
COPY --from=builder /install /usr/local

# Copy application code
COPY --chown=dagster:dagster pipeline/ ./pipeline/
COPY --chown=dagster:dagster setup.py .

# Dagster home directory (logs, run storage when using local dev)
ENV DAGSTER_HOME=/opt/dagster/dagster_home
RUN mkdir -p $DAGSTER_HOME && chown dagster:dagster $DAGSTER_HOME

USER dagster

# gRPC code server port
EXPOSE 3030

# Health check — Dagster gRPC servers respond to /health
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD python -c "import grpc; ch = grpc.insecure_channel('localhost:3030'); grpc.channel_ready_future(ch).result(timeout=5)" || exit 1

# Launch the gRPC code server — Dagster webserver and daemon connect to this
CMD ["dagster", "api", "grpc", \
     "--host", "0.0.0.0", \
     "--port", "3030", \
     "--module-name", "pipeline", \
     "--attribute", "defs"]
