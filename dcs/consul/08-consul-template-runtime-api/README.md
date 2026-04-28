# Combination 08 — consul-template Runtime API

consul-template watches the Consul service catalog for the `bench` service. When the primary changes, it renders a shell script and executes it. The script uses `socat` to send `set server ... state ready/maint` commands to HAProxy's Runtime API socket. **HAProxy never reloads** — no workers restart, no connection disruption.

---

## Architecture

```
Client → HAProxy :5000
              │
              ▼  (state updated via Runtime API, no reload)
consul-template ──→ Consul service catalog
              │
              └──→ renders update-haproxy.sh from .ctmpl
              └──→ runs it: socat → /var/run/haproxy/admin.sock
```

- 3 Patroni/PostgreSQL nodes
- 1 Consul server (DCS + service catalog)
- 1 HAProxy (static config, Runtime API on admin socket)
- 1 consul-template sidecar
- 1 Client connecting via HAProxy port 5000
- 4 Observer agents (patroni ×1, postgres ×1, consul ×1, haproxy ×1)

---

## Routing mechanism

1. HAProxy starts with a static config listing all three nodes in `state maint` (maintenance mode — no traffic, no health checks).
2. Patroni registers itself in Consul. The service catalog reflects which nodes pass the `/primary` check.
3. consul-template watches for any `bench` service catalog change.
4. On change: consul-template renders `update-haproxy.sh` from `update-haproxy.sh.ctmpl`. The script contains Runtime API commands:
   ```
   set server primary_backend/<node> state ready   (for passing nodes)
   set server primary_backend/<node> state maint   (for failing nodes)
   ```
5. consul-template immediately executes the rendered script. `socat` opens `/var/run/haproxy/admin.sock` and streams the commands.
6. HAProxy's backend state changes instantly — no reload, no worker restart, no connection disruption.

### Key difference vs combo 07

| | Combo 07 | Combo 08 |
|---|---|---|
| How HAProxy is updated | Config file rewrite + graceful reload | Runtime API socket commands |
| HAProxy reload | Yes (master-worker drain) | Never |
| Connection disruption | Brief (old workers drain) | None |
| Template output | `haproxy.cfg` | Shell script with `socat` commands |

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
cd dcs/consul/08-consul-template-runtime-api && docker compose up -d
docker exec prb-08-node1 patronictl -c /etc/patroni/patroni.yml list
```

Ports:
- HAProxy stats: http://localhost:8407/stats
- Consul UI: http://localhost:8506

---

## Inspect

```bash
# Watch consul-template events
docker logs prb-08-consul-template -f

# Check HAProxy backend states via Runtime API
echo "show servers state" | docker exec -i prb-08-haproxy socat - UNIX-CONNECT:/var/run/haproxy/admin.sock

# Trigger failover
docker stop prb-08-node1
```

---

## Files

```
config/
├── patroni.yml                   Patroni config with Consul service registration
├── consul.json                   Consul server config
├── consul-template.hcl           consul-template config
├── update-haproxy.sh.ctmpl       Template that renders Runtime API commands
└── haproxy.cfg                   Static HAProxy config (all servers in maint initially)
```

consul-template and HAProxy share the `haproxy_run` volume (`/var/run/haproxy`) for the admin socket. The `.ctmpl` uses `.Address` (unique per service registration, returns the node's IP) to identify each server in the Runtime API commands.
