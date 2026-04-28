#!/bin/bash
# Patroni on_role_change callback — BGP Anycast edition.
# Called as: bgp_callback.sh <action> <role> <scope>
#
# On promotion:
#   1. Binds the VIP on loopback so PostgreSQL can accept connections to it.
#   2. Writes "announce route" to the ExaBGP FIFO so FRR learns the route.
#      FRR proxy-ARPs for the VIP and forwards traffic to this node.
#
# On demotion/stop:
#   1. Withdraws the BGP route so FRR stops routing traffic here.
#   2. Removes the VIP from loopback.
#
# The FIFO is on a Docker volume shared between this container (Patroni) and
# the ExaBGP sidecar. If ExaBGP has not started yet the FIFO may not exist;
# the || true guards ensure the callback always exits 0.

ACTION=$1   # on_start, on_stop, on_role_change
ROLE=$2     # master, primary, replica, demoted, uninitialized
SCOPE=$3

VIP="172.32.0.100"
LO="lo"
FIFO="/run/exabgp/exabgp.cmd"

if [ "$ROLE" = "master" ] || [ "$ROLE" = "primary" ]; then
    ip addr add ${VIP}/32 dev ${LO} 2>/dev/null || true
    [ -p "$FIFO" ] && echo "announce route ${VIP}/32 next-hop self" > "$FIFO" 2>/dev/null || true
else
    [ -p "$FIFO" ] && echo "withdraw route ${VIP}/32 next-hop self" > "$FIFO" 2>/dev/null || true
    ip addr del ${VIP}/32 dev ${LO} 2>/dev/null || true
fi
