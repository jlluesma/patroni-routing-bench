# Measurement Tool

Measure failover timing on your existing Patroni cluster. No changes to your infrastructure — just Docker on one machine and network access.

## What You Need

- Docker and Docker Compose on one machine (your laptop, bastion host, or CI runner)
- Network access from that machine to your Patroni nodes, Consul, and PostgreSQL

## What It Measures

When you inject a failure on your Patroni cluster, the tool captures timestamped events at every layer of the failover cascade:

| Observer | What it watches | Events captured |
|---|---|---|
| **patroni** | REST API on each node | role_change, node_state_change, timeline_change |
| **consul** | KV leader key (blocking queries) | leader_key_deleted, leader_key_created |
| **haproxy** | Stats CSV endpoint | backend_state_change (UP/DOWN per server) |
| **postgres** | Direct SQL on each node | `pg_promote_detected`, `pg_ready_accept_connections`, `pg_connection_lost` |
| **client** | PostgreSQL queries through routing layer | query_success, query_failure + latency |

All events land in TimescaleDB with microsecond timestamps. The result: you see exactly where time is spent during a failover.

## Quick Start

```bash
cd tool/

# 1. Configure your endpoints
cp .env.example .env
vim .env    # fill in your Patroni node IPs, Consul URL, PG connection

# 2. Start observers + TimescaleDB
docker compose up -d
# If your routing layer is HAProxy:
# docker compose --profile haproxy up -d

# 3. Verify observers are connecting
docker compose logs observer-patroni | tail -5   # should show role_change events
docker compose logs observer-consul | tail -5    # should show leader_key events

# 4. Start the heartbeat client
docker compose --profile failover up -d

# 5. Verify the heartbeat (should show 100% success)
docker compose logs -f client-failover
# Press Ctrl+C after seeing a few success lines

# 6. Inject failure on your cluster (you control this)
ssh admin@leader "sudo systemctl stop patroni"

# 7. Watch recovery — the client auto-detects the failover
docker compose logs -f client-failover
# You'll see:
#   [auto-test-run] Failover detected — registering test_run_id: my-cluster_20260513_221500
#   [auto-test-run] Failover recovered — test_run_id: my-cluster_20260513_221500
#   [auto-test-run] Downtime: 6322ms, Failed queries: 3

# 8. Check results
docker exec prb-tsdb psql -U bench -c \
  "SELECT test_run_id, downtime_ms, total_failures FROM failover_window;"

# 9. Generate report
docker compose --profile charts run --rm charts db-report --output /results/report.html

# 10. View report
open results/report.html    # macOS
xdg-open results/report.html  # Linux
```

The heartbeat client automatically detects failovers and registers test runs. Each failover gets a unique test_run_id. You can inject multiple failures — each one is tracked separately.

## Architecture

```
Your machine (Docker)                Your cluster (untouched)
┌──────────────────────────┐         ┌──────────────────────────┐
│                          │         │                          │
│  TimescaleDB             │         │  Patroni node1 (:8008)   │
│  ├─ observer events      │         │  Patroni node2 (:8008)   │
│  └─ client events        │         │  Patroni node3 (:8008)   │
│                          │         │                          │
│  observer-patroni ───────┼── HTTP ─┤  Consul server (:8500)   │
│  observer-consul  ───────┼── HTTP ─┤                          │
│  observer-haproxy ───────┼── HTTP ─┤  HAProxy (:8404)         │
│  observer-postgres ───────┼── TCP ──┤  PostgreSQL (:5432)      │
│                          │         │                          │
│  client-failover  ───────┼── TCP ──┤  PostgreSQL (:5432)      │
│                          │         │  (via routing layer)     │
└──────────────────────────┘         └──────────────────────────┘
```

## Profiles

| Profile | What it starts | When to use |
|---|---|---|
| *(default)* | TimescaleDB + Patroni observer + Consul observer | Always — core observability |
| `haproxy` | HAProxy observer | If your routing layer is HAProxy |
| `failover` | Heartbeat client | When measuring failover timing |
| `charts` | Report generator (runs once, exits) | After a test to generate HTML report |

```bash
# Start core observers
docker compose up -d

# Add HAProxy observer
docker compose --profile haproxy up -d

# Add heartbeat client
docker compose --profile failover up -d

# Generate report
docker compose --profile charts run --rm charts
```

## Failure Injection

The tool observes — it doesn't inject failures. You control the failure:

