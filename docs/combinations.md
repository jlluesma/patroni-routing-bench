# Combination Configuration Conventions

When creating a new combination, follow these conventions to ensure
consistent logging and observability across all benchmarks.

## Directory Structure

Each combination lives under `dcs/<dcs-type>/<NN>-<name>/` with:

- `docker-compose.yml` — self-contained stack definition
- `config/patroni.yml` — Patroni configuration
- `config/consul.json` — DCS configuration
- `config/haproxy.cfg` (if using HAProxy)
- `README.md` — what this combination measures and how to run it

## Building from tool/

All observer and client images build from the canonical `tool/` directory.
Do NOT duplicate observer or client code inside a combination directory.

```yaml
# Observer containers reference tool/observers
observer-patroni:
  build:
    context: ../../../tool/observers
  environment:
    OBSERVER_COMPONENT: patroni
    ...

# Client containers reference tool/clients/failover
client:
  build:
    context: ../../../tool/clients/failover
  environment:
    PG_CONNSTRING: ...
    INTERVAL_MS: "100"
    ...
```

## PostgreSQL Logging

Include these parameters in `bootstrap.dcs.postgresql.parameters`
of your `patroni.yml`:

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

`log_connections` and `log_disconnections` show exactly when clients
connect/disconnect during failover. `log_replication_commands` captures
WAL streaming events. `log_checkpoints` shows I/O pressure during
promotion.

## Consul DCS

Key setting: `"log_level": "DEBUG"` so Raft election timing and KV
operations are visible. Consul Raft logs show leader election latency,
which directly impacts how fast Patroni can acquire the leader lock
after a failover.

## HAProxy

Include `option log-health-checks` in the `defaults` section of
`haproxy.cfg`. This logs every health check state transition
(L7OK, L7STS, L4TOUT), showing exactly when HAProxy detected the
primary went down and when it detected the new primary came up.

## Observer Containers

Every combination must include observer containers for each component
type present in the stack:

| Component | `OBSERVER_COMPONENT` | What it watches |
|---|---|---|
| Patroni | `patroni` | REST API on each node (multi-target via `WATCHER_TARGETS`) |
| Consul | `consul` | KV leader key via blocking queries |
| HAProxy | `haproxy` | Stats CSV endpoint |
| PostgreSQL | `postgres` | Direct SQL connection to each node (multi-target via `WATCHER_TARGETS`) |
| VIP | `vip` | Network interface IP binding |

The PostgreSQL observer connects via SQL (`pg_is_in_recovery()`,
`pg_control_checkpoint()`) — no log file access needed.

Multi-target mode for Patroni and PostgreSQL observers:

```yaml
observer-patroni:
  environment:
    OBSERVER_COMPONENT: patroni
    WATCHER_TARGETS: "node1:http://patroni-node1:8008,node2:http://patroni-node2:8008,node3:http://patroni-node3:8008"
    POLL_INTERVAL_MS: "100"

observer-postgres:
  environment:
    OBSERVER_COMPONENT: postgres
    WATCHER_TARGETS: "node1:host=patroni-node1 port=5432 dbname=postgres user=postgres password=postgres,node2:host=patroni-node2 port=5432 dbname=postgres user=postgres password=postgres,node3:host=patroni-node3 port=5432 dbname=postgres user=postgres password=postgres"
    POLL_INTERVAL_MS: "100"
```

Set `POLL_INTERVAL_MS: "100"` for all observers (100ms polling).

## Client Container

Include one client container with:

- `INTERVAL_MS: "100"` (100ms heartbeat)
- `COMBINATION_ID` set to match the directory name
- Connected to both the bench network and `prb-dashboard` external network

## Docker Networks

Each combination must define:

- An internal `bench` network (named `prb-<NN>-bench`)
- Connect to the external `prb-dashboard` network for TimescaleDB

## TimescaleDB Schema

The schema is auto-applied by the dashboard stack from
`tool/timescaledb/schema/`. Do NOT include schema files
inside a combination directory.
