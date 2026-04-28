###############################################################################
# ExaBGP image for patroni-routing-bench combination 05
# Installs ExaBGP via pip on a slim Python base. The official hashicorp
# images are scratch-based and have no shell; we need /bin/sh to run the
# FIFO reader script (exabgp-run.sh).
###############################################################################

FROM python:3.12-slim

RUN pip install --no-cache-dir exabgp

# ExaBGP writes state to /run/exabgp; pre-create so volume mounts can overlay
RUN mkdir -p /run/exabgp /etc/exabgp

ENTRYPOINT ["exabgp"]
