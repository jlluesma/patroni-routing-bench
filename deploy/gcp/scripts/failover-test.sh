#!/usr/bin/env bash
# failover-test.sh — trigger failover scenarios on GCP VMs
#
# Usage:
#   ./scripts/failover-test.sh --scenario hard_stop [--target patroni-1] [--recover]
#
# Scenarios:
#   hard_stop         SIGTERM → Patroni shuts down cleanly, releases DCS lock
#   hard_kill         SIGKILL → no cleanup, Consul session TTL must expire
#   switchover        patronictl switchover --force (planned)
#   network_partition iptables DROP → real network split
#
# Recovery:
#   After hard_stop / hard_kill, add --recover to restart Patroni on the target.
#   For network_partition, use --recover to flush iptables.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="${SCRIPT_DIR}/../ansible/inventory/gcp.ini"

SCENARIO=""
TARGET="patroni-1"
SSH_KEY="${SSH_KEY:-~/.ssh/id_rsa}"
RECOVER=false

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario)   SCENARIO="$2";  shift 2 ;;
        --target)     TARGET="$2";    shift 2 ;;
        --key)        SSH_KEY="$2";   shift 2 ;;
        --recover)    RECOVER=true;   shift ;;
        -h|--help)
            grep '^#' "$0" | head -20 | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$SCENARIO" ]] && [[ "$RECOVER" == "false" ]]; then
    echo "Usage: $0 --scenario SCENARIO [--target NODE] [--recover]" >&2
    exit 1
fi

# --- Resolve external IP from inventory ---
get_external_ip() {
    local host="$1"
    grep "^${host} " "$INVENTORY" | grep -oP 'ansible_host=\K[^ ]+' | head -1
}

get_ansible_user() {
    grep 'ansible_user=' "$INVENTORY" | grep -oP 'ansible_user=\K\S+' | head -1
}

SSH_USER="$(get_ansible_user)"
TARGET_IP="$(get_external_ip "$TARGET")"

if [[ -z "$TARGET_IP" ]]; then
    echo "Could not resolve IP for '$TARGET' from $INVENTORY" >&2
    exit 1
fi

SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no ${SSH_USER}@${TARGET_IP}"

echo "Target: ${TARGET} (${TARGET_IP}), Scenario: ${SCENARIO}"

# --- Recovery path ---
if [[ "$RECOVER" == "true" ]]; then
    case "$SCENARIO" in
        hard_stop|hard_kill|"")
            echo "Restarting Patroni on ${TARGET}..."
            $SSH "sudo systemctl start patroni"
            ;;
        network_partition)
            echo "Flushing iptables on ${TARGET}..."
            $SSH "sudo iptables -F INPUT && sudo iptables -F OUTPUT"
            ;;
        *)
            echo "No recovery action defined for scenario: ${SCENARIO}" >&2
            exit 1
            ;;
    esac
    echo "Recovery command sent. Wait for cluster to stabilise before next test."
    exit 0
fi

# --- Failure injection ---
case "$SCENARIO" in
    hard_stop)
        echo "Sending SIGTERM to Patroni on ${TARGET}..."
        $SSH "sudo systemctl stop patroni"
        echo "Patroni stopped. Consul session will be released immediately."
        echo "Recovery: $0 --scenario hard_stop --target ${TARGET} --recover"
        ;;

    hard_kill)
        echo "Sending SIGKILL to Patroni and PostgreSQL on ${TARGET}..."
        $SSH "sudo kill -9 \$(pgrep -f 'patroni') 2>/dev/null || true; sudo kill -9 \$(pgrep -o postgres) 2>/dev/null || true"
        echo "Processes killed. Consul session will expire after TTL (~30s)."
        echo "Recovery: $0 --scenario hard_kill --target ${TARGET} --recover"
        ;;

    switchover)
        echo "Triggering planned switchover away from ${TARGET}..."
        $SSH "patronictl -c /etc/patroni/patroni.yml switchover --master ${TARGET} --force"
        echo "Switchover initiated. No recovery needed."
        ;;

    network_partition)
        echo "Dropping all subnet traffic on ${TARGET} (iptables)..."
        $SSH "sudo iptables -A INPUT  -s 10.0.1.0/24 -j DROP && \
              sudo iptables -A OUTPUT -d 10.0.1.0/24 -j DROP"
        echo "Network partitioned. Consul session will expire after TTL (~30s)."
        echo "Recovery: $0 --scenario network_partition --target ${TARGET} --recover"
        ;;

    *)
        echo "Unknown scenario: ${SCENARIO}" >&2
        echo "Valid scenarios: hard_stop, hard_kill, switchover, network_partition" >&2
        exit 1
        ;;
esac
