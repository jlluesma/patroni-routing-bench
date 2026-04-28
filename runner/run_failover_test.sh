#!/usr/bin/env bash
# patroni-routing-bench — automated failover test driver
#
# Usage: runner/run_failover_test.sh [OPTIONS]
#
# Options:
#   --scenario S            Failure scenario: hard_stop|hard_kill|network_partition|
#                           postgres_crash|switchover|pause|all  (default: hard_stop)
#                           'all' runs all 6 scenarios once each (or N times each
#                           when combined with --iterations).
#   --iterations N          Times to repeat the scenario (default: 5 for single
#                           scenarios, 1 per scenario when --scenario all)
#   --interval S            Minimum stabilisation sleep after recovery before the
#                           next iteration, in seconds (default: 90)
#   --prefix P              Container prefix, e.g. prb-06 (default: prb-06)
#   --combo-id ID           Combination identifier written to test_runs
#                           (default: 06-haproxy-rest-polling)
#   --combo-dir DIR         Combination directory name under dcs/consul/, used to
#                           locate the docker-compose.yml when --fresh-cluster is
#                           set (default: 06-haproxy-rest-polling)
#   --fresh-cluster         Tear down and recreate the combination stack before
#                           each iteration. The dashboard stack (TimescaleDB,
#                           Grafana, Prometheus) is left running. (default: off)
#   --clean-db              Truncate observer_events, client_events, and test_runs
#                           before the first iteration
#   --skip-client-restart   Keep client running continuously (legacy behaviour,
#                           useful for debugging)
#   --generate-report       After all iterations, generate a self-contained HTML
#                           report via dashboard/charts/generate_report.py and
#                           save it to runner/results/<combo-id>/report_<date>.html
#   -h, --help              Show this help
set -eo pipefail

# ---------------------------------------------------------------------------
# Configuration defaults
# ---------------------------------------------------------------------------
SCENARIO="hard_stop"
ITERATIONS=5
ITERATIONS_SET=false
INTERVAL=90
COMBO_PREFIX="prb-06"
COMBINATION_ID="06-haproxy-rest-polling"
TSDB_CONTAINER="prb-timescaledb"
PATRONI_CONF="/etc/patroni/patroni.yml"
RECOVERY_TIMEOUT=120
CLEAN_DB=false
SKIP_CLIENT_RESTART=false
FRESH_CLUSTER=false
COMBO_DIR="06-haproxy-rest-polling"
GENERATE_REPORT=false

# All individually-addressable scenarios (includes network_partition for explicit use)
VALID_SCENARIOS=(hard_stop hard_kill network_partition postgres_crash switchover pause)

# Scenarios run by --scenario all.
# network_partition requires further investigation — docker network
# disconnect does not reliably trigger failover within the timeout
# in this topology. Available for explicit testing with
# --scenario network_partition while we debug.
ALL_SCENARIOS=(hard_stop hard_kill switchover)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario)            SCENARIO="$2";         shift 2;;
        --iterations)          ITERATIONS="$2"; ITERATIONS_SET=true; shift 2;;
        --interval)            INTERVAL="$2";         shift 2;;
        --prefix)              COMBO_PREFIX="$2";     shift 2;;
        --combo-id)            COMBINATION_ID="$2";   shift 2;;
        --combo-dir)           COMBO_DIR="$2";        shift 2;;
        --fresh-cluster)       FRESH_CLUSTER=true;    shift;;
        --clean-db)            CLEAN_DB=true;         shift;;
        --skip-client-restart) SKIP_CLIENT_RESTART=true; shift;;
        --generate-report)     GENERATE_REPORT=true;  shift;;
        -h|--help)             sed -n '2,27p' "$0" | sed 's/^# \?//'; exit 0;;
        *)                     echo "Unknown argument: $1" >&2; exit 1;;
    esac
done

# Validate scenario
if [[ "$SCENARIO" != "all" ]]; then
    valid=false
    for s in "${VALID_SCENARIOS[@]}"; do
        [[ "$SCENARIO" == "$s" ]] && valid=true && break
    done
    if ! $valid; then
        echo "Unknown scenario: $SCENARIO" >&2
        echo "Valid: ${VALID_SCENARIOS[*]} all" >&2
        exit 1
    fi
