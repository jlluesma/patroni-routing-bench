# consul-template configuration for combination 08
#
# Instead of rendering haproxy.cfg and reloading (combo 07), this renders a
# shell script that sends HAProxy Runtime API commands via the admin socket.
# HAProxy never restarts or reloads; server states are flipped in-place.
#
# Trigger: any change to the Consul service catalog for "bench" (Patroni
# registers role-tagged services: "primary" for the leader, "replica" for
# standbys). The "any" filter in the template ensures all 3 nodes appear in
# the rendered script even when one is unhealthy.
#
# consul-template runs the destination script with bash after each render.
# socat must be available in the container — see docker/consul-template/.

consul {
  address = "http://consul-server:8500"
}

template {
  source      = "/etc/consul-template/update-haproxy.sh.ctmpl"
  destination = "/tmp/update-haproxy.sh"
  command     = "bash /tmp/update-haproxy.sh"
}
