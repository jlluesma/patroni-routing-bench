# Combination 07 — consul-template HAProxy Reload

consul-template watches the Consul service catalog for the `bench` service. When the registered nodes change (old primary deregisters after a failover), consul-template re-renders `haproxy.cfg` from a template and triggers a graceful HAProxy reload via the master CLI socket.

---

## Architecture

```
Client → HAProxy :5000
              │
              ▼  (config reloaded on catalog change)
consul-template ──→ Consul service catalog
              │
              └──→ haproxy.cfg (rendered from .ctmpl)
              └──→ echo reload | socat → /var/run/haproxy/master.sock
```

- 3 Patroni/PostgreSQL nodes
- 1 Consul server (DCS + service catalog)
- 1 HAProxy (master-worker mode)
- 1 consul-template sidecar
- 1 Client connecting via HAProxy port 5000
- 4 Observer agents (patroni ×1, postgres ×1, consul ×1, haproxy ×1)

---

## Routing mechanism

1. Patroni registers itself in Consul as the `bench` service. Health checks run against `/primary` — passing on the leader, failing on replicas.
2. consul-template watches for any change to the `bench` service catalog (registrations, deregistrations, health check state changes).
3. On change: consul-template renders `haproxy.cfg` from `haproxy.cfg.ctmpl`, writing only the currently healthy (primary-passing) node as an active backend server.
4. consul-template then runs:
   ```
   echo reload | socat - UNIX-CONNECT:/var/run/haproxy/master.sock
   ```
5. HAProxy's master process receives the reload command, forks a new worker with the updated config, drains old connections on the old worker, and shuts it down cleanly.

### Why master CLI socket instead of SIGHUP

The original design used `pid: "service:haproxy"` (shared PID namespace) to send SIGHUP directly. Docker Compose rejected this as a **dependency cycle** (haproxy depends on consul-template for config; consul-template shared haproxy's PID namespace). The master CLI socket approach removes the PID namespace dependency entirely — consul-template only needs the shared `haproxy_run` volume.

---

## Key difference vs combo 06

| | Combo 06 | Combo 07 |
|---|---|---|
| Config | Static, never changes | Dynamic, rendered by consul-template |
| Update trigger | HAProxy polls every 2s | Consul catalog change (event-driven) |
| HAProxy reload | Never | On every catalog change |
| Extra lag | `inter × fall` (up to 6s) | Consul deregistration latency |

---

## Timing parameters

| Parameter | Value |
|---|---|
| Consul health check interval | 5s |
| Patroni `loop_wait` | 10s |
| Patroni `ttl` | 30s |
| Client heartbeat interval | 100ms |
| Observer poll interval | 100ms |

---

## Quick start

```bash
cd dashboard && docker compose up -d          # start shared dashboard
cd dcs/consul/07-consul-template-reload && docker compose up -d
docker exec prb-07-node1 patronictl -c /etc/patroni/patroni.yml list
```

Ports:
- HAProxy stats: http://localhost:8406/stats
- Consul UI: http://localhost:8505

---

## Inspect

```bash
# Watch consul-template re-render events
docker logs prb-07-consul-template -f

# Check rendered haproxy.cfg
docker exec prb-07-haproxy cat /usr/local/etc/haproxy/haproxy.cfg

# HAProxy worker status
docker logs prb-07-haproxy 2>&1 | tail -20

# Trigger failover
docker stop prb-07-node1
```

---

## Files

```
config/
├── patroni.yml                Patroni config with Consul service registration
├── consul.json                Consul server config
├── consul-template.hcl        consul-template config (template path, command)
├── haproxy.cfg.ctmpl          Jinja-like template for haproxy.cfg
└── Dockerfile.consul-template Builds consul-template image with socat added
```

consul-template and HAProxy share two Docker volumes:
- `haproxy_config` (`/usr/local/etc/haproxy`) — rendered haproxy.cfg
- `haproxy_run` (`/var/run/haproxy`) — master CLI socket