fi

# When --scenario all without explicit --iterations, default to 1 per scenario
if [[ "$SCENARIO" == "all" ]] && ! $ITERATIONS_SET; then
    ITERATIONS=1
fi

# Build the ordered list of scenarios to execute
SCENARIO_LIST=()
if [[ "$SCENARIO" == "all" ]]; then
    for (( rep=0; rep<ITERATIONS; rep++ )); do
        SCENARIO_LIST+=("${ALL_SCENARIOS[@]}")
    done
else
    for (( rep=0; rep<ITERATIONS; rep++ )); do
        SCENARIO_LIST+=("$SCENARIO")
    done
fi
TOTAL_ITERATIONS=${#SCENARIO_LIST[@]}

CLIENT_CONTAINER="${COMBO_PREFIX}-client"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    _R=$'\033[31m' _G=$'\033[32m' _Y=$'\033[33m' _B=$'\033[34m' _Z=$'\033[0m'
else
    _R="" _G="" _Y="" _B="" _Z=""
fi
info()   { printf "${_B}[INFO]${_Z} %s\n"   "$*"; }
ok()     { printf "${_G}[ OK ]${_Z} %s\n"   "$*"; }
warn()   { printf "${_Y}[WARN]${_Z} %s\n"   "$*"; }
result() { printf "${_G}[RSLT]${_Z} %s\n"   "$*"; }

# ---------------------------------------------------------------------------
# clean_db — truncate all three event tables (called once if --clean-db)
# ---------------------------------------------------------------------------
clean_db() {
    info "Truncating observer_events, client_events, test_runs..."
    docker exec "$TSDB_CONTAINER" psql -U bench -c "
        TRUNCATE observer_events, client_events, test_runs;" \
        >/dev/null 2>&1 \
        && ok "Database truncated." \
        || warn "Truncation failed — continuing anyway"
}

# ---------------------------------------------------------------------------
# wait_for_cluster_healthy — polls patronictl until 1 Leader + 2 streaming
# Replicas are present. Times out after 180 s. Returns 1 on timeout.
# ---------------------------------------------------------------------------
wait_for_cluster_healthy() {
    local deadline=$((SECONDS + 180))
    local output leader_count replica_count
    while (( SECONDS < deadline )); do
        output=$(docker exec "${COMBO_PREFIX}-node1" patronictl -c "$PATRONI_CONF" list 2>/dev/null \
                 || docker exec "${COMBO_PREFIX}-node2" patronictl -c "$PATRONI_CONF" list 2>/dev/null \
                 || docker exec "${COMBO_PREFIX}-node3" patronictl -c "$PATRONI_CONF" list 2>/dev/null) || true
        leader_count=$(awk '/Leader.*running/{n++} END{print n+0}' <<< "$output")
        replica_count=$(awk '/Replica.*streaming/{n++} END{print n+0}' <<< "$output")
        if [[ "$leader_count" -eq 1 && "$replica_count" -eq 2 ]]; then
            ok "Cluster healthy: 1 Leader + 2 streaming Replicas"
            return 0
        fi
        info "Waiting for cluster: leaders=$leader_count replicas=$replica_count"
        sleep 5
    done
    warn "Cluster did not reach healthy state within 180s"
    return 1
}

# ---------------------------------------------------------------------------
# find_leader — tries each node in turn; echoes node number (1/2/3)
# ---------------------------------------------------------------------------
find_leader() {
    local n out leader
    for n in 1 2 3; do
        out=$(docker exec "${COMBO_PREFIX}-node${n}" \
            patronictl -c "$PATRONI_CONF" list 2>/dev/null) || continue
        leader=$(echo "$out" | grep Leader | awk '{print $2}')
        if [[ -n "$leader" ]]; then
            echo "${leader##patroni-node}"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# wait_for_steady_state — confirms >20 successes in the last 5 s
# ---------------------------------------------------------------------------
wait_for_steady_state() {
    local attempt count
    for attempt in 1 2 3; do
        count=$(docker exec "$TSDB_CONTAINER" psql -U bench -t -A -c \
            "SELECT COUNT(*) FROM client_events
             WHERE success=TRUE AND ts > NOW() - INTERVAL '5 seconds';" \
            2>/dev/null || echo "0")
        if [[ "$count" -gt 20 ]]; then
            ok "Steady state confirmed ($count successes in last 5s)"
            return 0
        fi
        warn "Steady state not reached ($count/20 successes) — waiting 5s (attempt $attempt/3)"
        sleep 5
    done
    warn "Steady state not confirmed after 3 attempts — proceeding anyway"
}

# ---------------------------------------------------------------------------
# wait_for_recovery — polls TimescaleDB every 2 s; returns 0 when recovered
# ---------------------------------------------------------------------------
wait_for_recovery() {
    local kill_ts="$1"
    local deadline=$((SECONDS + RECOVERY_TIMEOUT))
    while (( SECONDS < deadline )); do
        local recovered
        recovered=$(docker exec "$TSDB_CONTAINER" psql -U bench -t -A -c \
            "SELECT COUNT(*) FROM client_events WHERE success=TRUE
             AND ts > (SELECT COALESCE(MAX(ts),'1970-01-01')
                       FROM client_events
                       WHERE success=FALSE AND ts>'$kill_ts'::timestamptz)
             AND ts>'$kill_ts'::timestamptz;" 2>/dev/null || echo "0")
        if [[ "$recovered" -gt 5 ]]; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# ---------------------------------------------------------------------------
# measure_downtime — returns "downtime_s|failed_queries"
# ---------------------------------------------------------------------------
measure_downtime() {
    local kill_ts="$1"
    docker exec "$TSDB_CONTAINER" psql -U bench -t -A -c \
        "SELECT ROUND(EXTRACT(EPOCH FROM (
             MIN(ts) FILTER (WHERE success=TRUE AND ts > (
                 SELECT MAX(ts) FROM client_events
                 WHERE success=FALSE AND ts>'$kill_ts'::timestamptz))
             - MIN(ts) FILTER (WHERE success=FALSE)
         ))::numeric, 1) AS downtime_s,
         COUNT(*) FILTER (WHERE success=FALSE) AS failed
         FROM client_events WHERE ts > '$kill_ts'::timestamptz;" \
        2>/dev/null || true
}

# ---------------------------------------------------------------------------
# compute_stats — reads newline-separated numbers from stdin
# Outputs pipe-separated: "mean|median|min|max|stddev"
# ---------------------------------------------------------------------------
compute_stats() {
    awk '
    /^[0-9]+(\.[0-9]+)?$/ {
        vals[++n] = $1 + 0
        sum += $1
    }
    END {
        if (n == 0) { print "-|-|-|-|-"; exit }
        mean = sum / n
        for (i = 1; i <= n; i++) sumsq += (vals[i] - mean)^2
        denom = (n > 1) ? n - 1 : 1
        stddev = sqrt(sumsq / denom)
        for (i = 1; i <= n; i++)
            for (j = i + 1; j <= n; j++)
                if (vals[i] > vals[j]) { t = vals[i]; vals[i] = vals[j]; vals[j] = t }
        median = (n % 2 == 0) \
                 ? (vals[n/2] + vals[n/2 + 1]) / 2.0 \
                 : vals[int(n/2) + 1]
        printf "%.2f|%.2f|%.2f|%.2f|%.2f", mean, median, vals[1], vals[n], stddev
    }
    '
}

# ---------------------------------------------------------------------------
# inject_failure — perform the scenario-specific failure on $victim
# Returns 1 for switchover if no candidate is available.
# ---------------------------------------------------------------------------
inject_failure() {
    local scenario="$1" victim="$2"
    case "$scenario" in
        hard_stop)
            info "Stopping $victim (SIGTERM/hard_stop)..."
            docker stop "$victim" >/dev/null
            ;;
        hard_kill)
            info "Killing $victim (SIGKILL/hard_kill)..."
            docker kill --signal=SIGKILL "$victim" >/dev/null
            ;;
        network_partition)
            info "Disconnecting $victim from ${COMBO_PREFIX}-bench network..."
            docker network disconnect "${COMBO_PREFIX}-bench" "$victim"
            ;;
        postgres_crash)
            info "Crashing postgres process inside $victim..."
            docker exec "$victim" bash -c 'kill -9 $(pgrep -f "postgres: bench")' || true
            ;;
        switchover)
            local leader_name="patroni-node${victim##*-node}"
            local target
            target=$(docker exec "${COMBO_PREFIX}-node1" patronictl -c "$PATRONI_CONF" list 2>/dev/null \
                     | grep "Replica.*streaming" | head -1 | awk '{print $2}')
            if [[ -z "$target" ]]; then
                warn "No streaming replica found for switchover — skipping"
                return 1
            fi
            info "Switchover: $leader_name → $target (planned, no outage expected)"
            docker exec "${COMBO_PREFIX}-node1" patronictl -c "$PATRONI_CONF" switchover \
                --leader "$leader_name" --candidate "$target" --force
            ;;
        pause)
            info "Pausing $victim (SIGSTOP/pause)..."
            docker pause "$victim"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# recover_node — scenario-specific cleanup; then wait for full cluster health
