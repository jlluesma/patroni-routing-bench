# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

A benchmarking and measurement tool for PostgreSQL failover timing across Patroni routing strategies.

Two faces:
1. **Measurement tool** (`tool/`) — Docker images that connect to any existing Patroni cluster and measure failover timing at every layer of the routing stack.
2. **Benchmark lab** (`dcs/consul/`) — 9 routing combinations deployed as Docker Compose stacks for automated failover testing.

## Key Directories

```
tool/                          # THE TOOL — canonical source for all images
├── observers/                 # Observer agent (one image, multiple watcher types)
│   ├── core/agent.py          # Entry point — reads OBSERVER_COMPONENT, loads watcher
│   ├── core/watcher.py        # BaseWatcher ABC: setup(), poll(), teardown()
│   ├── core/emitter.py        # Batches events, flushes to TimescaleDB
│   └── watchers/              # patroni, consul, haproxy, postgres_sql, vip
├── clients/failover/          # Heartbeat client for failover timing
├── timescaledb/schema/        # Schema SQL (auto-applied on first start)
├── charts/                    # Chart generation (Plotly)
├── docker-compose.yml         # For external users (measure their own cluster)
└── .env.example               # User fills in their endpoints

dcs/consul/                    # 9 routing combinations (benchmark lab)
├── 01-libpq-multihost/
├── 02-consul-dns/
├── ...
└── 09-patroni-callback-haproxy/

dashboard/                     # TimescaleDB + Prometheus + Grafana stack
runner/                        # Batch test automation
shared/docker/postgres-patroni/  # PostgreSQL 18 + Patroni base image
```

## Running the Stacks

```bash
# Start dashboard first (once, kept running across all test runs)
cd dashboard && docker compose up -d

# Start a specific combination
cd dcs/consul/06-haproxy-rest-polling && docker compose up -d --build

# Check cluster health
docker exec prb-06-node1 patronictl -c /etc/patroni/patroni.yml list

# Run a failover test
cd ~/patroni-routing-bench
./runner/run_failover_test.sh \
    --combo-dir 06-haproxy-rest-polling \
    --combo-id 06-haproxy-rest-polling \
    --prefix prb-06 \
    --scenario hard_stop --iterations 3

# Run all 9 combinations
./runner/run_batch.sh --skip "05,10" --iterations 3

# Tear down a combination (dashboard stays up)
cd dcs/consul/06-haproxy-rest-polling && docker compose down -v
```

Access:
- Grafana: http://localhost:3000 (admin/admin)
- Prometheus: http://localhost:9090
- TimescaleDB: localhost:5433 (user: bench, pass: bench, db: bench)
- HAProxy stats: http://localhost:8404/stats
- Consul UI: http://localhost:8500

## Architecture

### tool/ (canonical source)
All observer and client Docker images build from `tool/`. Combination
docker-compose files reference `tool/` via relative paths:
```yaml
observer-patroni:
  build:
    context: ../../../tool/observers
client:
  build:
    context: ../../../tool/clients/failover
```

### Observer agent (`tool/observers/`)
Pluggable watcher system:
- `core/agent.py`: reads `OBSERVER_COMPONENT` env var, dynamically loads watcher
- `core/watcher.py`: `BaseWatcher` ABC with `setup()`, `poll()`, `teardown()`
- `core/emitter.py`: batches and flushes state-change events to TimescaleDB
- `watchers/`: one file per component type

Watcher registry:
```python
WATCHER_REGISTRY = {
    "patroni": "watchers.patroni_watcher.PatroniWatcher",
    "consul": "watchers.consul_watcher.ConsulWatcher",
    "haproxy": "watchers.haproxy_watcher.HAProxyWatcher",
    "vip": "watchers.vip_watcher.VIPWatcher",
    "postgres": "watchers.postgres_sql_watcher.PostgresSQLWatcher",
}
```

The PostgreSQL watcher uses SQL-based detection (`pg_is_in_recovery()`,
`pg_control_checkpoint()`) — connects remotely via TCP, no log file needed.
Multi-target mode (patroni and postgres): `WATCHER_TARGETS` env var spawns
one watcher thread per target node.

### Dashboard stack (`dashboard/`)
Shared across all combinations:
- **TimescaleDB**: stores events (schema from `tool/timescaledb/schema/`)
- **Prometheus**: scrapes exporters
- **Grafana**: pre-provisioned dashboards

### Combination stack (`dcs/<dcs-type>/<NN>-<name>/`)
Each combination is self-contained with:
- 3 Patroni/PostgreSQL nodes
- 1 Consul server
- 1 Router (HAProxy, VIP, DNS, or libpq)
- 1 Client heartbeat container (builds from `tool/clients/failover`)
- Observer containers (build from `tool/observers`)

## Adding a New Combination

1. Create `dcs/<dcs-type>/<NN>-<name>/` directory
2. Copy `docker-compose.yml` from combination 06 (the baseline)
3. Add `config/` with `patroni.yml`, `consul.json`, and router config
4. Set `COMBINATION_ID` in client and observer containers
5. Ensure observer/client builds reference `tool/`:
   - `context: ../../../tool/observers`
   - `context: ../../../tool/clients/failover`
6. See `docs/combinations.md` for full conventions

## Key Timing Parameters

| Parameter | Value |
|---|---|
| HAProxy check interval | 2s (`inter 2s`) |
| HAProxy fall threshold | 3 consecutive failures |
| HAProxy rise threshold | 2 consecutive successes |
| Patroni `loop_wait` | 10s |
| Patroni `ttl` | 30s |
| Client heartbeat interval | 100ms |
| Observer poll interval | 100ms |

## TimescaleDB Schema

Three core tables (defined in `tool/timescaledb/schema/`):
- `test_runs`: metadata per test run (combination, failover type, config)
- `observer_events`: server-side state changes (`component`, `node`, `event_type`, `old_value`, `new_value`)
- `client_events`: per-query heartbeat results (`success`, `latency_us`, `error`)

Key views:
- `failover_window`: client-perceived downtime per test run
- `component_timing`: per-component detection timing
- `failover_timeline`: merged server + client event stream
