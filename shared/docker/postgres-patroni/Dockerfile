###############################################################################
# patroni-routing-bench: postgres-patroni base image
# PostgreSQL 18 + Patroni (latest) + Consul DCS support
# Used by all 10 combinations as the database node image
###############################################################################

FROM postgres:18

LABEL maintainer="patroni-routing-bench"
LABEL description="PostgreSQL 18 + Patroni with Consul DCS support"

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    gcc \
    libpq-dev \
    curl \
    jq \
    iputils-ping \
    iputils-arping \
    iproute2 \
    libcap2-bin \
    net-tools \
    procps \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Create a virtual environment for Patroni and its dependencies
# This avoids conflicts with system Python packages
ENV PATRONI_VENV=/opt/patroni
RUN python3 -m venv ${PATRONI_VENV}
ENV PATH="${PATRONI_VENV}/bin:${PATH}"

# Install Patroni with Consul DCS support and psycopg3
RUN pip install --no-cache-dir \
    patroni[consul,psycopg3]

# Verify installations
RUN patroni --version && \
    python3 -c "import psycopg; print(f'psycopg3: {psycopg.__version__}')"

# Create directories for Patroni
RUN mkdir -p /etc/patroni /var/log/patroni && \
    chown -R postgres:postgres /etc/patroni /var/log/patroni

# Grant ip command NET_ADMIN capability so postgres user can
# manage VIP addresses without running as root
RUN setcap cap_net_admin,cap_net_raw+ep /sbin/ip || \
    setcap cap_net_admin,cap_net_raw+ep /usr/sbin/ip || true

# Allow postgres user to run ip and arping without password
RUN echo "postgres ALL=(root) NOPASSWD: /sbin/ip, /usr/sbin/ip, /usr/bin/arping, /usr/sbin/arping" > /etc/sudoers.d/vip && \
    chmod 0440 /etc/sudoers.d/vip

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Patroni REST API
EXPOSE 8008
# PostgreSQL
EXPOSE 5432

USER postgres

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