```bash
# Graceful stop (SIGTERM) — Patroni releases Consul session
ssh admin@leader "sudo systemctl stop patroni"

# Hard crash (SIGKILL) — no cleanup, Consul TTL must expire
ssh admin@leader "sudo kill -9 $(pgrep patroni); sudo kill -9 $(pgrep -o postgres)"

# Planned switchover
ssh admin@leader "patronictl switchover --force --leader current-leader --candidate target-replica"
```

Each scenario produces different timing — graceful stops are fast (1-5s), hard crashes wait for TTL (20-30s), switchovers are near-instantaneous.

## Querying Results

Connect to TimescaleDB directly:

```bash
# Full event timeline
docker exec prb-tsdb psql -U bench -c "
SELECT ts, component, event_type, node, new_value
FROM observer_events
ORDER BY ts DESC LIMIT 20;"

# Failover window (client-perceived downtime)
docker exec prb-tsdb psql -U bench -c "
SELECT * FROM failover_window;"

# Component timing (where was time spent)
docker exec prb-tsdb psql -U bench -c "
SELECT * FROM component_timing
ORDER BY first_detected;"

# Latency distribution before/during/after failover
docker exec prb-tsdb psql -U bench -c "
SELECT * FROM client_latency_buckets;"
```

> **Note:** These examples use `prb-tsdb` (the container name in `tool/docker-compose.yml`). If you're running the benchmark lab with `dashboard/docker-compose.yml`, the container is called `prb-timescaledb` instead.

## Using with HAProxy

If your routing layer is HAProxy, add the HAProxy observer:

```env
# .env
HAPROXY_STATS_URL=http://10.0.1.100:8404/stats;csv
```

```bash
docker compose --profile haproxy up -d
```

The HAProxy observer detects backend UP/DOWN transitions, showing exactly when HAProxy discovered the new primary.

## Using with VIP

If your routing layer is a VIP (vip-manager, keepalived), set the PG_CONNSTRING to the VIP address:

```env
PG_CONNSTRING=host=10.0.1.200 port=5432 dbname=postgres user=postgres password=xxx connect_timeout=5
```

No additional observer is needed — the Patroni and Consul observers capture the VIP migration timing indirectly.

## Using with Consul DNS

If your routing layer is Consul DNS:

```env
PG_CONNSTRING=host=primary.service.consul port=5432 dbname=postgres user=postgres password=xxx connect_timeout=5
```

The Consul observer captures when DNS would update (leader key change).

## Troubleshooting

### "relation failover_window does not exist"

The views were not created on container startup. Fix:

```bash
docker cp tool/timescaledb/schema/003_create_views.sql prb-tsdb:/tmp/
docker exec prb-tsdb psql -U bench -f /tmp/003_create_views.sql
```

### failover_window returns empty results

No failover was detected yet. The heartbeat client auto-registers test runs when it detects the first query failure. Verify the client is running and connected:

```bash
docker compose logs client-failover | tail -10
```

### Observer shows "unreachable" or "Connection refused"

Check network connectivity from the Docker host to your cluster:

```bash
curl http://YOUR_PATRONI_IP:8008/patroni
curl http://YOUR_CONSUL_IP:8500/v1/status/leader
```

### Client shows "PG_CONNSTRING is required"

The `.env` file is missing or not mounted. Verify:

```bash
cat .env | grep PG_CONNSTRING
docker compose config | grep PG_CONNSTRING
```

### Charts: "connection refused" to TimescaleDB

The charts container needs Docker networking to reach TimescaleDB. Run it via docker compose (not standalone docker run):

```bash
docker compose --profile charts run --rm charts db-report --output /results/report.html
```

## Cleanup

```bash
# Stop everything
docker compose --profile failover --profile haproxy down

# Stop and remove data
docker compose --profile failover --profile haproxy down -v
```

## Comparing Multiple Routing Layers

Run the tool once per routing layer, changing COMBINATION_ID and PG_CONNSTRING:

```bash
# Measure through HAProxy
echo "COMBINATION_ID=haproxy" >> .env
echo "PG_CONNSTRING=host=haproxy-ip port=5432 ..." >> .env
docker compose --profile failover up -d
# inject failure, wait for recovery
docker compose --profile failover down

# Measure through VIP
echo "COMBINATION_ID=vip" >> .env
echo "PG_CONNSTRING=host=vip-ip port=5432 ..." >> .env
docker compose --profile failover up -d
# inject failure, wait for recovery
docker compose --profile failover down

# Compare
docker compose --profile charts run --rm charts
```

The chart generator produces a comparison report across all COMBINATION_IDs in TimescaleDB.
