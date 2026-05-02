# runner — Failover Test Runner

Two scripts for running failover experiments against combination stacks.

- `run_failover_test.sh` — single combination, one or more iterations
- `run_batch.sh` — all combinations in sequence, produces a CSV and optional HTML report

---

## run_failover_test.sh

### Quick Reference

```bash
# Default: 5 iterations of hard_stop against combination 06
./runner/run_failover_test.sh

# Specific combination
./runner/run_failover_test.sh \
    --prefix prb-09 \
    --combo-id 09-patroni-callback-haproxy \
    --iterations 5

# Single scenario, repeated
./runner/run_failover_test.sh --scenario hard_kill --iterations 3

# All 3 default scenarios once each (hard_stop, hard_kill, switchover)
./runner/run_failover_test.sh --scenario all

# All 3 scenarios, 3 times each (9 iterations total)
./runner/run_failover_test.sh --scenario all --iterations 3

# With per-iteration charts and final HTML report
./runner/run_failover_test.sh --scenario all --iterations 3 --generate-report
```

### Arguments

| Argument | Default | Description |
|---|---|---|
| `--scenario S` | `hard_stop` | Scenario: `hard_stop`, `hard_kill`, `switchover`, `postgres_crash`, `pause`, `all` |
| `--iterations N` | `5` (single), `1` (all) | Repetitions. With `--scenario all`, defaults to 1 per scenario. |
| `--interval S` | `90` | Seconds to sleep between iterations for cluster stabilisation. |
| `--prefix P` | `prb-06` | Container name prefix (e.g. `prb-06`, `prb-09`). |
| `--combo-id ID` | `06-haproxy-rest-polling` | Written to `test_runs.combination_id`. Must match `COMBINATION_ID` env var. |
| `--combo-dir DIR` | `06-haproxy-rest-polling` | Directory under `dcs/consul/`. Used only with `--fresh-cluster`. |
| `--fresh-cluster` | off | Tear down and redeploy the stack before each iteration. |
| `--clean-db` | off | Truncate event tables before the first iteration. |
| `--generate-report` | off | Generate per-iteration charts and a final HTML report via the charts container. |
| `-h`, `--help` | — | Print usage and exit. |

### Default Scenarios

The `--scenario all` flag runs these three by default:

| Scenario | Method | Expected downtime |
|---|---|---|
| `hard_stop` | `docker stop` (SIGTERM) | ~9s (combo 06 baseline) |
| `hard_kill` | `docker kill -s SIGKILL` | ~30s (TTL expiry) |
| `switchover` | `patronictl switchover` | <1s (planned) |

Additional scenarios available for explicit use (`--scenario postgres_crash`, `--scenario pause`):

- **`postgres_crash`** — kills only the PostgreSQL process inside the container; Patroni stays up.
- **`pause`** — `docker pause` freezes the process; tests TTL-based detection without TCP RST.
- **`network_partition`** — `docker network disconnect`; tests split-brain prevention. Requires manual investigation in this topology.

### Failure Scenarios

**`hard_stop`**: SIGTERM to the container → Patroni shuts down cleanly, releases the DCS leader lock. Tests the standard failover path and HAProxy polling latency.

**`hard_kill`**: SIGKILL → no graceful cleanup. Leader lock expires via TTL (up to 30s). Tests abrupt failure and TTL-based lock expiry.

**`switchover`**: `patronictl switchover --force`. Planned, coordinated role transfer. Patroni waits for the replica to catch up before promoting. If no streaming replica is found, the iteration is marked `SKIPPED`.

### Test Lifecycle (per iteration)

```
1. wait_for_cluster_healthy()          ← abort if not 1 Leader + 2 streaming Replicas
2. find_leader()                       ← determine which node to target
3. restart client container            ← clean per-iteration data window
4. wait_for_steady_state()             ← confirm >20 successes in last 5s
5. INSERT INTO test_runs ...           ← record scenario as failover_type
6. inject_failure(scenario, victim)    ← scenario-specific failure
7. wait_for_recovery(kill_ts)          ← poll TimescaleDB for 5+ consecutive successes
8. capture 5s of post-recovery data   ← clean window end
9. stop client                         ← close data window
10. UPDATE test_runs SET ended_at ...  ← tag events with test_run_id
11. measure_downtime(kill_ts)          ← authoritative from TimescaleDB timestamps
12. recover_node(scenario, victim)     ← scenario-specific cleanup
13. wait_for_cluster_healthy()         ← verify all 3 nodes healthy
14. sleep $INTERVAL                    ← stabilisation buffer
```