# ---------------------------------------------------------------------------
recover_node() {
    local scenario="$1" victim="$2" iter_num="$3" total="$4"
    case "$scenario" in
        hard_stop|hard_kill)
            info "Starting $victim..."
            docker start "$victim" >/dev/null
            ;;
        network_partition)
            info "Reconnecting $victim to ${COMBO_PREFIX}-bench network..."
            docker network connect "${COMBO_PREFIX}-bench" "$victim"
            ;;
        postgres_crash)
            info "Waiting 15s for Patroni to auto-restart postgres..."
            sleep 15
            if ! docker exec "$victim" patronictl -c "$PATRONI_CONF" list >/dev/null 2>&1; then
                info "Patroni unresponsive — restarting container $victim..."
                docker restart "$victim" >/dev/null
            fi
            ;;
        switchover)
            # No recovery needed — former leader is already a streaming replica
            :
            ;;
        pause)
            info "Unpausing $victim..."
            docker unpause "$victim"
            ;;
    esac

    # Restart vip-manager and observer-vip sidecars that share
    # Patroni nodes' network namespaces (network_mode: service:X).
    # When a Patroni node restarts or changes role, these containers
    # can lose their network or DNS resolution. Restarting them
    # ensures clean state for the next iteration.
    for n in 1 2 3; do
        for sidecar in "${COMBO_PREFIX}-vip${n}" "${COMBO_PREFIX}-obs-vip${n}"; do
            if docker ps -a --format '{{.Names}}' | grep -q "^${sidecar}$"; then
                docker restart "$sidecar" >/dev/null 2>&1 || true
            fi
        done
    done

    if (( iter_num < total )); then
        wait_for_cluster_healthy || {
            warn "Cluster did not recover cleanly after scenario '$scenario'"
            return 1
        }
        info "Sleeping ${INTERVAL}s for stabilisation..."
        sleep "$INTERVAL"

        info "Verifying cluster health before next iteration..."
        if wait_for_cluster_healthy; then
            ok "Cluster fully recovered — ready for next iteration"
        else
            warn "Cluster not fully healthy after ${INTERVAL}s — next iteration may fail"
        fi
    fi
}

