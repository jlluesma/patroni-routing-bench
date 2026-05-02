# Combination 04 — vip-patroni-callback

Patroni binds a floating VIP via an `on_role_change` callback script. No separate vip-manager polling process — Patroni calls `vip_callback.sh` synchronously at the moment of promotion, so the VIP moves without polling lag.

---

## Architecture

```
Client → 172.31.0.100:5432
              │
              ▼
    Patroni node holding the VIP
    (bound via on_role_change callback)
```

- 3 Patroni/PostgreSQL nodes (with `NET_ADMIN` capability)
- 1 Consul server (DCS only)
- 1 Client connecting directly to VIP
- 5 Observer agents (patroni ×1, postgres ×1, consul ×1, vip ×3)

---

## Routing mechanism

1. Patroni's `on_role_change` callback fires synchronously at every role transition.
2. `vip_callback.sh` is called with `<action> <role> <scope>`.
3. On `on_role_change primary`: the script runs `sudo ip addr add 172.31.0.100/24 dev eth0` and `sudo arping -c 3` to announce the VIP. Note: the VIP binds quickly (~0.07s after leader election), but client connections may hit a `connect_timeout` hang if PostgreSQL is still completing promotion when the first connection arrives.
4. On `on_role_change replica` / `on_stop` / `on_restart`: the script runs `sudo ip addr del 172.31.0.100/24 dev eth0`.
5. `post_init` (initial bootstrap): `vip_post_init.sh` binds the VIP immediately when the first primary is initialized.

The callback is synchronous — Patroni waits for it to exit before proceeding. This means the VIP is bound before Patroni finishes its promotion, making the lag essentially zero (no polling interval added on top of promotion time).

### Key difference vs combo 03

| | Combo 03 (vip-manager) | Combo 04 (callback) |
|---|---|---|
| Trigger | Consul KV poll every 1s | Patroni event, synchronous |
| Extra lag | 0–1s polling window | ~0s |
| Process | Separate sidecar container | Script executed by Patroni |

---

## Privileges

The Patroni image (`shared/docker/postgres-patroni`) includes:
- `iproute2` and `iputils-arping` — for `ip addr` and `arping`
- `libcap2-bin` + `setcap cap_net_admin,cap_net_raw+ep` on `/sbin/ip` — allows postgres user to manage interfaces
- `sudo` with a `/etc/sudoers.d/vip` rule: `postgres ALL=(root) NOPASSWD: /sbin/ip, /usr/bin/arping`

Each Patroni container also has `cap_add: [NET_ADMIN]`.

---

## Timing parameters

| Parameter | Value |
|---|---|
| Patroni `loop_wait` | 10s |
| Patroni `ttl` | 30s |
| Client heartbeat interval | 100ms |
| Observer poll interval | 100ms |

---

## ARP cache tuning

The client container runs as root (`user: "0"`) and writes to `/proc/sys` at startup:

```
net.ipv4.neigh.eth0.base_reachable_time_ms = 1000
net.ipv4.neigh.eth0.gc_stale_time          = 1
```

This ensures the client re-ARPs within ~1s of the VIP moving to a new node.

---

## Quick start

```bash
cd dashboard && docker compose up -d          # start shared dashboard
cd dcs/consul/04-vip-patroni-callback && docker compose up -d
docker exec prb-04-node1 patronictl -c /etc/patroni/patroni.yml list
```

Ports:
- Consul UI: http://localhost:8504

---

## Inspect

```bash
# Check which node holds the VIP
docker exec prb-04-node1 ip addr show eth0 | grep 172.31.0.100
docker exec prb-04-node2 ip addr show eth0 | grep 172.31.0.100
docker exec prb-04-node3 ip addr show eth0 | grep 172.31.0.100

# Trigger failover
docker stop prb-04-node1
```

---

## Files

```
config/
├── patroni.yml          Patroni config with callback and post_init hooks
├── consul.json          Consul server config
├── vip_callback.sh      on_role_change / on_stop / on_restart handler
└── vip_post_init.sh     post_init handler (initial bootstrap VIP binding)
```

`vip_callback.sh` is mounted into all three Patroni containers at `/usr/local/bin/vip_callback.sh`. `vip_post_init.sh` handles initial bootstrap: `post_init` receives the connection string as `$1` (not action/role/scope), so a dedicated script is needed rather than reusing `vip_callback.sh`.
