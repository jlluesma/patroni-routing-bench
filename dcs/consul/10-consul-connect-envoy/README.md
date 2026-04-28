> **Status: Parked.** This combination is not implemented. It is
> included as an architecture reference for potential future work.
> Do not attempt to run it — the Docker images and configs are
> incomplete.

---

# Combination 10 — Consul Connect + Envoy *(parked)*

> **Status: parked.** This combination is defined but not yet implemented. It is excluded from all batch runs by default.

---

## Planned architecture

```
Client (with Envoy sidecar)
    │  mTLS via Consul Connect
    ▼
Envoy sidecar on Patroni primary
    │
    ▼
PostgreSQL primary
```

- 3 Patroni/PostgreSQL nodes, each with an Envoy sidecar proxy
- 1 Consul server (service mesh control plane — Connect CA, intentions)
- 1 Client with its own Envoy sidecar
- Observer agents (patroni ×1, postgres ×1, consul ×1)

---

## Planned routing mechanism

Consul Connect is a service mesh built into Consul. Unlike all other combinations in this project, there is no HAProxy, no VIP, and no template rendering:

1. Consul manages a Certificate Authority (CA) and issues short-lived mTLS certificates to all service instances.
2. Each Patroni node registers with Consul Connect enabled. The service catalog reflects health check state.
3. The client's Envoy sidecar resolves the `bench` service via the Consul xDS API (Envoy's control plane protocol) and routes traffic only to the currently healthy (primary) endpoint.
4. When a failover occurs, Consul updates the xDS endpoint discovery response. Envoy picks up the change and reroutes — no DNS TTL, no polling interval.

The key difference from all other combinations: routing is enforced at the sidecar layer with mTLS, not at a shared load balancer or IP layer.

---

## Why parked

Consul Connect in Docker Compose requires careful network configuration:

- Envoy sidecar containers must share the network namespace with their service container (`network_mode: service:...`)
- Consul Connect's `proxy` configuration must match container IPs and ports
- mTLS certificate bootstrapping requires Consul agent mode (not just server mode)
- PostgreSQL clients must connect to the local Envoy port, not directly to PostgreSQL

The setup is non-trivial to validate end-to-end, and failover behaviour under mTLS connection draining is qualitatively different from the other combinations (it's a stretch-goal comparison, not a direct baseline competitor). Implementation is deferred until the other combinations are fully benchmarked.

---

## Skip in batch runs

```bash
./runner/run_batch.sh --skip "05,10"
```
