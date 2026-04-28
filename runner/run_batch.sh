#!/usr/bin/env bash
# patroni-routing-bench — full-suite batch runner
#
# Usage: runner/run_batch.sh [OPTIONS]
#
# Options:
#   --combos "01,06,07"   Only run combinations whose number prefix matches (comma-separated)
#   --skip  "05,10"       Skip combinations whose number prefix matches (comma-separated)
#   --scenario S          Scenario passed to run_failover_test.sh (default: all)
#   --iterations N        Repetitions per scenario, passed to run_failover_test.sh (default: 1)
#   --interval S          Stabilisation sleep between iterations in seconds (default: 90)
#   --generate-report     Generate per-combo HTML reports (passes --generate-report to runner)
#   --batch-report        Generate cross-combo HTML report at the end
#   -h, --help            Show this help
set -eo pipefail

# ---------------------------------------------------------------------------
# Combo registry — parallel arrays indexed 0..10
# ---------------------------------------------------------------------------
COMBO_DIRS=(
    "01-libpq-multihost"
    "02-consul-dns"
    "03-vip-manager-poll"
    "04-vip-patroni-callback"
    "05-bgp-anycast"
    "06-haproxy-rest-polling"
    "06-haproxy-rest-polling-tuned"
    "07-consul-template-reload"
    "08-consul-template-runtime-api"
    "09-patroni-callback-haproxy"
    "10-consul-connect-envoy"
)
COMBO_PREFIXES=(
    "prb-01"
    "prb-02"
    "prb-03"
    "prb-04"
    "prb-05"
    "prb-06"
    "prb-06t"
    "prb-07"
    "prb-08"
    "prb-09"
    "prb-10"
)

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
FILTER_COMBOS=""
SKIP_COMBOS=""
SCENARIO="all"
ITERATIONS=1
INTERVAL=90
GENERATE_REPORT=false
BATCH_REPORT=false

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    _R=$'\033[31m' _G=$'\033[32m' _Y=$'\033[33m' _B=$'\033[34m' _Z=$'\033[0m'
else
    _R="" _G="" _Y="" _B="" _Z=""
fi
info()   { printf "${_B}[INFO]${_Z} %s\n" "$*"; }
ok()     { printf "${_G}[ OK ]${_Z} %s\n" "$*"; }
warn()   { printf "${_Y}[WARN]${_Z} %s\n" "$*"; }
err()    { printf "${_R}[FAIL]${_Z} %s\n" "$*" >&2; }
banner() {
    printf "\n${_B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    printf "  %s\n" "$*"
    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_Z}\n"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --combos)          FILTER_COMBOS="$2"; shift 2;;
        --skip)            SKIP_COMBOS="$2";   shift 2;;
        --scenario)        SCENARIO="$2";      shift 2;;
        --iterations)      ITERATIONS="$2";    shift 2;;
        --interval)        INTERVAL="$2";      shift 2;;
        --generate-report) GENERATE_REPORT=true; shift;;
        --batch-report)    BATCH_REPORT=true;    shift;;
        -h|--help)         sed -n '2,11p' "$0" | sed 's/^# \?//'; exit 0;;
        *) err "Unknown argument: $1"; exit 1;;
    esac
done

# ---------------------------------------------------------------------------
# should_run — returns 0 if this combo dir should be included in the batch
# ---------------------------------------------------------------------------
should_run() {
    local dir="$1"
    local num="${dir%%-*}"  # "06-haproxy-..." → "06"

    if [[ -n "$FILTER_COMBOS" ]]; then
        local found=false
        IFS=',' read -ra _filter <<< "$FILTER_COMBOS"
        for f in "${_filter[@]}"; do
            [[ "${num}" == "${f// /}" ]] && found=true && break
        done
        $found || return 1
    fi

    if [[ -n "$SKIP_COMBOS" ]]; then
        IFS=',' read -ra _skip <<< "$SKIP_COMBOS"
        for s in "${_skip[@]}"; do
            [[ "${num}" == "${s// /}" ]] && return 1
        done
    fi

    return 0
}

