###############################################################################
# patroni-failover-observer: observer agent image
# Watches component state changes and pushes timestamped events to TimescaleDB
# Deployed as a sidecar next to each component (Patroni, Consul, HAProxy, etc.)
###############################################################################

FROM python:3.12-slim

LABEL maintainer="patroni-failover-observer"
LABEL description="Failover observer agent for component-level timing"

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    curl \
    iputils-ping \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
RUN pip install --no-cache-dir \
    psycopg[binary] \
    requests \
    pyyaml

# Create app directory
WORKDIR /app

# Copy agent code
COPY core/ /app/core/
COPY watchers/ /app/watchers/

# Create a non-root user
RUN useradd --create-home --shell /bin/bash observer && \
    chown -R observer:observer /app
USER observer

ENTRYPOINT ["python3", "-m", "core.agent"]
