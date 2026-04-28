# Combination Configuration Conventions

When creating a new combination, follow these conventions to ensure consistent
logging and observability across all benchmarks.

## Directory Structure

Each combination lives under `dcs/<dcs-type>/<NN>-<name>/` with:
- `docker-compose.yml` — self-contained stack definition
- `config/patroni.yml` — Patroni configuration
- `config/consul.json` (or etcd equivalent) — DCS configuration
- `config/haproxy.cfg` (or equivalent routing config)
- `README.md` — what this combination measures and how to run it

## PostgreSQL Logging

Include these parameters in `bootstrap.dcs.postgresql.parameters` of your
`patroni.yml`. Reference: `shared/config/patroni-logging.yml`.

```yaml
logging_collector: "on"
log_directory: /var/log/postgresql
log_filename: postgresql.log
log_line_prefix: "%m [%p] %q%u@%d "
log_connections: "on"
log_disconnections: "on"
log_replication_commands: "on"
log_checkpoints: "on"
log_min_messages: info
log_statement: none
log_min_duration_statement: 1000
```

**Why**: `log_connections` and `log_disconnections` show exactly when clients
connect/disconnect during failover. `log_replication_commands` captures WAL
streaming events. `log_checkpoints` shows I/O pressure during promotion.

## Consul DCS

Start from `shared/config/consul-base.json`. Key setting: `"log_level": "DEBUG"`
so Raft election timing and KV operations are visible.

**Why**: Consul Raft logs show leader election latency, which directly impacts
how fast Patroni can acquire the leader lock after a failover.

## HAProxy

Include `option log-health-checks` in the `defaults` section of `haproxy.cfg`.
Reference: `shared/config/haproxy-logging.cfg`.

**Why**: logs every health check state transition (L7OK, L7STS, L4TOUT), so you
can see exactly when HAProxy detected the primary went down and when it detected
the new primary came up.

## Observer Containers

Every combination must include observer containers for each component type
present in the stack. Use `OBSERVER_COMPONENT` env var to select the watcher:
`patroni`, `consul`, `haproxy`, `vip`, `postgres`.

Set `POLL_INTERVAL_MS: "200"` for all observers (200ms polling).

## Client Container

Include one client container with:
- `INTERVAL_MS: "100"` (100ms heartbeat)
- `COMBINATION_ID` set to match the directory name
- Connected to both the bench network and `prb-dashboard` external network

## Docker Networks

Each combination must define:
- An internal `bench` network (named `prb-<NN>-bench`)
- Connect to the external `prb-dashboard` network for TimescaleDB/Prometheus
