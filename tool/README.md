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

# 3. Verify observers are running
docker compose logs observer-patroni | tail -5
docker compose logs observer-consul | tail -5

# 4. Start the heartbeat client
docker compose --profile failover up -d

# 5. Watch the heartbeat (should show 100% success)
docker compose logs -f client-failover

# 6. Inject a failure on your cluster (in another terminal)
ssh admin@leader "sudo systemctl stop patroni"

# 7. Watch recovery in the heartbeat output
docker compose logs -f client-failover

# 8. After recovery — generate report
docker compose --profile charts run --rm charts

# 9. View results
ls results/
```

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
