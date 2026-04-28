# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

A benchmarking framework for measuring PostgreSQL failover detection latency across different Patroni routing strategies. Each routing strategy is called a "combination" and runs as an isolated Docker Compose stack. All combinations share a single dashboard stack (TimescaleDB + Prometheus + Grafana) that persists data across test runs.

## Running the Stacks

```bash
# Start dashboard first (once, kept running across all test runs)
cd dashboard && docker compose up -d

# Start a specific combination
cd dcs/consul/06-haproxy-rest-polling && docker compose up -d

# Check cluster health
docker exec prb-06-node1 patronictl list

# Trigger a failover
docker stop prb-06-node1

# Tear down a combination (dashboard stays up)
docker compose down -v
```

Access:
- Grafana: http://localhost:3000 (admin/admin)
- Prometheus: http://localhost:9090
- TimescaleDB: localhost:5433 (user: bench, pass: bench, db: bench)
- HAProxy stats: http://localhost:8404/stats
- Consul UI: http://localhost:8500

## Architecture

### Dashboard stack (`dashboard/`)
Runs independently and is shared across all combinations. Contains:
- **TimescaleDB**: stores failover timing events (`observer_events`, `client_events`, `test_runs` tables)
- **Prometheus**: scrapes exporters from whichever combination is running
- **Grafana**: pre-provisioned dashboards, auto-loaded from `dashboard/grafana/dashboards/`

Schema migrations in `observer/schema/` are mounted into TimescaleDB and run in order (001_, 002_, 003_) on first start.

### Combination stack (`dcs/<dcs-type>/<NN>-<name>/`)
Each combination is self-contained with:
- 3 Patroni/PostgreSQL nodes (1 primary + 2 replicas)
- 1 Consul server (DCS)
- 1 HAProxy (or other router, depending on combination)
- 1 Client heartbeat container
- Multiple Observer agent containers (one per component type)
- Prometheus exporters (node_exporter, postgres_exporter, consul_exporter)

Two Docker networks per combination:
- `prb-<NN>-bench`: internal communication between components
- `prb-dashboard` (external): shared with the dashboard stack for metrics/events

### Shared Docker images (`shared/docker/`)
Built locally and reused across combinations:
- **`postgres-patroni/`**: PostgreSQL + Patroni image, configured via `patroni.yml` and env vars
- **`client/`**: Python heartbeat client (`heartbeat.py`) — fires INSERTs every 100ms and records success/failure to TimescaleDB via `reporter.py`
- **`observer/`**: Python observer daemon — polls component REST APIs every 200ms, detects state changes, emits events to TimescaleDB

### Observer agent (`shared/docker/observer/`)
The observer is a pluggable watcher system:
- `core/agent.py`: entry point — reads `OBSERVER_COMPONENT` env var, dynamically loads the right watcher
- `core/watcher.py`: `BaseWatcher` ABC with `setup()`, `poll()`, `teardown()` lifecycle
- `core/emitter.py`: batches and flushes state-change events to TimescaleDB
- `watchers/`: one file per component — `patroni_watcher.py`, `consul_watcher.py`, `haproxy_watcher.py`, `vip_watcher.py`, `postgres_watcher.py`

To add a new watcher type: implement `BaseWatcher`, add it to `WATCHER_REGISTRY` in `agent.py`.

## Adding a New Combination

1. Create `dcs/<dcs-type>/<NN>-<name>/` directory
2. Copy and adapt `docker-compose.yml` from combination 06 (the baseline)
3. Add a `config/` directory with `patroni.yml`, `consul.json`, and whatever router config applies
4. Set `COMBINATION_ID` env var in the client and observer containers to a unique string matching the directory name
5. Combination 06 is the baseline — all others are compared against it

## Key Timing Parameters (combination 06 baseline)

| Parameter | Value |
|---|---|
| HAProxy check interval | 2s (`inter 2s`) |
| HAProxy fall threshold | 3 consecutive failures |
| HAProxy rise threshold | 2 consecutive successes |
| Patroni `loop_wait` | 10s |
| Patroni `ttl` | 30s |
| Client heartbeat interval | 100ms |
| Observer poll interval | 200ms |

Worst-case failover detection: `inter × fall` = 6s (HAProxy) + `loop_wait + ttl` (Patroni leader election).

## Logging & Observability

All components log verbosely by default to support failover timeline analysis.
Shared config templates live in `shared/config/`. See `docs/combinations.md`
for the full conventions.

- **PostgreSQL**: `log_connections`, `log_disconnections`, `log_replication_commands`, `log_checkpoints` are all ON. Captures connection lifecycle and replication events during failover.
- **Consul**: `log_level: DEBUG` to expose Raft election timing and KV operations.
- **HAProxy**: `option log-health-checks` logs every health check state transition (L7OK, L7STS, L4TOUT).

Inspect component logs during/after a failover:
```bash
docker logs prb-06-node1 2>&1 | grep -iE "promote|recovery|connection"
docker logs prb-06-consul 2>&1 | grep -i raft
docker logs prb-06-haproxy 2>&1 | tail -30
```

## TimescaleDB Schema

Three core tables (defined in `observer/schema/`):
- `test_runs`: metadata per test run (combination, failover type, config)
- `observer_events`: server-side state changes (`component`, `node`, `event_type`, `old_value`, `new_value`)
- `client_events`: per-query heartbeat results (`success`, `latency_us`, `error`)
