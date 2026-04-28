# Combination 02 — Consul DNS Routing

Consul acts as both the DCS and the routing layer. The client connects to a single DNS name — `primary.bench.service.consul` — which Consul resolves to the IP of whichever node is currently passing the `/primary` health check.

---

## Architecture

```
Client → primary.bench.service.consul:5432
              │
              ▼
        Consul DNS (port 53)
              │
              ▼
    patroni-nodeN (current primary)
```

- 3 Patroni/PostgreSQL nodes
- 1 Consul server (DCS + DNS resolver on port 53)
- 1 Client connecting via DNS name
- 3 Observer agents (patroni ×1, postgres ×1, consul ×1)

---

## Routing mechanism

1. Each Patroni node registers itself in Consul as the `bench` service with a health check against its own `/primary` REST endpoint.
2. The Consul DNS interface runs on port 53 (`NET_BIND_SERVICE` capability).
3. The client container sets `consul-server` as its DNS resolver (`--dns` flag).
4. `primary.bench.service.consul` resolves to whichever registered node has a passing `/primary` check.
5. After failover, once the new primary's Consul health check passes, DNS returns the new IP.

The DNS TTL is set to 0 so clients never cache the record across failovers.

### Key detail: static IPs

Patroni nodes register with **static IPs** (`172.30.2.11`, `.12`, `.13`) rather than hostnames. This ensures Consul DNS returns a routable A record directly. If Consul returned hostnames, Docker's DNS (127.0.0.11) would be needed to resolve them — which breaks in containers that share a network namespace.

---

## Timing parameters

| Parameter | Value |
|---|---|
| Consul health check interval | 5s |
| Consul health check timeout | 3s |
| Patroni `loop_wait` | 10s |
| Patroni `ttl` | 30s |
| Client heartbeat interval | 100ms |
| Observer poll interval | 100ms |

Worst-case routing update: Consul health check interval (5s) after the new primary completes election.

---

## Quick start

```bash
cd dashboard && docker compose up -d          # start shared dashboard
cd dcs/consul/02-consul-dns && docker compose up -d
docker exec prb-02-node1 patronictl -c /etc/patroni/patroni.yml list
```

Ports:
- Consul UI: http://localhost:8502

---

## Inspect

```bash
# Verify DNS resolution
docker exec prb-02-client nslookup primary.bench.service.consul

# Check Consul health checks
docker exec prb-02-consul consul health checks service bench

# Watch Patroni state
docker exec prb-02-node1 patronictl -c /etc/patroni/patroni.yml list

# Trigger failover
docker stop prb-02-node1
```

---

## Files

```
config/
├── patroni.yml          Patroni config (shared by all 3 nodes via env vars)
└── consul.json          Consul server config (DNS on port 53, log_level DEBUG)
```

Patroni nodes use static IPs on the `prb-02-bench` network so that the Consul service registration contains routable addresses rather than hostnames.
