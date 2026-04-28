#!/bin/bash
set -e

# patroni-routing-bench: postgres-patroni entrypoint
# Starts Patroni using either:
#   1. A mounted config file at /etc/patroni/patroni.yml
#   2. Environment variables (PATRONI_* namespace)

PATRONI_CONFIG="${PATRONI_CONFIG:-/etc/patroni/patroni.yml}"

# Wait for Consul to be reachable before starting Patroni
if [ -n "${CONSUL_HOST}" ]; then
    echo "Waiting for Consul at ${CONSUL_HOST}:${CONSUL_PORT:-8500}..."
    retries=0
    max_retries=30
    until curl -sf "http://${CONSUL_HOST}:${CONSUL_PORT:-8500}/v1/status/leader" > /dev/null 2>&1; do
        retries=$((retries + 1))
        if [ ${retries} -ge ${max_retries} ]; then
            echo "ERROR: Consul not reachable after ${max_retries} attempts. Exiting."
            exit 1
        fi
        echo "  Consul not ready yet (attempt ${retries}/${max_retries})..."
        sleep 2
    done
    echo "Consul is ready."
fi

# Start Patroni
if [ -f "${PATRONI_CONFIG}" ]; then
    echo "Starting Patroni with config: ${PATRONI_CONFIG}"
    exec patroni "${PATRONI_CONFIG}"
else
    echo "ERROR: Patroni config not found at ${PATRONI_CONFIG}"
    echo "Mount a config file or set PATRONI_CONFIG to the correct path."
    exit 1
fi