# ---------------------------------------------------------------------------
# bootstrap_wait — polls patronictl until 1 Leader + 2 streaming Replicas
# Times out after 90 s. Returns 1 on timeout.
# ---------------------------------------------------------------------------
bootstrap_wait() {
    local prefix="$1"
    local patroni_conf="/etc/patroni/patroni.yml"
    local deadline=$(( SECONDS + 90 ))
    local output leader_count replica_count

    while (( SECONDS < deadline )); do
        output=$(docker exec "${prefix}-node1" patronictl -c "$patroni_conf" list 2>/dev/null \
              || docker exec "${prefix}-node2" patronictl -c "$patroni_conf" list 2>/dev/null \
              || docker exec "${prefix}-node3" patronictl -c "$patroni_conf" list 2>/dev/null) || true
        leader_count=$(awk  '/Leader.*running/{n++} END{print n+0}' <<< "$output")
        replica_count=$(awk '/Replica.*streaming/{n++} END{print n+0}' <<< "$output")
        if [[ "$leader_count" -eq 1 && "$replica_count" -eq 2 ]]; then
            ok "[${prefix}] Bootstrap ready: 1 Leader + 2 streaming Replicas"
            return 0
        fi
        info "[${prefix}] Bootstrap in progress: leaders=${leader_count} replicas=${replica_count}"
        sleep 5
    done
    warn "[${prefix}] Cluster not ready after 90s"
    return 1
}

# ---------------------------------------------------------------------------
# parse_runner_rows — extract data rows from captured runner output and
# append CSV lines (without header) to BATCH_CSV, tagging with session_folder.
# ---------------------------------------------------------------------------
parse_runner_rows() {
    local output_file="$1"
    local combo_dir="$2"
    local prefix="$3"
    local session_folder="$4"

    python3 - "$output_file" "$combo_dir" "$prefix" "$session_folder" <<'PYEOF'
import sys

output_file    = sys.argv[1]
combo_dir      = sys.argv[2]
prefix         = sys.argv[3]
session_folder = sys.argv[4]

with open(output_file, errors="replace") as fh:
    lines = fh.readlines()

for line in lines:
    line = line.strip()
    if not (line.startswith("║") and line.endswith("║")):
        continue
    parts = [p.strip() for p in line.strip("║").split("║")]
    if len(parts) != 6:
        continue
    iteration, scenario, leader_killed, downtime_s, failed_queries, status = parts
    if iteration == "Iteration":        # header row
        continue
    try:
        int(iteration)
    except ValueError:
        continue                         # separator or non-data row
    print(f"{combo_dir},{prefix},{scenario},{iteration},{leader_killed},{downtime_s},{failed_queries},{status},{session_folder}")
PYEOF
}