# ---------------------------------------------------------------------------
# fresh_cluster_cycle — tear down and recreate the combination stack.
# The dashboard stack (prb-timescaledb, prb-grafana, prb-prometheus) is
# intentionally left running; only the combination compose file is cycled.
# ---------------------------------------------------------------------------
fresh_cluster_cycle() {
    local compose_file="dcs/consul/${COMBO_DIR}/docker-compose.yml"

    if [[ ! -f "$compose_file" ]]; then
        warn "Cannot find compose file: $compose_file — skipping fresh-cluster cycle"
        return 1
    fi

    info "Fresh-cluster: stopping combination stack (${COMBO_DIR})..."
    docker compose -f "$compose_file" down -v >/dev/null 2>&1 \
        || warn "docker compose down reported errors — continuing"

    info "Fresh-cluster: waiting 5s..."
    sleep 5

    info "Fresh-cluster: starting combination stack (${COMBO_DIR})..."
    docker compose -f "$compose_file" up -d >/dev/null 2>&1 \
        || { warn "docker compose up failed — aborting fresh-cluster cycle"; return 1; }

    info "Fresh-cluster: waiting 30s for containers to initialise..."
    sleep 30
}

# ---------------------------------------------------------------------------
# Result storage
# ---------------------------------------------------------------------------
RES_ITER=()
RES_SCENARIO=()
RES_LEADER=()
RES_DOWN=()
RES_FAILED=()
RES_RUN_ID=()
RES_STATUS=()

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
# Capture the session date now (before any work) so the report groups correctly
# even if iterations span midnight.
SESSION_DATE=$(date -u +%Y-%m-%d)

