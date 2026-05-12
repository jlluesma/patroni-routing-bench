#!/usr/bin/env bash
# failover-test.sh — trigger failover scenarios on GCP VMs via Ansible
#
# Usage:
#   ./scripts/failover-test.sh --scenario SCENARIO [--target NODE] [--recover]
#
# Scenarios:
#   hard_stop         systemctl stop patroni (SIGTERM, releases DCS lock)
#   hard_kill         kill -9 Patroni + PostgreSQL (TTL must expire)
#   switchover        patronictl switchover --force (planned, no recovery needed)
#   network_partition iptables DROP on cluster subnet (real network split)
#   postgres_crash    kill -9 postmaster only (Patroni stays running)
#
# Recovery:
#   Add --recover to apply recovery actions on the target node.
#   Switchover and postgres_crash do not need manual recovery.
#
# Examples:
#   ./scripts/failover-test.sh --scenario hard_stop --target patroni-1
#   ./scripts/failover-test.sh --scenario hard_stop --target patroni-1 --recover
#   ./scripts/failover-test.sh --scenario network_partition --target patroni-1
#   ./scripts/failover-test.sh --scenario network_partition --target patroni-1 --recover

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="${SCRIPT_DIR}/../ansible/inventory/gcp.ini"
INJECT_PLAYBOOK="${SCRIPT_DIR}/../ansible/inject.yml"

SCENARIO=""
TARGET="patroni-1"
RECOVER=false

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario)  SCENARIO="$2"; shift 2 ;;
        --target)    TARGET="$2";   shift 2 ;;
        --recover)   RECOVER=true;  shift ;;
        -h|--help)
            grep '^#' "$0" | head -25 | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$SCENARIO" ]] && [[ "$RECOVER" == "false" ]]; then
    echo "Usage: $0 --scenario SCENARIO [--target NODE] [--recover]" >&2
    exit 1
fi

if [[ ! -f "$INVENTORY" ]]; then
    echo "Inventory not found: $INVENTORY" >&2
    echo "Run 'terraform apply' first to generate ansible/inventory/gcp.ini" >&2
    exit 1
fi

# --- Recovery path ---
if [[ "$RECOVER" == "true" ]]; then
    echo "Recovering ${TARGET} from ${SCENARIO}..."
    ansible-playbook -i "$INVENTORY" "$INJECT_PLAYBOOK" \
        -e "scenario=${SCENARIO}" \
        -e "recover=true" \
        -e "target=${TARGET}" \
        --limit "${TARGET}"
    echo "Recovery complete. Wait for cluster to stabilise before the next test."
    exit 0
fi

# --- Failure injection ---
echo "Injecting ${SCENARIO} on ${TARGET}..."

case "$SCENARIO" in
    hard_stop|hard_kill|switchover|network_partition|postgres_crash)
        ansible-playbook -i "$INVENTORY" "$INJECT_PLAYBOOK" \
            -e "scenario=${SCENARIO}" \
            -e "target=${TARGET}" \
            --limit "${TARGET}"
        ;;
    *)
        echo "Unknown scenario: ${SCENARIO}" >&2
        echo "Valid: hard_stop, hard_kill, switchover, network_partition, postgres_crash" >&2
        exit 1
        ;;
esac
