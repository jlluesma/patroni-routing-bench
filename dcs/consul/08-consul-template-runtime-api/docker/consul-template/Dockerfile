###############################################################################
# consul-template image with socat for patroni-routing-bench combination 08
#
# hashicorp/consul-template is Alpine-based. We add:
#   socat  — sends Runtime API commands to HAProxy's admin Unix socket
#   bash   — required because consul-template.hcl runs: bash /tmp/update-haproxy.sh
#
# Running as root so the admin socket (mode 660, owned by haproxy:haproxy)
# is accessible without group membership management.
###############################################################################

FROM hashicorp/consul-template:latest

USER root
RUN apk add --no-cache socat bash

ENTRYPOINT ["/bin/consul-template"]
