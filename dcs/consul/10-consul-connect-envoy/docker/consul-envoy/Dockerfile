###############################################################################
# consul-envoy: Envoy proxy with the Consul binary for xDS bootstrap.
#
# consul connect envoy needs the Consul binary to:
#   1. Fetch the proxy registration from Consul's catalog
#   2. Generate Envoy's bootstrap configuration (bootstrap.json)
#   3. Hand off to the Envoy process for ongoing xDS streaming
#
# The Consul binary is copied from the official HashiCorp image so that the
# version stays in sync with the consul-server container image.
###############################################################################

FROM hashicorp/consul:latest AS consul-bin

FROM envoyproxy/envoy:latest
COPY --from=consul-bin /bin/consul /usr/local/bin/consul
