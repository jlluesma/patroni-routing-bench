#!/bin/bash
# Patroni on_role_change callback — updates HAProxy primary_backend server
# state via the HAProxy Runtime API TCP socket.
#
# Called by Patroni as: haproxy_callback.sh <action> <role> <scope>
#
# Implementation note:
#   The spec originally used:
#     curl -s "http://haproxy:8404/runtime-api" --data "set server ..."
#   HAProxy's Runtime API is NOT an HTTP endpoint — it is a line-oriented
#   protocol over a Unix or TCP socket. curl cannot speak this protocol.
#   The patroni image has Python 3 but not socat/nc, so we use Python's
#   socket module to open a TCP connection to HAProxy's stats socket
#   (stats socket ipv4@*:9999 level admin in haproxy.cfg).

ACTION=$1   # on_start, on_stop, on_role_change
ROLE=$2     # master, primary, replica, demoted, uninitialized
SCOPE=$3

NODE=$(hostname)
HAPROXY_HOST="haproxy"
HAPROXY_PORT=9999

if [ "$ROLE" = "primary" ] || [ "$ROLE" = "master" ]; then
    STATE="ready"
else
    STATE="maint"
fi

python3 - <<EOF 2>/dev/null || true
import socket, sys
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(("${HAPROXY_HOST}", ${HAPROXY_PORT}))
    s.sendall(b"set server primary_backend/${NODE} state ${STATE}\n")
    s.close()
except Exception as e:
    sys.exit(0)  # never fail Patroni if HAProxy is unavailable
EOF
