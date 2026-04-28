# Combination 09 — Patroni Callback → HAProxy Runtime API

Patroni fires a callback synchronously on every role change. The callback opens a TCP connection directly to HAProxy's Runtime API port and sends a `set server ... state ready/maint` command. No consul-template, no polling loop, no config reload — the HAProxy backend state changes at the exact moment Patroni finishes promotion.

---

## Architecture

```
Client → HAProxy :5000
              │
              ▼  (state set via Runtime API at promotion time)
    Patroni primary ──→ haproxy_callback.sh ──→ HAProxy :9999 (Runtime API)
```

- 3 Patroni/PostgreSQL nodes
- 1 Consul server (DCS only — no service catalog, no consul-template)
- 1 HAProxy (static config, Runtime API on TCP port 9999)
- 1 Client connecting via HAProxy port 5000
- 4 Observer agents (patroni ×1, postgres ×1, consul ×1, haproxy ×1)

---

## Routing mechanism

1. HAProxy starts with a static config. All three nodes are listed in `primary_backend` in `state maint`.
2. Patroni's `on_role_change` callback fires synchronously at every role transition.
3. `haproxy_callback.sh` is called with `<action> <role> <scope>`.
4. On `on_role_change primary`: the script connects to `haproxy:9999` and sends:
   ```
   set server primary_backend/<this-node> state ready
   set server primary_backend/<other-nodes> state maint
   ```
5. On `on_role_change replica`: the script sends `state maint` for this node.
6. HAProxy's backend state changes immediately — the new primary starts receiving traffic before Patroni's promotion function returns.

The callback uses Python 3's `socket` module (available in the Patroni image) because `curl` cannot speak the HAProxy Runtime API wire protocol.

### Key difference vs combo 08 (consul-template Runtime API)

| | Combo 08 | Combo 09 |
|---|---|---|
| Update trigger | Consul catalog change (polled by consul-template) | Patroni event, synchronous callback |
| Intermediary | consul-template + socat | Python socket in callback script |
| Extra lag | Consul check interval (5s) | ~0s (synchronous with promotion) |
| Runtime API transport | Unix socket | TCP port 9999 |

### Key difference vs combo 04 (VIP callback)

| | Combo 04 | Combo 09 |
|---|---|---|
| Callback target | Network interface (VIP bind) | HAProxy backend state |
| Client routing | Direct to VIP | Via HAProxy load balancer |

---

## Timing parameters

| Parameter | Value |
|---|---|
| Patroni `loop_wait` | 10s |
| Patroni `ttl` | 30s |
| Client heartbeat interval | 100ms |
| Observer poll interval | 100ms |

The callback fires synchronously, so HAProxy state update adds no measurable lag beyond the Python socket call (~1ms).

---

## Quick start

```bash
cd dashboard && docker compose up -d          # start shared dashboard
cd dcs/consul/09-patroni-callback-haproxy && docker compose up -d
docker exec prb-09-node1 patronictl -c /etc/patroni/patroni.yml list
```

Ports:
- HAProxy stats: http://localhost:8408/stats
- Consul UI: http://localhost:8507

---

## Inspect

```bash
# Check HAProxy backend states via Runtime API
echo "show servers state" | docker exec -i prb-09-haproxy socat - TCP:localhost:9999

# Patroni state
docker exec prb-09-node1 patronictl -c /etc/patroni/patroni.yml list

# Callback execution logs (in Patroni node logs)
docker logs prb-09-node1 2>&1 | grep -i callback

# Trigger failover
docker stop prb-09-node1
```

---

## Files

```
config/
├── patroni.yml             Patroni config with on_role_change callback
├── consul.json             Consul server config
├── haproxy.cfg             Static HAProxy config (all servers in maint initially)
└── haproxy_callback.sh     Callback script: opens TCP socket, sends Runtime API command
```

`haproxy_callback.sh` is mounted into all three Patroni containers at `/usr/local/bin/haproxy_callback.sh`. The script also sets all other nodes to `state maint` on promotion, ensuring only one server is active at a time regardless of previous state.