### Summary Table

```
╔═══════════╦══════════════╦═══════════════╦══════════════╦════════════════╦═════════╗
║ Iteration ║ Scenario     ║ Leader Killed ║ Downtime (s) ║ Failed Queries ║ Status  ║
╠═══════════╬══════════════╬═══════════════╬══════════════╬════════════════╬═════════╣
║ 1         ║ hard_stop    ║ node1         ║ 9.3          ║ 3              ║ SUCCESS ║
║ 2         ║ hard_kill    ║ node2         ║ 28.7         ║ 9              ║ SUCCESS ║
║ 3         ║ switchover   ║ node3         ║ 0.4          ║ 0              ║ SUCCESS ║
╚═══════════╩══════════════╩═══════════════╩══════════════╩════════════════╩═════════╝
```

**Downtime (s):** first client failure → first success after last failure. Measured from TimescaleDB timestamps.

**Status values:**

| Status | Meaning |
|---|---|
| `SUCCESS` | Recovery within `RECOVERY_TIMEOUT` (default 120s) |
| `TIMEOUT` | No recovery within 120s |
| `SKIPPED` | Failure injection skipped (e.g. no replica for switchover) |
| `CLUSTER_UNHEALTHY` | Cluster not healthy before iteration started |
| `ERROR` | Could not find a leader node |

---

## run_batch.sh

Runs multiple combinations in sequence. Starts/stops each combo stack, runs the test suite, writes results to a shared CSV.

### Quick Reference

```bash
# Run all combos (skip parked 05 and 10), 5 iterations, with reports
./runner/run_batch.sh --skip "05,10" --iterations 3 --generate-report --batch-report

# Run only specific combos
./runner/run_batch.sh --combos "06,07,08,09" --iterations 5

# Run all combos, 1 iteration each scenario
./runner/run_batch.sh --scenario all
```

### Arguments

| Argument | Default | Description |
|---|---|---|
| `--combos "01,06,09"` | all | Only run combinations whose number prefix matches. |
| `--skip "05,10"` | none | Skip combinations whose number prefix matches. |
| `--scenario S` | `all` | Scenario passed to `run_failover_test.sh`. |
| `--iterations N` | `1` | Repetitions per scenario, passed to runner. |
| `--interval S` | `90` | Stabilisation sleep between iterations. |
| `--generate-report` | off | Generate per-combo HTML reports. |
| `--batch-report` | off | Generate cross-combo batch HTML report at the end. |

### Output

Results go to `runner/results/batch_YYYYMMDD_HHMMSS/`:

```
runner/results/batch_20250424_120000/
├── results.csv          ← one row per iteration across all combos
└── batch_report.html    ← cross-combo heatmap, leaderboard, waterfall (if --batch-report)
```

The CSV schema: `combo_dir, prefix, scenario, iteration, leader_killed, downtime_s, failed_queries, status, session_folder`.

### Prerequisites

- Dashboard stack must be running: `cd dashboard && docker compose up -d`
- Run from the repo root

---

## Troubleshooting

**"Cluster unhealthy — skipping iteration"**
The cluster did not have 1 Leader + 2 streaming Replicas. Increase `--interval`, check the node manually:
```bash
docker exec prb-06-node1 patronictl -c /etc/patroni/patroni.yml list
```

**"No recovery within 120s" (TIMEOUT)**
HAProxy may not have promoted the new primary. Check:
- HAProxy stats: http://localhost:8404/stats
- Patroni logs: `docker logs prb-06-node2 2>&1 | tail -20`
- Client events: `docker logs prb-06-client --tail 10`

**"switchover marked SKIPPED"**
No streaming replica found. Cluster must be fully healthy (2 streaming replicas) before switchover works.

---

## TimescaleDB Queries

```bash
PSQL="docker exec prb-timescaledb psql -U bench"

# List recent test runs
$PSQL -c "SELECT id, combination_id, failover_type, started_at FROM test_runs ORDER BY started_at DESC LIMIT 10;"

# Per-run downtime summary
$PSQL -c "SELECT * FROM failover_window ORDER BY first_failure DESC LIMIT 10;"

# Event timeline for a specific run
$PSQL -c "SELECT ts, component, node, event_type, old_value, new_value FROM observer_events WHERE test_run_id = 'YOUR_ID' ORDER BY ts;"

# Cross-combination comparison
$PSQL -c "SELECT * FROM combination_comparison;"
```
