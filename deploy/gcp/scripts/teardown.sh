#!/usr/bin/env bash
# teardown.sh — stop the observer tool stack and destroy GCP infrastructure
#
# Usage:
#   ./scripts/teardown.sh [--keep-data] [--infra-only] [--tool-only]
#
# Options:
#   --keep-data    Skip `docker compose down -v` (preserves TimescaleDB data)
#   --infra-only   Only destroy Terraform infra (skip observer tool shutdown)
#   --tool-only    Only stop the tool stack on the observer VM (skip Terraform)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="${SCRIPT_DIR}/../ansible/inventory/gcp.ini"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"
SSH_KEY="${SSH_KEY:-~/.ssh/id_rsa}"

KEEP_DATA=false
INFRA_ONLY=false
TOOL_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-data)   KEEP_DATA=true;   shift ;;
        --infra-only)  INFRA_ONLY=true;  shift ;;
        --tool-only)   TOOL_ONLY=true;   shift ;;
        -h|--help)
            grep '^#' "$0" | head -15 | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

get_external_ip() {
    grep "^${1} " "$INVENTORY" | grep -oP 'ansible_host=\K[^ ]+' | head -1
}

get_ansible_user() {
    grep 'ansible_user=' "$INVENTORY" | grep -oP 'ansible_user=\K\S+' | head -1
}

# --- 1. Stop tool stack on observer VM ---
if [[ "$INFRA_ONLY" != "true" ]]; then
    OBSERVER_IP="$(get_external_ip observer)"
    SSH_USER="$(get_ansible_user)"

    if [[ -n "$OBSERVER_IP" ]]; then
        echo "Stopping tool stack on observer VM (${OBSERVER_IP})..."
        COMPOSE_CMD="cd /opt/patroni-routing-bench/tool"
        if [[ "$KEEP_DATA" == "true" ]]; then
            COMPOSE_DOWN="docker compose --profile failover --profile haproxy down"
        else
            COMPOSE_DOWN="docker compose --profile failover --profile haproxy down -v"
        fi
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
            "${SSH_USER}@${OBSERVER_IP}" \
            "${COMPOSE_CMD} && ${COMPOSE_DOWN}" || echo "Observer unreachable — skipping tool shutdown"
    else
        echo "Could not resolve observer IP — skipping tool shutdown"
    fi
fi

# --- 2. Destroy Terraform infrastructure ---
if [[ "$TOOL_ONLY" != "true" ]]; then
    echo ""
    echo "Destroying GCP infrastructure..."
    cd "$TERRAFORM_DIR"
    terraform destroy -auto-approve
    echo ""
    echo "Infrastructure destroyed."
fi

echo "Teardown complete."
