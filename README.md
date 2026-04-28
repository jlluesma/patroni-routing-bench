# patroni-routing-bench

**Measure PostgreSQL failover timing at every layer of the routing stack — on your own Patroni cluster.**

When a Patroni-managed PostgreSQL primary fails, multiple components react in a cascade: the DCS detects the leader is gone, Patroni promotes a replica, the routing layer discovers the new topology, and the client reconnects. This tool captures timestamped events at every layer and shows you exactly where time is spent.

## What It Measures

The routing layer between your application and PostgreSQL affects failover behavior in four ways. This tool measures each one independently:

| Dimension | What it answers | Status |
|---|---|---|
| **Failover timing** | When the primary dies, how long until my queries work again? Where is that time spent? | ✅ Implemented |
| **Connection establishment** | How long does each routing layer take to establish a new connection? | 🔜 Planned |
| **Steady-state latency** | How much per-query overhead does each routing layer add during normal operation? | 🔜 Planned |
| **Connection storm** | When 500 clients reconnect simultaneously after failover, how does each layer handle it? | 🔜 Planned |

Dimensions 2–4 become especially interesting when **PgBouncer** is added to the stack — the connection pooler changes how each routing layer behaves during failover and under load. See [Future Work](#the-pgbouncer-factor) for details.

---

## Use It on Your Cluster

You don't need to run our benchmark to use this tool. If you already have a Patroni cluster, measure its failover timing directly.

**Requirements:** Docker on one machine + network access to your cluster. No changes to your infrastructure.

```
Your machine (Docker)                Your cluster (untouched)
┌──────────────────────────┐         ┌──────────────────────────┐
│ TimescaleDB              │         │ Patroni node1 (:8008)    │
│ observer-patroni ────────┼── HTTP ─┤ Patroni node2 (:8008)    │
│ observer-consul  ────────┼── HTTP ─┤ Patroni node3 (:8008)    │
│ observer-haproxy ────────┼── HTTP ─┤ Consul server (:8500)    │
│ client-failover  ────────┼── TCP ──┤ HAProxy / VIP / DNS      │
│ chart-generator          │         │ PostgreSQL (:5432)        │
└──────────────────────────┘         └──────────────────────────┘
```

### Quick Start

```bash
cd tool/

# 1. Configure your endpoints
cp .env.example .env
vim .env    # fill in your Patroni IPs, Consul URL, PG connection string

# 2. Start observers + TimescaleDB
docker compose up -d

# 3. Start the heartbeat client
docker compose --profile failover up -d

# 4. Inject failure on your cluster (manual — you control this)
ssh admin@leader "sudo systemctl stop patroni"

# 5. Watch recovery
docker compose logs -f client-failover

# 6. Generate report
docker compose --profile charts run --rm charts
```

The observers run on YOUR machine as Docker containers, connecting remotely to your Patroni REST API, Consul, and PostgreSQL. They capture timestamped events at every layer — DCS detection, PostgreSQL promotion, routing update, client recovery — and store them in a local TimescaleDB.

Works with any routing layer: HAProxy, VIP (vip-manager, keepalived), Consul DNS, libpq multi-host, or any custom setup. If your routing layer is HAProxy, add the HAProxy observer: `docker compose --profile haproxy up -d`.

See [`tool/README.md`](tool/README.md) for full documentation, including how to compare multiple routing layers and query raw event data.

---

## Benchmark Results

We used this tool to benchmark 9 routing strategies in a controlled Docker environment. 81 test runs (9 combinations × 3 scenarios × 3 iterations), all successful.

Median client-perceived downtime (seconds):

| Combination | Category | hard_stop | hard_kill | switchover |
|---|---|---|---|---|
| 01 — libpq multi-host | Client | 1.3s | 25.5s | 1.2s |
| 03 — vip-manager (poll) | VIP | 1.9s | 23.0s | 1.6s |
| 02 — Consul DNS | DNS | 3.9s | 24.0s | 4.5s |
| 07 — consul-template reload | HAProxy | 5.2s | 27.4s | 5.0s |
| 04 — VIP Patroni callback | VIP | 9.7s | 26.0s | 4.1s |
| 06t — HAProxy REST poll (tuned) | HAProxy | 9.1s | 20.7s | 6.6s |
| 09 — Patroni callback → HAProxy | HAProxy | 9.1s | 28.9s | 6.7s |
| 08 — consul-template runtime API | HAProxy | 9.2s | 29.9s | 4.0s |
| 06 — HAProxy REST poll | HAProxy | 9.4s | 25.1s | 5.3s |

> **Note:** Results are from a Docker Desktop / WSL2 environment. VIP combinations include Docker-specific ARP cache overhead not present in bare-metal deployments. Use the tool on your own infrastructure for production-representative numbers.

### Key Findings

- **Graceful failovers (hard_stop, switchover) vary 10×** across routing layers — from 1.2s (libpq) to 9.4s (HAProxy polling).
- **Ungraceful failovers (hard_kill) are dominated by the Consul session TTL** (30s default). All combinations converge to 20–30s regardless of routing layer.
- **The simplest approach (libpq multi-host) is the fastest.** Adding infrastructure (HAProxy, VIP) adds latency for failover detection, not removes it. The value of a proxy is operational (connection pooling, read/write split, observability), not failover speed.
- **consul-template + reload (combo 07) is the fastest HAProxy variant** — event-driven detection vs periodic polling.
- **VIP poll (combo 03) is fastest overall** for graceful failures with dedicated routing infrastructure.

### Where Time Is Spent (Combo 06 Baseline)

During a `hard_stop` failover with HAProxy REST polling:

| Phase | Typical Duration | What Happens |
|---|---|---|
| DCS detection | ~1s | Consul blocking query detects leader key change |
| PostgreSQL promotion | ~0.2–1.3s | New primary accepts connections |
| Routing detection | ~2–6s | HAProxy health checks detect the new primary (`inter 2s × fall 3`) |
| Client recovery | ~1–4s | Application reconnects through the routing layer |
| **Total downtime** | **~9–12s** | End-to-end client-perceived outage |

---

## 9 Routing Combinations

Each combination deploys the same Patroni + PostgreSQL + Consul infrastructure with a different routing layer:

| # | Name | Routing Mechanism | Category |
|---|---|---|---|
| 01 | libpq-multihost | `target_session_attrs=primary` in connection string | Client-side |
| 02 | consul-dns | Consul DNS with health checks on `/primary` endpoint | DNS |
| 03 | vip-manager-poll | vip-manager polls Consul KV, binds floating VIP | VIP |
| 04 | vip-patroni-callback | Patroni `on_role_change` callback runs `ip addr add` | VIP |
| 06 | haproxy-rest-polling | HAProxy polls Patroni REST API (`/primary`) | HAProxy |
| 06t | haproxy-rest-polling-tuned | Same as 06 with `ttl: 20` | HAProxy |
| 07 | consul-template-reload | consul-template watches Consul catalog, reloads HAProxy | HAProxy |
| 08 | consul-template-runtime-api | consul-template uses HAProxy Runtime API (no reload) | HAProxy |
| 09 | patroni-callback-haproxy | Patroni callback flips HAProxy backends via Runtime API | HAProxy |

Each combination has its own README with architecture details and usage instructions.

---

## Failure Scenarios

| Scenario | Mechanism | What It Tests |
|---|---|---|
| `hard_stop` | `docker stop` (SIGTERM) | Graceful shutdown — Patroni releases Consul session, routing layer detects quickly |
| `hard_kill` | `docker kill` (SIGKILL) | Abrupt crash — no cleanup, routing must wait for Consul session TTL expiry |
| `switchover` | `patronictl switchover --force` | Planned operation — orchestrated transition, best-case timing |

---

## Running the Benchmark Lab

To reproduce our results or add new routing combinations:

### 1. Start the dashboard

```bash
git clone https://github.com/jlluesma/patroni-routing-bench.git
cd patroni-routing-bench
cd dashboard && docker compose up -d
```

### 2. Run a single combination

```bash
cd ../dcs/consul/06-haproxy-rest-polling
docker compose up -d --build
sleep 60
docker exec prb-06-node1 patronictl -c /etc/patroni/patroni.yml list
```

### 3. Run a failover test

```bash
cd ~/patroni-routing-bench
./runner/run_failover_test.sh \
    --combo-dir 06-haproxy-rest-polling \
    --combo-id 06-haproxy-rest-polling \
    --prefix prb-06 \
    --scenario all --iterations 3
```

### 4. Run the full batch (all 9 combinations)

```bash
./runner/run_batch.sh --generate-report --batch-report --skip "05,10" --iterations 3
```

Results saved to `runner/results/batch_<timestamp>/`: `results.csv` and interactive `batch_report.html`.

### 5. Tear down

```bash
cd dcs/consul/06-haproxy-rest-polling && docker compose down -v
cd ~/patroni-routing-bench/dashboard && docker compose down -v
```

---

## Observer Agents

Lightweight Python daemons that watch each infrastructure component and emit timestamped state-change events to TimescaleDB.

| Component | Watches | Key Events |
|---|---|---|
| `patroni` | REST API `/patroni` on all 3 nodes | `role_change`, `node_state_change` |
| `consul` | KV leader key (blocking queries) | `leader_key_deleted`, `leader_key_created` |
| `haproxy` | Stats CSV endpoint | `backend_state_change` (UP/DOWN) |
| `postgres` | PostgreSQL log file (tailed) | `pg_promote_requested`, `pg_ready_accept_connections` |
| `vip` | Network interface (`ip addr show`) | `vip_state_change` (bound/unbound) |

Observers use **multi-target mode**: one container watches all nodes of a component type simultaneously via the `WATCHER_TARGETS` environment variable.

---

## Project Structure

```
patroni-routing-bench/
├── tool/                             # MEASUREMENT TOOL — use on your cluster
│   ├── docker-compose.yml            # One compose file, profiles per feature
│   ├── .env.example                  # User fills in their endpoints
│   ├── observers/                    # Observer agent Docker image
│   ├── clients/failover/             # Heartbeat client for failover timing
│   ├── timescaledb/schema/           # Auto-applied on first start
│   ├── charts/                       # Report generation (Plotly)
│   └── results/                      # Generated reports
│
├── dcs/consul/                       # BENCHMARK LAB — 9 routing combinations
│   ├── 01-libpq-multihost/
│   ├── 02-consul-dns/
│   ├── ...
│   └── 09-patroni-callback-haproxy/
│
├── dashboard/                        # Observability stack (for benchmark lab)
│   ├── docker-compose.yml            # TimescaleDB + Prometheus + Grafana
│   └── charts/                       # Chart generation
│
├── runner/                           # Benchmark automation
│   ├── run_failover_test.sh          # Single-combo test driver
│   └── run_batch.sh                  # Multi-combo batch orchestrator
│
├── shared/docker/                    # Shared Docker images
│   ├── postgres-patroni/             # PostgreSQL 18 + Patroni base image
│   ├── client/                       # Heartbeat client
│   └── observer/                     # Observer agent
│
└── observer/schema/                  # TimescaleDB schema (canonical)
```

---

## Configuration Reference

### Patroni DCS Timing

```yaml
bootstrap:
  dcs:
    ttl: 30         # Leader lock TTL — time before dead leader's lock expires
    loop_wait: 10   # HA loop interval — how often replicas check DCS state
    retry_timeout: 10
```

These settings directly affect ungraceful failover timing. `ttl: 30` means a hard_kill waits up to 30s before replicas can acquire the leader lock.

### HAProxy Health Check (Combos 06–09)

```
default-server inter 2s fall 3 rise 2
```

- `inter 2s` — check every 2 seconds
- `fall 3` — 3 consecutive failures to mark DOWN (worst-case detection: 6s)
- `rise 2` — 2 consecutive passes to mark UP

---

## Grafana Dashboards

| Dashboard | Purpose |
|---|---|
| Failover Timeline | Swimlane view of all components during a failover — the main analysis tool |
| Combination Comparison | Side-by-side downtime across routing strategies |

Access at http://localhost:3000 (admin/admin) when running the benchmark lab.

---

## Known Limitations

- **Docker benchmark environment** — results reflect Docker networking behavior, not bare-metal or cloud. Use the [measurement tool](#use-it-on-your-cluster) on your own infrastructure for production-representative numbers.
- **Single-node Consul** — production deployments use 3+ Consul servers. Single-node Consul has no Raft consensus overhead.
- **No concurrent load** — the heartbeat client sends sequential queries. Production failovers under heavy load may behave differently.

---

## Future Work

### The PgBouncer Factor

The current benchmark tests routing layers in isolation: one client, direct connections, no connection pooling. In production, **PgBouncer sits between the application and the routing layer**, and this changes the dynamics fundamentally:

- **Connection establishment time** — how fast does PgBouncer re-establish its backend pool after a failover through each routing layer?
- **Steady-state latency overhead** — Client → PgBouncer → HAProxy → PostgreSQL is three hops. Client → PgBouncer → VIP → PostgreSQL is two. What's the per-hop cost?
- **Connection storm behavior** — PgBouncer absorbs the client storm, but must reconnect to PostgreSQL through the routing layer. Pool explosion risk (`num_pools × pool_size`) varies by routing strategy.
- **Pool rebuild timing** — after a VIP migration, all PgBouncer backend connections break simultaneously. With HAProxy, PgBouncer connects to a stable endpoint. Each routing layer creates a different pool rebuild profile.

Adding PgBouncer to each combination would test the routing layer as part of a realistic production stack — the natural next phase of this project.

### Additional Plans
- **etcd DCS support** — parallel routing strategies for DCS comparison
- **Cloud deployment** — Terraform + Ansible for AWS/GCP with real infrastructure
- **Network partition scenario** — reliable implementation using `tc netem`
- **Docker Hub images** — pre-built observer and client images for zero-build setup

---

## Troubleshooting

**Docker won't start (WSL2):**
```bash
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo service docker start
```

**Cluster not healthy after failover:**
```bash
docker start prb-06-node2
sleep 30
docker exec prb-06-node1 patronictl -c /etc/patroni/patroni.yml list
```

**Observer events missing:** `docker ps | grep obs` — verify observer containers are running.

**Runner reports TIMEOUT:** Verify cluster is fully healthy (1 Leader + 2 streaming Replicas) before starting a test.

---

## Related Articles

1. [Patroni + PostgreSQL Routing Deep Dive: Guide to Client Connections](https://medium.com/@jlluesma85/patroni-postgresql-routing-deep-dive-guide-to-client-connections-73d3b9168173)
2. [Measuring What Nobody Measures: Empirical Failover Timing in Patroni](https://medium.com/@jlluesma85/measuring-what-nobody-measures-empirical-failover-timing-in-patroni-with-a-custom-observability-022e7d9a589d)

---

## Contributing

Contributions welcome:

- **New routing combinations** — add a strategy we haven't covered
- **New measurement dimensions** — implement connection establishment, latency, or storm clients
- **Observer improvements** — new component watchers or better detection precision
- **Cloud providers** — Terraform/Ansible configs for AWS/GCP deployment
- **etcd support** — the DCS layer is designed to be swappable

---

## Prerequisites

- Docker and Docker Compose v2
- For the measurement tool: Docker on one machine + network access to your cluster
- For the benchmark lab: 8GB RAM minimum (14+ containers running simultaneously)

---

## License

MIT

---

*Built with PostgreSQL 18, Patroni, Consul, TimescaleDB, Grafana, and Plotly.*