# ---------------------------------------------------------------------------
# process_combo — run one combination end-to-end
# Appends to global arrays BATCH_STATUS and BATCH_SESSIONS.
# ---------------------------------------------------------------------------
process_combo() {
    local combo_dir="$1"
    local prefix="$2"
    local combo_id="$3"
    local compose_file="dcs/consul/${combo_dir}/docker-compose.yml"

    banner "COMBO ${combo_dir}  (prefix=${prefix})"

    if [[ ! -f "$compose_file" ]]; then
        warn "[${combo_dir}] No docker-compose.yml at ${compose_file} — skipping"
        BATCH_STATUS+=("SKIPPED")
        BATCH_SESSIONS+=("")
        return 0
    fi

    # 1. Tear down any stale instance
    info "[${combo_dir}] Tearing down stale stack..."
    docker compose -f "$compose_file" down -v >/dev/null 2>&1 \
        || warn "[${combo_dir}] docker compose down reported errors (stale state)"
    sleep 3

    # 2. Bring up fresh stack
    info "[${combo_dir}] Starting stack (--build)..."
    if ! docker compose -f "$compose_file" up -d --build >/dev/null 2>&1; then
        warn "[${combo_dir}] docker compose up failed — skipping"
        BATCH_STATUS+=("START_FAILED")
        BATCH_SESSIONS+=("")
        return 0
    fi

    # 3. Wait for cluster bootstrap
    info "[${combo_dir}] Waiting for cluster bootstrap (up to 90s)..."
    if ! bootstrap_wait "$prefix"; then
        warn "[${combo_dir}] Bootstrap timed out — skipping runner"
        docker compose -f "$compose_file" down -v >/dev/null 2>&1 || true
        BATCH_STATUS+=("BOOTSTRAP_TIMEOUT")
        BATCH_SESSIONS+=("")
        return 0
    fi

    # 4. Build runner arguments
    local runner_args=(
        --combo-id   "$combo_id"
        --combo-dir  "$combo_dir"
        --prefix     "$prefix"
        --scenario   "$SCENARIO"
        --iterations "$ITERATIONS"
        --interval   "$INTERVAL"
    )
    $GENERATE_REPORT && runner_args+=(--generate-report)

    # 5. Run the test suite, capturing output while still printing to terminal
    local runner_output
    runner_output=$(mktemp /tmp/prb_runner_XXXXXX.log)

    info "[${combo_dir}] Running test suite (scenario=${SCENARIO}, iterations=${ITERATIONS})..."
    set +e
    bash runner/run_failover_test.sh "${runner_args[@]}" 2>&1 | tee "$runner_output"
    local runner_rc="${PIPESTATUS[0]}"
    set -e
    [[ "$runner_rc" -ne 0 ]] && warn "[${combo_dir}] Runner exited with code ${runner_rc}"

    # 6. Detect session folder created by this run
    local session_folder=""
    session_folder=$(ls -d "runner/results/${combo_id}/"*/ 2>/dev/null | sort | tail -1) || true
    session_folder="${session_folder%/}"
    BATCH_SESSIONS+=("$session_folder")

    # 7. Parse runner output → append rows to batch CSV
    parse_runner_rows "$runner_output" "$combo_dir" "$prefix" "$session_folder" >> "$BATCH_CSV"
    rm -f "$runner_output"

    # 8. Count successes for this combo from the CSV
    local success_count=0
    success_count=$(grep "^${combo_dir}," "$BATCH_CSV" \
        | awk -F',' '$8=="SUCCESS"{c++} END{print c+0}') || true
    if [[ "$success_count" -gt 0 ]]; then
        ok "[${combo_dir}] PASSED (${success_count} successful iteration(s))"
        BATCH_STATUS+=("PASSED")
    else
        warn "[${combo_dir}] FAILED (0 successful iterations)"
        BATCH_STATUS+=("FAILED")
    fi

    # 9. Tear down combination stack
    info "[${combo_dir}] Tearing down stack..."
    docker compose -f "$compose_file" down -v >/dev/null 2>&1 \
        || warn "[${combo_dir}] docker compose down reported errors"

    return 0
}

