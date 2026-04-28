# Combination 01 — libpq Multi-Host (Zero Infrastructure)

**The zero-infrastructure baseline.** No HAProxy, no VIP, no routing layer.
The client connects directly to all three PostgreSQL nodes using libpq's
built-in multi-host failover.

## How it works

The client connection string is:

```
host=patroni-node1,patroni-node2,patroni-node3
port=5432
target_session_attrs=read-write
connect_timeout=5
```

On each connection attempt libpq tries the hosts in order. With
`target_session_attrs=read-write` it keeps trying until it lands on a node
that accepts writes (the Patroni primary). If the first host is a replica or
is unreachable, libpq moves to the next host in the list.

**There is no persistent connection** — every 100 ms the heartbeat client
opens a new connection, runs `INSERT`, and closes it. Recovery is
detected the moment libpq successfully opens a read-write connection to
the new primary.

## What we measure

| Signal | Source |
|--------|--------|
| Client downtime | `client_events` — consecutive failures from first fail to first success |
| Patroni role change | `observer_events` — `role_change` on all 3 nodes |
| DCS leader key | `observer_events` — `leader_key_deleted` / `leader_key_created` |
| PostgreSQL promotion | `observer_events` — `pg_promote_requested` / `pg_ready_accept_connections` |

**There is no routing-layer signal** — the HAProxy lane visible in combo 06
is absent here. Recovery is purely client-side: libpq retry succeeds as
soon as the new primary is ready to accept connections.

## Expected behavior during failover

1. Leader is stopped. Consul detects the TTL expiry (~30 s `ttl`).
2. Patroni elects a new primary via `loop_wait` (10 s) + Consul lock.
3. **Every** libpq connection attempt during steps 1–2 fails because
   no node accepts read-write connections. The client accumulates
   sequential `connect_timeout` (5 s) × number-of-hosts delays per
   retry cycle in the worst case.
4. Once the new primary is promoted, the next libpq attempt that lands
   on it succeeds immediately.

### Why downtime is typically higher than combo 06

- libpq tries hosts **sequentially** — if the dead node is first in the
  list, each attempt wastes up to `connect_timeout` seconds on it.
- There is no health check pre-filtering: the client always tries all
  hosts on every new connection.
- Combo 06 (HAProxy) pre-filters unhealthy backends and routes straight
  to the live primary once it passes health checks.

## Prerequisites

Start the shared dashboard stack first:

```bash
cd ../../../dashboard && docker compose up -d
```

## Usage

```bash
# Start combination 01
cd dcs/consul/01-libpq-multihost
docker compose up -d

# Check cluster health
docker exec prb-01-node1 patronictl -c /etc/patroni/patroni.yml list

# Trigger a failover
docker stop prb-01-node1

# Watch client events in real time
docker logs -f prb-01-client

# Tear down (dashboard stack stays up)
docker compose down -v
```

## Ports

| Service | Host port |
|---------|-----------|
| Consul UI | http://localhost:8501 |

PostgreSQL nodes are not exposed on host ports — the client reaches them
over the internal `prb-01-bench` network.

## Comparison with combo 06

| Metric | 01 libpq multi-host | 06 HAProxy REST polling |
|--------|---------------------|-------------------------|
| Routing infrastructure | None | HAProxy |
| Routing detection latency | N/A | `inter × fall` ≈ 6 s |
| Client retry mechanism | Sequential host scan | Single endpoint |
| Worst-case per-retry penalty | `connect_timeout × 3` | `connect_timeout × 1` |
| Operational complexity | Minimal | Requires HAProxy config |

## Common issues

**Client fails to connect on startup**: the Patroni primary may not be
elected yet. The client retries continuously; wait 30–60 s for the
cluster to initialise.

**All connections hit `connect_timeout`**: the dead node is at the front
of the host list. This is expected behaviour and is part of what the
benchmark measures. Reorder the host list to explore the impact.

**Consul UI not reachable**: port 8501 is used (instead of 8500) so
this combination can run alongside combo 06 without a port conflict.
