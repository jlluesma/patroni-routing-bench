# Combination 03 — vip-manager VIP Polling

vip-manager runs as a sidecar on each Patroni node, polling Consul KV for the current leader key every second. The node whose name matches the key value binds a floating VIP (`172.30.3.100`) to its network interface. The client connects directly to the VIP — no HAProxy, no DNS lookup, no callbacks.

---

## Architecture

```
Client → 172.30.3.100:5432
              │
              ▼
    Patroni node holding the VIP
    (bound via vip-manager sidecar)
```

- 3 Patroni/PostgreSQL nodes
- 1 Consul server (DCS only — no service catalog, no DNS)
- 3 vip-manager sidecars (one per node, sharing the node's network namespace)
- 1 Client connecting directly to VIP
- 6 Observer agents (patroni ×1, postgres ×1, consul ×1, vip ×3)

---

## Routing mechanism

1. Patroni writes the current leader name to Consul KV (`/service/bench/leader`).
2. All three vip-manager instances poll that key every 1 second.
3. The instance whose configured `trigger-value` matches the key value binds `172.30.3.100/24` to `eth0` using `ip addr add`.
4. All other vip-manager instances remove the VIP from their interface.
5. An ARP announcement (gratuitous ARP) flushes ARP caches on the bench network so the client immediately routes to the new holder.

vip-manager shares the Patroni node's network namespace (`network_mode: service:patroni-nodeN`) so that the VIP it binds appears on the Patroni node's interface, not on a separate container interface.

---

## Timing parameters

| Parameter | Value |
|---|---|
| vip-manager poll interval | 1000ms (1s) |
| Patroni `loop_wait` | 10s |
| Patroni `ttl` | 30s |
| Client heartbeat interval | 100ms |
| Observer poll interval | 100ms |

The 1s poll interval adds up to 1s of extra lag after Patroni updates the Consul KV key before the new node binds the VIP. This is the key difference from combo 04 (callback-based, near-zero extra lag).

---

## Custom vip-manager image

The Docker Hub `cybertecpostgresql/vip-manager` image is not reliably maintained for recent releases. This combination builds its own image from the GitHub release tarball:

```
docker/vip-manager/Dockerfile
```

The image downloads `vip-manager_2.6.0_Linux_x86_64.tar.gz` from the GitHub releases page and installs the binary to `/usr/local/bin/`.

---

## ARP cache tuning

The client container runs with `privileged: true` and writes to `/proc/sys` at startup to reduce ARP cache staleness:

```
net.ipv4.neigh.eth0.base_reachable_time_ms = 1000
net.ipv4.neigh.eth0.gc_stale_time          = 1
```

This ensures the client re-ARPs within ~1s of the VIP moving to a new node.

---

## Quick start

```bash
cd dashboard && docker compose up -d          # start shared dashboard
cd dcs/consul/03-vip-manager-poll && docker compose up -d
docker exec prb-03-node1 patronictl -c /etc/patroni/patroni.yml list
```

Ports:
- Consul UI: http://localhost:8503

---

## Inspect

```bash
# Check which node holds the VIP
docker exec prb-03-node1 ip addr show eth0 | grep 172.30.3.100
docker exec prb-03-node2 ip addr show eth0 | grep 172.30.3.100
docker exec prb-03-node3 ip addr show eth0 | grep 172.30.3.100

# Check leader key in Consul
docker exec prb-03-consul consul kv get /service/bench/leader

# Trigger failover
docker stop prb-03-node1
```

---

## Files

```
config/
├── patroni.yml                Patroni config
├── consul.json                Consul server config
├── vip-manager-node1.yml      vip-manager config for node1
├── vip-manager-node2.yml      vip-manager config for node2
└── vip-manager-node3.yml      vip-manager config for node3
docker/
└── vip-manager/
    └── Dockerfile             Builds vip-manager from GitHub release
```

Each `vip-manager-nodeN.yml` contains the `trigger-value` (the node name) and the static IP of the Consul server (`172.30.3.2:8500`). Using the static IP rather than `consul-server` hostname avoids DNS resolution failures when the Patroni container is restarted and Docker DNS breaks for containers sharing its network namespace.
