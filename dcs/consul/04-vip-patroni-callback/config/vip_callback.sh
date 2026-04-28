#!/bin/bash
# Patroni on_role_change callback — binds/unbinds a floating VIP on this node.
# Called by Patroni as: vip_callback.sh <action> <role> <scope>
#
# Patroni guarantees this script is called synchronously before connections
# are accepted, so the VIP is bound before clients can reconnect.

ACTION=$1   # on_start, on_stop, on_role_change
ROLE=$2     # master, primary, replica, demoted, uninitialized
SCOPE=$3

VIP="172.31.0.100"
IFACE="eth0"

if [ "$ROLE" = "master" ] || [ "$ROLE" = "primary" ]; then
    sudo ip addr add ${VIP}/24 dev ${IFACE} 2>/dev/null || true
    # Gratuitous ARP: forces all hosts on the LAN to update their ARP cache
    sudo arping -c 3 -I ${IFACE} ${VIP} 2>/dev/null || true
else
    sudo ip addr del ${VIP}/24 dev ${IFACE} 2>/dev/null || true
fi
