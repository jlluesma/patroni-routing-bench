# Combination 06t — HAProxy REST Polling (Tuned)

Identical architecture to [combo 06](../06-haproxy-rest-polling/README.md) but with tighter Patroni timing parameters. The goal is to reduce the leader election window (`loop_wait` + `ttl`) without changing the HAProxy detection mechanism, isolating the effect of Patroni's own timing on total downtime.

---

## Architecture

Same as combo 06 — HAProxy polls Patroni REST API (`/primary`) every 2 seconds. See [06 README](../06-haproxy-rest-polling/README.md) for the full description.

---

## What changed vs combo 06

| Parameter | Combo 06 | Combo 06t |
|---|---|---|
| Patroni `loop_wait` | 10s | 5s |
| Patroni `ttl` | 30s | 20s |
| Patroni `retry_timeout` | 10s | 5s |
| HAProxy `inter` | 2s | 2s |
| HAProxy `fall` | 3 | 3 |
| HAProxy `rise` | 2 | 2 |

The HAProxy health check timing is unchanged. The shorter `loop_wait` means Patroni checks for a leader lock more frequently. The shorter `ttl` means the expired lock is detected faster on `hard_kill` scenarios.

**Expected impact**: reduced `hard_kill` downtime (lock expires at 20s instead of 30s), similar or slightly better `hard_stop` downtime.

---

## Quick start

```bash
cd dashboard && docker compose up -d          # start shared dashboard
cd dcs/consul/06-haproxy-rest-polling-tuned && docker compose up -d
docker exec prb-06t-node1 patronictl -c /etc/patroni/patroni.yml list
```

Ports:
- HAProxy stats: http://localhost:8405/stats
- Consul UI: http://localhost:8501

---

## Inspect

```bash
docker exec prb-06t-node1 patronictl -c /etc/patroni/patroni.yml list
docker logs prb-06t-haproxy 2>&1 | tail -20
docker stop prb-06t-node1
```

---

## Files

```
config/
├── patroni.yml      Patroni config (loop_wait=5, ttl=20, retry_timeout=5)
├── consul.json      Consul server config
└── haproxy.cfg      Same as combo 06
```