info "Starting ${TOTAL_ITERATIONS} iteration(s), scenario=${SCENARIO}, interval=${INTERVAL}s, prefix=${COMBO_PREFIX}"
$FRESH_CLUSTER       && info "Mode: fresh-cluster (combination stack recycled before each iteration, combo-dir=${COMBO_DIR})"
$SKIP_CLIENT_RESTART && info "Mode: skip-client-restart (client runs continuously)"
$CLEAN_DB            && info "Mode: clean-db (tables will be truncated now)"

$CLEAN_DB && clean_db

# Create a timestamped session directory for all results from this run.
# Using the current time (not SESSION_DATE alone) so back-to-back runs on
# the same day don't collide.
SESSION_DIR="runner/results/${COMBINATION_ID}/${SESSION_DATE}_$(date -u +%H%M%S)"
mkdir -p "$SESSION_DIR"
info "Session directory: ${SESSION_DIR}"

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
for (( i=0; i<TOTAL_ITERATIONS; i++ )); do
    iter_num=$(( i + 1 ))
    current_scenario="${SCENARIO_LIST[$i]}"
    echo
    info "=== Iteration ${iter_num} / ${TOTAL_ITERATIONS} [scenario: ${current_scenario}] ==="

    # Create per-iteration subfolder immediately so it exists even for
    # non-SUCCESS iterations (charts are only written on SUCCESS).
    ITER_DIR="${SESSION_DIR}/iter${iter_num}_${current_scenario}"
    mkdir -p "$ITER_DIR"

    # 0. Fresh-cluster cycle (if enabled), then verify cluster health
    if $FRESH_CLUSTER; then
        info "Fresh-cluster mode: recycling combination stack before iteration ${iter_num}..."
        if ! fresh_cluster_cycle; then
            warn "Fresh-cluster cycle failed — marking iteration ${iter_num} as CLUSTER_UNHEALTHY and skipping"
            RES_ITER+=("$iter_num")
            RES_SCENARIO+=("$current_scenario")
            RES_LEADER+=("—")
            RES_DOWN+=("—")
            RES_FAILED+=("—")
            RES_RUN_ID+=("")
            RES_STATUS+=("CLUSTER_UNHEALTHY")
            continue
        fi
    fi

    info "Verifying cluster health before iteration ${iter_num}..."
    if ! wait_for_cluster_healthy; then
        warn "Cluster unhealthy — marking iteration ${iter_num} as CLUSTER_UNHEALTHY and skipping"
        RES_ITER+=("$iter_num")
        RES_SCENARIO+=("$current_scenario")
        RES_LEADER+=("—")
        RES_DOWN+=("—")
        RES_FAILED+=("—")
        RES_RUN_ID+=("")
        RES_STATUS+=("CLUSTER_UNHEALTHY")
        continue
    fi

    # 1. Find current leader
    leader_num=""
    if ! leader_num=$(find_leader); then
        warn "No leader found — marking iteration ${iter_num} as ERROR and skipping"
        RES_ITER+=("$iter_num")
        RES_SCENARIO+=("$current_scenario")
        RES_LEADER+=("—")
        RES_DOWN+=("—")
        RES_FAILED+=("—")
        RES_RUN_ID+=("")
        RES_STATUS+=("ERROR")
        continue
    fi
    victim="${COMBO_PREFIX}-node${leader_num}"
    info "Leader: patroni-node${leader_num}  (container: $victim)"

    # 2. Client lifecycle
    if $SKIP_CLIENT_RESTART; then
        info "Restarting $CLIENT_CONTAINER (skip-client-restart mode)..."
        docker restart "$CLIENT_CONTAINER" >/dev/null 2>&1
        sleep 5
    else
        info "Stopping $CLIENT_CONTAINER..."
        docker stop "$CLIENT_CONTAINER" >/dev/null 2>&1 || true
        sleep 2

        info "Starting $CLIENT_CONTAINER..."
        docker start "$CLIENT_CONTAINER" >/dev/null

        info "Waiting 10s for client steady state..."
        sleep 10
        wait_for_steady_state
    fi

    # 3. Generate test_run_id and record start
    TEST_RUN_ID="${COMBINATION_ID}_$(date +%Y%m%d_%H%M%S)"
    START_TS=$(date -u +%Y-%m-%dT%H:%M:%S.%N+00:00)
    info "test_run_id: $TEST_RUN_ID"
    docker exec "$TSDB_CONTAINER" psql -U bench -c "
        INSERT INTO test_runs (id, combination_id, dcs, provider, failover_type, started_at)
        VALUES ('$TEST_RUN_ID', '$COMBINATION_ID', 'consul', 'local', '$current_scenario', '$START_TS');" \
        >/dev/null 2>&1 || warn "Could not insert test_runs row (schema mismatch — continuing)"

    # 3a. Warmup (fresh-cluster mode only)
    if $FRESH_CLUSTER; then
        info "Warming up cluster for 150s..."
        sleep 120
        ok "Warmup complete"
    fi

    # 4. Record timestamp and inject failure
    kill_ts=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)
    info "Injecting failure [$current_scenario] on $victim at $kill_ts"
    if ! inject_failure "$current_scenario" "$victim"; then
        warn "Failure injection skipped — marking iteration ${iter_num} as SKIPPED"
        RES_ITER+=("$iter_num")
        RES_SCENARIO+=("$current_scenario")
        RES_LEADER+=("node${leader_num}")
        RES_DOWN+=("—")
        RES_FAILED+=("—")
        RES_RUN_ID+=("$TEST_RUN_ID")
        RES_STATUS+=("SKIPPED")
        continue
    fi

    # 5. Wait for recovery
    iter_status="TIMEOUT"
    effective_timeout=$([[ "$current_scenario" == "network_partition" ]] && echo 180 || echo "$RECOVERY_TIMEOUT")
    info "Waiting for recovery (timeout ${effective_timeout}s)..."
    if RECOVERY_TIMEOUT=$effective_timeout wait_for_recovery "$kill_ts"; then
        ok "Recovery confirmed"
        iter_status="SUCCESS"
    else
        warn "No recovery within ${effective_timeout}s"
    fi

    # 6. Post-recovery: capture tail data, then stop client (bounded mode only)
    if ! $SKIP_CLIENT_RESTART; then
        info "Capturing 5s of post-recovery data..."
        sleep 5
        info "Stopping $CLIENT_CONTAINER..."
        docker stop "$CLIENT_CONTAINER" >/dev/null 2>&1 || true
    fi

    # 7. Tag events and record end time
    END_TS=$(date -u +%Y-%m-%dT%H:%M:%S.%N+00:00)
    docker exec "$TSDB_CONTAINER" psql -U bench -c "
        UPDATE test_runs SET ended_at = '$END_TS' WHERE id = '$TEST_RUN_ID';" \
        >/dev/null 2>&1 || true
    docker exec "$TSDB_CONTAINER" psql -U bench -c "
        UPDATE observer_events SET test_run_id = '$TEST_RUN_ID'
        WHERE ts BETWEEN '$START_TS'::timestamptz AND '$END_TS'::timestamptz
          AND (test_run_id IS NULL OR test_run_id = '');" \
        >/dev/null 2>&1 || true
    docker exec "$TSDB_CONTAINER" psql -U bench -c "
        UPDATE client_events SET test_run_id = '$TEST_RUN_ID'
        WHERE ts BETWEEN '$START_TS'::timestamptz AND '$END_TS'::timestamptz
          AND (test_run_id IS NULL OR test_run_id = '');" \
        >/dev/null 2>&1 || true

    # 8. Measure downtime
    raw=$(measure_downtime "$kill_ts")
    downtime="${raw%%|*}"
    failed_q="${raw##*|}"
    [[ -z "$downtime" ]] && downtime="—"
    [[ -z "$failed_q"  ]] && failed_q="—"

    result "Iteration ${iter_num}: scenario=${current_scenario}, leader=node${leader_num}, downtime=${downtime}s, failed=${failed_q}, status=${iter_status}, run_id=${TEST_RUN_ID}"

    RES_ITER+=("$iter_num")
    RES_SCENARIO+=("$current_scenario")
    RES_LEADER+=("node${leader_num}")
    RES_DOWN+=("$downtime")
    RES_FAILED+=("$failed_q")
    RES_RUN_ID+=("$TEST_RUN_ID")
    RES_STATUS+=("$iter_status")

    # 8a. Auto-generate charts for successful iterations into the per-iteration dir
    if [[ "$iter_status" == "SUCCESS" ]]; then
        info "Generating charts → ${ITER_DIR}/"
        # ITER_DIR is a path like: runner/results/<combo>/<session>/iter1_hard_stop
        # Inside the charts container, runner/results/ is mounted at /results,
        # so we strip the "runner/results/" prefix to get the container path.
        container_iter_dir="/results/${ITER_DIR#runner/results/}"
        if docker compose -f dashboard/docker-compose.yml --profile charts run --rm charts \
                iteration \
                --test-run-id "$TEST_RUN_ID" \
                --output-dir "$container_iter_dir" \
                >/dev/null 2>&1; then
            ok "Charts saved to ${ITER_DIR}/"
        else
            warn "Chart generation failed for $TEST_RUN_ID — continuing"
        fi
    fi

    # 9. Scenario-specific recovery + cluster health check before next iteration
    recover_node "$current_scenario" "$victim" "$iter_num" "$TOTAL_ITERATIONS" || {
        warn "Recovery handling for '$current_scenario' reported issues — next iteration may fail"
    }
