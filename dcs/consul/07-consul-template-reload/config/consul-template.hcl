# consul-template configuration for combination 07
#
# consul-template watches the Consul service catalog for the "bench" service.
# Whenever a node registers, deregisters, or changes health state, it
# re-renders haproxy.cfg.ctmpl and reloads HAProxy.
#
# Reload mechanism: HAProxy runs in master-worker mode (-W) with a master CLI
# socket exposed at /run/haproxy/master.sock. consul-template sends "reload"
# to that socket via socat. This avoids the circular dependency created by
# pid: "service:haproxy" while preserving zero-downtime config reload
# semantics (HAProxy master spawns new workers, drains old ones).

consul {
  address = "http://consul-server:8500"
}

template {
  source      = "/etc/consul-template/haproxy.cfg.ctmpl"
  destination = "/usr/local/etc/haproxy/haproxy.cfg"
  command     = "echo reload | socat - UNIX-CONNECT:/var/run/haproxy/master.sock 2>/dev/null || true"
}
