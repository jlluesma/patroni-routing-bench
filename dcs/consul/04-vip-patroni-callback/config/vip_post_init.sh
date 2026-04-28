#!/bin/bash
# Bind the VIP after initial cluster bootstrap.
# post_init is called only once, on the initial leader.
# Arguments from Patroni: $1 = connection string (ignored)
VIP="172.31.0.100"
IFACE="eth0"
sudo ip addr add ${VIP}/24 dev ${IFACE} 2>/dev/null || true
sudo arping -c 3 -I ${IFACE} ${VIP} 2>/dev/null || true
exit 0
