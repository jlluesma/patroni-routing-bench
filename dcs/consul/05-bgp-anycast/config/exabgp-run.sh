#!/bin/sh
# ExaBGP process script — creates a named pipe and bridges it to ExaBGP's
# API stdin. bgp_callback.sh writes "announce/withdraw route ..." commands
# to the FIFO; this script forwards them to ExaBGP via stdout.
#
# The `exec 3<>"$FIFO"` trick keeps the write-end of the FIFO open so that
# `cat` never receives EOF between callback invocations.
#
# Must be executable: chmod +x config/exabgp-run.sh

FIFO=/run/exabgp/exabgp.cmd
mkdir -p "$(dirname "$FIFO")"
rm -f "$FIFO"
mkfifo "$FIFO"
exec 3<>"$FIFO"   # hold write-end open on fd3 to prevent cat from seeing EOF
exec cat "$FIFO"  # forward FIFO contents to ExaBGP's API input (our stdout)