# ---------------------------------------------------------------------------
# cleanup_between_combos — prune Docker runtime state after a combo tears down.
# Aborts the batch if TimescaleDB has disappeared (observability lost).
# Must NOT be called after the final combo (wastes 30s and serves no purpose).
# ---------------------------------------------------------------------------
cleanup_between_combos() {
    local combo_dir="$1"

    if ! docker inspect prb-timescaledb >/dev/null 2>&1; then
        err "prb-timescaledb is no longer running after [${combo_dir}]. Aborting batch — observability lost."
        exit 1
    fi

    info "[${combo_dir}] Cleaning up runtime state..."
    docker container prune -f >/dev/null 2>&1 || true
    docker image prune -f >/dev/null 2>&1 || true
    docker network prune -f >/dev/null 2>&1 || true
    docker volume prune -f --filter "label!=keep" >/dev/null 2>&1 || true
    info "[${combo_dir}] Waiting 30s for system to settle..."
    sleep 30
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
info "Pre-flight checks..."

if ! docker inspect prb-timescaledb >/dev/null 2>&1; then
    err "prb-timescaledb is not running. Start it first:"
    err "  cd dashboard && docker compose up -d"
    exit 1
fi
ok "prb-timescaledb is running"

if ! docker inspect prb-grafana >/dev/null 2>&1; then
    err "prb-grafana is not running. Start it first:"
    err "  cd dashboard && docker compose up -d"
    exit 1
fi
ok "prb-grafana is running"

if ! docker inspect prb-prometheus >/dev/null 2>&1; then
    warn "prb-prometheus is not running — Prometheus metrics will not be captured (non-fatal)"
fi

# Ensure we run from the repo root
if [[ ! -f "runner/run_failover_test.sh" ]]; then
    err "Must be run from the repo root (runner/run_failover_test.sh not found)"
    exit 1
fi

# ---------------------------------------------------------------------------
# Batch output directory and CSV
# ---------------------------------------------------------------------------
BATCH_TS=$(date -u +%Y%m%d_%H%M%S)
BATCH_DIR="runner/results/batch_${BATCH_TS}"
mkdir -p "$BATCH_DIR"
BATCH_CSV="${BATCH_DIR}/results.csv"
echo "combo_dir,prefix,scenario,iteration,leader_killed,downtime_s,failed_queries,status,session_folder" > "$BATCH_CSV"

info "Batch directory : ${BATCH_DIR}"
info "Batch CSV       : ${BATCH_CSV}"

# ---------------------------------------------------------------------------
# Determine which combos to run
# ---------------------------------------------------------------------------
RUN_DIRS=()
RUN_PREFIXES=()
RUN_IDS=()

for i in "${!COMBO_DIRS[@]}"; do
    if should_run "${COMBO_DIRS[$i]}"; then
        RUN_DIRS+=("${COMBO_DIRS[$i]}")
        RUN_PREFIXES+=("${COMBO_PREFIXES[$i]}")
        RUN_IDS+=("${COMBO_DIRS[$i]}")   # combo_id == combo_dir
    fi
done

total_combos=${#RUN_DIRS[@]}
if [[ "$total_combos" -eq 0 ]]; then
    err "No combinations match the given --combos / --skip filters"
    exit 1
fi

info "Combinations to run (${total_combos}): ${RUN_DIRS[*]}"
echo

# ---------------------------------------------------------------------------
# Main batch loop
# ---------------------------------------------------------------------------
BATCH_STATUS=()
BATCH_SESSIONS=()

for (( i=0; i<total_combos; i++ )); do
    process_combo "${RUN_DIRS[$i]}" "${RUN_PREFIXES[$i]}" "${RUN_IDS[$i]}"
    if (( i < total_combos - 1 )); then
        cleanup_between_combos "${RUN_DIRS[$i]}"
    fi
done

# ---------------------------------------------------------------------------
# Final summary table
# ---------------------------------------------------------------------------
echo
printf "╔══════════════════════════════════════════╦══════════════════╦══════════════════════════╗\n"
printf "║ %-40s ║ %-16s ║ %-24s ║\n" "Combination" "Status" "Session Folder"
printf "╠══════════════════════════════════════════╬══════════════════╬══════════════════════════╣\n"

passed_combos=0
for (( i=0; i<total_combos; i++ )); do
    s="${BATCH_STATUS[$i]}"
    folder_short="${BATCH_SESSIONS[$i]##*/}"
    [[ "$s" == "PASSED" ]] && (( passed_combos++ )) || true
    printf "║ %-40s ║ %-16s ║ %-24s ║\n" "${RUN_DIRS[$i]}" "$s" "$folder_short"
done

printf "╚══════════════════════════════════════════╩══════════════════╩══════════════════════════╝\n"
echo
info "Combos passed  : ${passed_combos} / ${total_combos}"
info "Results CSV    : ${BATCH_CSV}"

# ---------------------------------------------------------------------------
# Cross-combo batch HTML report
# ---------------------------------------------------------------------------
if $BATCH_REPORT; then
    batch_report="${BATCH_DIR}/batch_report.html"
    info "Generating batch report → ${batch_report}"
    container_csv="/results/${BATCH_CSV#runner/results/}"
    container_dir="/results/${BATCH_DIR#runner/results/}"
    container_out="/results/${batch_report#runner/results/}"
    if docker compose -f dashboard/docker-compose.yml --profile charts run --rm charts \
            batch-report \
            --batch-csv "$container_csv" \
            --batch-dir "$container_dir" \
            --output "$container_out"; then
        ok "Batch report saved: ${batch_report}"
    else
        warn "Batch report generation failed"
    fi
fi

# ---------------------------------------------------------------------------
# Exit code: 0 if ≥80% of combos passed, 1 otherwise
# ---------------------------------------------------------------------------
if (( total_combos == 0 )); then
    exit 1
fi
threshold=$(( total_combos * 80 / 100 ))
if [[ "$passed_combos" -ge "$threshold" ]]; then
    ok "Batch PASSED (${passed_combos}/${total_combos} ≥ 80% threshold)"
    exit 0
else
    warn "Batch FAILED (${passed_combos}/${total_combos} < 80% threshold)"
    exit 1
fi
