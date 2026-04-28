> **Status: Parked.** This combination is not implemented. It is
> included as an architecture reference for potential future work.
> Do not attempt to run it — the Docker images and configs are
> incomplete.

---

# Combination 05 — BGP Anycast *(parked)*

> **Status: parked.** This combination is defined but not yet implemented. It is excluded from all batch runs by default.

---

## Planned architecture

```
Client → 172.32.0.100:5432  (anycast VIP)
              │
              ▼
        FRR router (proxy-ARP for VIP)
              │
              ▼
    ExaBGP on current primary node
    (announces 172.32.0.100/32 via eBGP)
```

- 3 Patroni/PostgreSQL nodes, each with an ExaBGP sidecar
- 1 FRR (Free Range Routing) container acting as the eBGP peer and ARP proxy
- 1 Client connecting to the anycast VIP
- Observer agents (patroni ×1, postgres ×1, consul ×1, BGP ×3)

---

## Planned routing mechanism

1. On promotion, a Patroni `on_role_change` callback binds `172.32.0.100/32` on the node's loopback (`lo`).
2. ExaBGP detects the loopback prefix and announces it via eBGP to the FRR router.
3. FRR proxy-ARPs for the VIP on the bench network: clients on the subnet resolve the VIP MAC to FRR's MAC, and FRR forwards packets to the node that announced the prefix.
4. On demotion, the callback removes the loopback prefix; ExaBGP withdraws the route.

---

## Why parked

BGP-based anycast routing requires a software router (FRR/BIRD) and eBGP session setup that adds significant infrastructure complexity beyond the other combinations. The mechanism is well-understood in production (used by large-scale PostgreSQL deployments), but setting it up correctly in a Docker Compose environment — especially proxy-ARP for the VIP and eBGP session stability across failovers — requires more work to validate.

This combination will be implemented in a later milestone.

---

## Skip in batch runs

```bash
./runner/run_batch.sh --skip "05,10"
```
