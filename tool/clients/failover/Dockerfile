###############################################################################
# patroni-routing-bench: client image
# Traffic generator for failover timing measurement
# Runs a heartbeat INSERT loop and records per-query timestamps
###############################################################################

FROM python:3.12-slim

LABEL maintainer="patroni-routing-bench"
LABEL description="Traffic generator client for failover benchmarking"

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    curl \
    iputils-ping \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
RUN pip install --no-cache-dir \
    psycopg[binary] \
    psycopg_pool \
    requests

# Create app directory
WORKDIR /app

# Copy client scripts
COPY heartbeat.py /app/heartbeat.py
COPY reporter.py /app/reporter.py

# Create a non-root user
RUN useradd --create-home --shell /bin/bash bench && \
    chown -R bench:bench /app
USER bench

ENTRYPOINT ["python3", "/app/heartbeat.py"]
