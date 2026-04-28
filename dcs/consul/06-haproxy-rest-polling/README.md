# Combination 06 — HAProxy REST Polling (Baseline)

This is the **validated baseline** combination. HAProxy routes traffic to the PostgreSQL primary by polling the Patroni REST API (`/primary` endpoint) via HTTP health checks every 2 seconds. No consul-template, no DNS resolution, no callbacks — pure static health-check-based routing.

---

## Architecture

```
Client → HAProxy :5000
              │
              ▼  HTTP health check → :8008/primary
    patroni-nodeN (current primary, 200 OK)
    patroni-nodeM (replica, 503)
    patroni-nodeL (replica, 503)
```

- 3 Patroni/PostgreSQL nodes
- 1 Consul server (DCS only)
- 1 HAProxy (static config, polls Patroni REST API)
- 1 Client connecting via HAProxy port 5000
- 4 Observer agents (patroni ×1, postgres ×1, consul ×1, haproxy ×1)

---

## Routing mechanism

HAProxy is configured with a static list of all three Patroni nodes. It polls each node's Patroni REST API (`GET :8008/primary`) every 2 seconds:

- `200 OK` → server is UP, receives traffic
- `503` → server is DOWN (replica or unavailable), removed from rotation

`on-marked-down shutdown-sessions` immediately closes existing connections to a downed server so the client reconnects to the new primary.

The haproxy.cfg never changes. HAProxy discovers the new primary autonomously by polling — no external notification needed.

---

## Timing parameters

| Parameter | Value |
|---|---|
| HAProxy check interval (`inter`) | 2s |
| HAProxy fall threshold | 3 consecutive failures |
| HAProxy rise threshold | 2 consecutive successes |
| Patroni `loop_wait` | 10s |
| Patroni `ttl` | 30s |
| Client heartbeat interval | 100ms |
| Observer poll interval | 100ms |

**Worst-case failover detection**: `inter × fall` = 6s (HAProxy marks old primary DOWN) + Patroni election time (~`loop_wait` to `ttl`).

**Typical `hard_stop` downtime**: ~9s

---

## Quick start

```bash
cd dashboard && docker compose up -d          # start shared dashboard
cd dcs/consul/06-haproxy-rest-polling && docker compose up -d
docker exec prb-06-node1 patronictl -c /etc/patroni/patroni.yml list
```

Ports:
- HAProxy stats: http://localhost:8404/stats
- Consul UI: http://localhost:8500

---

## Inspect

```bash
# HAProxy backend status
curl -s http://localhost:8404/stats | grep -i "primary_backend"

# Patroni cluster state
docker exec prb-06-node1 patronictl -c /etc/patroni/patroni.yml list

# HAProxy logs (health check transitions)
docker logs prb-06-haproxy 2>&1 | tail -20

# Trigger failover
docker stop prb-06-node1
```

---

## Files

```
config/
├── patroni.yml      Patroni config (loop_wait=10, ttl=30)
├── consul.json      Consul server config
└── haproxy.cfg      Static HAProxy config with primary_backend and replica_backend
```

HAProxy exposes:
- Port 5000: primary-only backend (write traffic)
- Port 5001: replica round-robin backend (read traffic)
- Port 8404: stats page
- `/var/run/haproxy/admin.sock`: Runtime API socket (level admin)