done

# ---------------------------------------------------------------------------
# Summary table — 6 columns per spec
# Widths: Iteration=9, Scenario=20, Leader Killed=13, Downtime=12, Failed=14, Status=7
# ---------------------------------------------------------------------------
echo
printf "╔═══════════╦══════════════════════╦═══════════════╦══════════════╦════════════════╦═════════╗\n"
printf "║ %-9s ║ %-20s ║ %-13s ║ %-12s ║ %-14s ║ %-7s ║\n" \
       "Iteration" "Scenario" "Leader Killed" "Downtime (s)" "Failed Queries" "Status"
printf "╠═══════════╬══════════════════════╬═══════════════╬══════════════╬════════════════╬═════════╣\n"

for (( i=0; i<${#RES_ITER[@]}; i++ )); do
    status_val="${RES_STATUS[$i]}"
    printf "║ %-9s ║ %-20s ║ %-13s ║ %-12s ║ %-14s ║ %-7s ║\n" \
        "${RES_ITER[$i]}" "${RES_SCENARIO[$i]}" "${RES_LEADER[$i]}" \
        "${RES_DOWN[$i]}" "${RES_FAILED[$i]}" "$status_val"
done

printf "╚═══════════╩══════════════════════╩═══════════════╩══════════════╩════════════════╩═════════╝\n"

# ---------------------------------------------------------------------------
# Statistics section
# ---------------------------------------------------------------------------
echo

# Overall success count
success_count=0
for status in "${RES_STATUS[@]}"; do
    [[ "$status" == "SUCCESS" ]] && (( success_count++ ))
done

total_recorded=${#RES_STATUS[@]}
info "Valid iterations: ${success_count} / ${total_recorded} ($((success_count * 100 / (total_recorded > 0 ? total_recorded : 1)))%)"

if [[ "$SCENARIO" == "all" ]]; then
    # Per-scenario breakdown
    echo
    info "Summary by scenario:"
    for s in "${ALL_SCENARIOS[@]}"; do
        s_dt_vals="" s_success=0 s_total=0
        for (( i=0; i<${#RES_SCENARIO[@]}; i++ )); do
            if [[ "${RES_SCENARIO[$i]}" == "$s" ]]; then
                (( s_total++ ))
                if [[ "${RES_STATUS[$i]}" == "SUCCESS" ]]; then
                    (( s_success++ ))
                    s_dt_vals+="${RES_DOWN[$i]}"$'\n'
                fi
            fi
        done
        if (( s_total == 0 )); then
            continue
        fi
        if (( s_success > 0 )); then
            IFS='|' read -r dt_mean _ _ _ dt_std \
                <<< "$(printf '%s' "$s_dt_vals" | compute_stats)"
            printf "  %-22s mean=%-8s stddev=%-8s iterations=%d/%d valid\n" \
                "${s}:" "${dt_mean}s" "${dt_std}" "$s_success" "$s_total"
        else
            printf "  %-22s no successful iterations  (%d/%d valid)\n" \
                "${s}:" "0" "$s_total"
        fi
    done
else
    # Single-scenario aggregate stats (existing behaviour)
    dt_success_vals="" fq_success_vals=""
    for (( i=0; i<${#RES_STATUS[@]}; i++ )); do
        if [[ "${RES_STATUS[$i]}" == "SUCCESS" ]]; then
            dt_success_vals+="${RES_DOWN[$i]}"$'\n'
            fq_success_vals+="${RES_FAILED[$i]}"$'\n'
        fi
    done

    if (( success_count > 0 )); then
        IFS='|' read -r dt_mean dt_med dt_min dt_max dt_std \
            <<< "$(printf '%s' "$dt_success_vals" | compute_stats)"
        IFS='|' read -r fq_mean fq_med fq_min fq_max fq_std \
            <<< "$(printf '%s' "$fq_success_vals" | compute_stats)"

        printf "  %-12s downtime: mean=%-8s stddev=%-8s min=%-8s max=%s\n" \
            "($SCENARIO)" "${dt_mean}s" "${dt_std}" "${dt_min}s" "${dt_max}s"
        printf "  %-12s failed_q: mean=%-8s stddev=%-8s min=%-8s max=%s\n" \
            "" "${fq_mean}" "${fq_std}" "${fq_min}" "${fq_max}"
    fi
fi

# Warn if success rate is below 60%
if (( success_count * 10 < total_recorded * 6 )); then
    warn "Low success rate — consider increasing --interval or investigating cluster stability."
fi

# ---------------------------------------------------------------------------
# Per-run summary from TimescaleDB
# ---------------------------------------------------------------------------
if (( ${#RES_RUN_ID[@]} > 0 )); then
    run_ids=""
    for rid in "${RES_RUN_ID[@]}"; do
        [[ -n "$rid" ]] && run_ids+="'${rid}',"
    done
    run_ids="${run_ids%,}"

    if [[ -n "$run_ids" ]]; then
        echo
        info "Per-iteration results from TimescaleDB (combination_id=$COMBINATION_ID):"
        docker exec "$TSDB_CONTAINER" psql -U bench -c "
            SELECT
              tr.id AS test_run,
              tr.failover_type AS scenario,
              ROUND(EXTRACT(EPOCH FROM (
                MIN(ce.ts) FILTER (WHERE ce.success=TRUE AND ce.ts > (
                    SELECT MAX(ts) FROM client_events
                    WHERE success=FALSE AND test_run_id=tr.id))
                - MIN(ce.ts) FILTER (WHERE ce.success=FALSE)
              ))::numeric, 1) AS downtime_s,
              COUNT(*) FILTER (WHERE ce.success=FALSE) AS failed_queries
            FROM test_runs tr
            JOIN client_events ce ON ce.test_run_id = tr.id
            WHERE tr.combination_id = '$COMBINATION_ID'
              AND tr.id IN (${run_ids})
            GROUP BY tr.id, tr.failover_type, tr.started_at
            ORDER BY tr.started_at;" 2>/dev/null \
            || warn "TimescaleDB summary query failed"
    fi
fi

echo
ok "Done. Client container ($CLIENT_CONTAINER) is stopped."
info "To resume live dashboard traffic: docker start $CLIENT_CONTAINER"

# ---------------------------------------------------------------------------
# HTML report generation (if --generate-report)
# ---------------------------------------------------------------------------
if $GENERATE_REPORT; then
    report_output="${SESSION_DIR}/report.html"
    info "Generating HTML report → ${report_output}"
    container_session_dir="/results/${SESSION_DIR#runner/results/}"
    container_report="/results/${report_output#runner/results/}"
    if docker compose -f dashboard/docker-compose.yml --profile charts run --rm charts \
            combo-report \
            --combination-id "$COMBINATION_ID" \
            --session-dir "$container_session_dir" \
            --output "$container_report" \
            >/dev/null 2>&1; then
        ok "Report saved: ${report_output}"
    else
        warn "Report generation failed — continuing"
    fi
fi
