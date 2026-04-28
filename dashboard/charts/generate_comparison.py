#!/usr/bin/env python3
"""
patroni-routing-bench: Cross-combination comparison chart generator

Connects to TimescaleDB and produces three outputs per run:
  1. comparison_grouped.png   — grouped bar chart, one bar per phase per combination
  2. comparison_timeline.png  — stacked horizontal bars, same time axis per combination
  3. comparison_progress.png  — step-function lines, one per combination (recovery milestones)
  4. comparison_summary.csv   — statistics table

Usage:
    python generate_comparison.py \\
        --combinations 06-haproxy-rest-polling,02-consul-dns \\
        --iterations 5

    python generate_comparison.py \\
        --combinations 01-libpq-multihost,06-haproxy-rest-polling,09-patroni-callback-haproxy \\
        --output my_comparison.png \\
        --format html

Environment variables (same as generate_gantt.py):
    TIMESCALE_HOST     (default: localhost)
    TIMESCALE_PORT     (default: 5433)
    TIMESCALE_USER     (default: bench)
    TIMESCALE_PASSWORD (default: bench)
    TIMESCALE_DB       (default: bench)
"""

import argparse
import csv
import os
import statistics
import sys
from pathlib import Path

import pandas as pd
import psycopg
import plotly.graph_objects as go

# ---------------------------------------------------------------------------
# Style constants — mirrors generate_gantt.py
# ---------------------------------------------------------------------------

PHASE_COLORS = {
    "DCS Detection":      "#e67e22",
    "Patroni Promotion":  "#f39c12",
    "Routing Detection":  "#3498db",
    "Client Recovery":    "#2ecc71",
}

# Phase order is fixed: each phase feeds the next in the sequential model.
ALL_PHASES = [
    "DCS Detection",
    "Patroni Promotion",
    "Routing Detection",
    "Client Recovery",
]

# Milestone labels for the progress/step-function chart (y-axis ticks)
MILESTONE_LABELS = [
    "Failure",
    "DCS Detected",
    "Patroni Promoted",
    "Routing Updated",
    "Client Recovered",
]

FONT_FAMILY = "Arial, Helvetica, sans-serif"
WHITE      = "#ffffff"
DARK       = "#2c3e50"
GRAY       = "#95a5a6"
RED        = "#e74c3c"
GREEN      = "#2ecc71"

# One distinct line color per combination (cycles if > 10 combos)
COMBO_PALETTE = [
    "#e74c3c", "#3498db", "#2ecc71", "#f39c12", "#9b59b6",
    "#1abc9c", "#e67e22", "#2980b9", "#27ae60", "#8e44ad",
]


# ---------------------------------------------------------------------------
# Database connection
# ---------------------------------------------------------------------------
def get_connection():
    host     = os.environ.get("TIMESCALE_HOST",     "localhost")
    port     = os.environ.get("TIMESCALE_PORT",     "5433")
    db       = os.environ.get("TIMESCALE_DB",       "bench")
    user     = os.environ.get("TIMESCALE_USER",     "bench")
    password = os.environ.get("TIMESCALE_PASSWORD", "bench")
    return psycopg.connect(
        f"host={host} port={port} dbname={db} user={user} password={password}"
    )


def _query_df(conn, query: str, params: dict | None = None) -> pd.DataFrame:
    with conn.cursor() as cur:
        cur.execute(query, params or {})
        cols = [d[0] for d in cur.description]
        return pd.DataFrame(cur.fetchall(), columns=cols)


# ---------------------------------------------------------------------------
# Fetch successful test run IDs
# A "successful" run has ≥1 failed client event AND ≥1 successful client
# event after the first failure (i.e. the cluster actually recovered).
# ---------------------------------------------------------------------------
def fetch_successful_run_ids(conn, combination_id: str, limit: int) -> list[str]:
    df = _query_df(
        conn,
        """
        SELECT tr.id
        FROM test_runs tr
        WHERE tr.combination_id = %(cid)s
          AND tr.id IN (
              SELECT test_run_id
              FROM client_events
              WHERE success = FALSE
          )
          AND tr.id IN (
              SELECT DISTINCT ce_ok.test_run_id
              FROM client_events ce_ok
              JOIN (
                  SELECT test_run_id, MIN(ts) AS first_fail
                  FROM client_events
                  WHERE success = FALSE
                  GROUP BY test_run_id
              ) ff USING (test_run_id)
              WHERE ce_ok.success = TRUE
                AND ce_ok.ts > ff.first_fail
          )
        ORDER BY tr.started_at DESC
        LIMIT %(lim)s
        """,
        {"cid": combination_id, "lim": limit},
    )
    return list(df["id"])


# ---------------------------------------------------------------------------
# Load observer + client events for one test run
# ---------------------------------------------------------------------------
def load_events(
    conn, combination_id: str, run_id: str
) -> tuple[pd.DataFrame, pd.DataFrame]:
    obs = _query_df(
        conn,
        """
        SELECT ts, component, node, event_type, old_value, new_value, detail
        FROM observer_events
        WHERE combination_id = %(cid)s AND test_run_id = %(rid)s
        ORDER BY ts
        """,
        {"cid": combination_id, "rid": run_id},
    )
    cli = _query_df(
        conn,
        """
        SELECT ts, success, latency_us, error
        FROM client_events
        WHERE combination_id = %(cid)s AND test_run_id = %(rid)s
        ORDER BY ts
        """,
        {"cid": combination_id, "rid": run_id},
    )
    return obs, cli


# ---------------------------------------------------------------------------
# Phase extraction for a single run
# Returns {phase_name: duration_seconds | None}
# ---------------------------------------------------------------------------
def extract_phases(
    obs_df: pd.DataFrame, cli_df: pd.DataFrame
) -> dict[str, float | None]:
    phases: dict[str, float | None] = {p: None for p in ALL_PHASES}

    if cli_df.empty:
        return phases

    failures = cli_df[~cli_df["success"]]
    if failures.empty:
        return phases

    first_failure = failures["ts"].min()
    last_failure  = failures["ts"].max()
    after_fail    = cli_df[(cli_df["success"]) & (cli_df["ts"] > last_failure)]
    if after_fail.empty:
        return phases

    first_recovery = after_fail["ts"].min()

    # Client Recovery = last failure → first success after
    phases["Client Recovery"] = (first_recovery - last_failure).total_seconds()

    # DCS Detection = first failure → leader_key_deleted
    consul_del = obs_df[obs_df["event_type"] == "leader_key_deleted"]
    if not consul_del.empty:
        t_del = consul_del["ts"].iloc[-1]
        if t_del >= first_failure:
            phases["DCS Detection"] = (t_del - first_failure).total_seconds()

    # Patroni Promotion = pg_promote_requested → pg_ready_accept_connections
    pg_req   = obs_df[obs_df["event_type"] == "pg_promote_requested"]
    pg_ready = obs_df[obs_df["event_type"] == "pg_ready_accept_connections"]
    if not pg_req.empty and not pg_ready.empty:
        pg_start = pg_req["ts"].iloc[-1]
        pg_after = pg_ready[pg_ready["ts"] >= pg_start]
        if not pg_after.empty:
            phases["Patroni Promotion"] = (
                pg_after["ts"].iloc[0] - pg_start
            ).total_seconds()

    # Routing Detection = first HAProxy event after failure → primary_backend UP
    haproxy = obs_df[obs_df["event_type"] == "backend_state_change"]
    if not haproxy.empty:
        ha_after = haproxy[haproxy["ts"] >= first_failure]
        if not ha_after.empty:
            ha_start  = ha_after["ts"].iloc[0]
            up_events = ha_after[
                ha_after["new_value"].astype(str).str.upper().str.startswith("UP")
            ]
            if not up_events.empty and "detail" in up_events.columns:
                primary_up = up_events[
                    up_events["detail"]
                    .astype(str)
                    .str.contains("primary_backend", na=False)
                ]
                if not primary_up.empty:
                    up_events = primary_up
            if not up_events.empty:
                phases["Routing Detection"] = (
                    up_events["ts"].iloc[0] - ha_start
                ).total_seconds()

    return phases


# ---------------------------------------------------------------------------
# Statistics helpers
# ---------------------------------------------------------------------------
def _nonnull(values: list) -> list[float]:
    return [v for v in values if v is not None]


def compute_stats(values: list) -> dict:
    vals = _nonnull(values)
    n = len(vals)
    if n == 0:
        return {"mean": None, "median": None, "min": None, "max": None,
                "stddev": None, "n": 0}
    mean   = sum(vals) / n
    median = statistics.median(vals)
    mn     = min(vals)
    mx     = max(vals)
    stddev = statistics.stdev(vals) if n > 1 else 0.0
    return {"mean": mean, "median": median, "min": mn, "max": mx,
            "stddev": stddev, "n": n}


def compute_downtime(cli_df: pd.DataFrame) -> float | None:
    if cli_df.empty:
        return None
    failures = cli_df[~cli_df["success"]]
    if failures.empty:
        return None
    first_failure = failures["ts"].min()
    after = cli_df[(cli_df["success"]) & (cli_df["ts"] > first_failure)]
    if after.empty:
        return None
    return (after["ts"].min() - first_failure).total_seconds()


# ---------------------------------------------------------------------------
# Per-combination aggregation
# ---------------------------------------------------------------------------
def aggregate_combination(
    conn, combination_id: str, n_iterations: int
) -> dict | None:
    run_ids = fetch_successful_run_ids(conn, combination_id, n_iterations)
    if not run_ids:
        print(f"  [{combination_id}] No successful runs found — skipping")
        return None

    preview = run_ids[:3]
    suffix  = "…" if len(run_ids) > 3 else ""
    print(f"  [{combination_id}] {len(run_ids)} successful run(s): {preview}{suffix}")

    downtime_values: list[float]            = []
    phase_values: dict[str, list[float]]    = {p: [] for p in ALL_PHASES}

    for rid in run_ids:
        obs_df, cli_df = load_events(conn, combination_id, rid)
        dt = compute_downtime(cli_df)
        if dt is not None:
            downtime_values.append(dt)
        for phase, val in extract_phases(obs_df, cli_df).items():
            if val is not None and val >= 0:
                phase_values[phase].append(val)

    return {
        "combination_id":  combination_id,
        "run_ids":         run_ids,
        "downtime_values": downtime_values,
        "phase_values":    phase_values,
        "stats": {
            "downtime": compute_stats(downtime_values),
            "phases":   {p: compute_stats(phase_values[p]) for p in ALL_PHASES},
        },
    }


# ---------------------------------------------------------------------------
# Chart 1: Grouped bar chart
# One group per combination, 4 bars per group (phases), error bars = stddev
# ---------------------------------------------------------------------------
def build_grouped_bar_chart(
    combo_data: list[dict], n_iterations: int
) -> go.Figure:
    combo_labels = [d["combination_id"] for d in combo_data]
    fig = go.Figure()

    for phase in ALL_PHASES:
        means  = []
        errors = []
        for d in combo_data:
            s = d["stats"]["phases"][phase]
            means.append(s["mean"]   if s["mean"]   is not None else 0.0)
            errors.append(s["stddev"] if s["stddev"] is not None else 0.0)

        fig.add_trace(go.Bar(
            name=phase,
            x=combo_labels,
            y=means,
            error_y=dict(type="data", array=errors, visible=True,
                         color=DARK, thickness=1.5, width=6),
            marker_color=PHASE_COLORS[phase],
            text=[f"{m:.2f}s" if m else "N/A" for m in means],
            textposition="outside",
            textfont=dict(size=10, family=FONT_FAMILY, color=DARK),
        ))

    fig.update_layout(
        title=dict(
            text=(
                "Failover Phase Breakdown — Cross-Combination Comparison<br>"
                f"<sup>Mean across up to {n_iterations} successful iterations per combination"
                " | error bars = stddev</sup>"
            ),
            font=dict(size=18, family=FONT_FAMILY, color=DARK),
        ),
        font=dict(family=FONT_FAMILY, size=12, color=DARK),
        plot_bgcolor=WHITE,
        paper_bgcolor=WHITE,
        width=max(900, len(combo_labels) * 220),
        height=560,
        margin=dict(l=60, r=60, t=120, b=140),
        barmode="group",
        xaxis=dict(
            title="Combination",
            showgrid=False,
            tickangle=-30,
            tickfont=dict(size=11),
        ),
        yaxis=dict(
            title="Duration (seconds)",
            showgrid=True,
            gridcolor="#ecf0f1",
            rangemode="tozero",
        ),
        legend=dict(
            orientation="h",
            yanchor="bottom",
            y=1.04,
            xanchor="right",
            x=1,
        ),
    )
    return fig


# ---------------------------------------------------------------------------
# Chart 2: Phase timeline — stacked horizontal bars on the same time axis
# One row per combination; leftmost = fastest; segments show where time is spent
# ---------------------------------------------------------------------------
def build_phase_timeline_chart(
    combo_data: list[dict], n_iterations: int
) -> go.Figure:
    combo_labels = [d["combination_id"] for d in combo_data]
    fig = go.Figure()

    for phase in ALL_PHASES:
        means = []
        for d in combo_data:
            s = d["stats"]["phases"][phase]
            means.append(s["mean"] if s["mean"] is not None else 0.0)

        fig.add_trace(go.Bar(
            name=phase,
            y=combo_labels,
            x=means,
            orientation="h",
            marker_color=PHASE_COLORS[phase],
            text=[f"{m:.2f}s" if m > 0.3 else "" for m in means],
            textposition="inside",
            textfont=dict(color="white", size=11, family=FONT_FAMILY),
            hovertemplate=(
                f"<b>{phase}</b>: %{{x:.2f}}s<br>"
                "Combination: %{y}<extra></extra>"
            ),
        ))

    n_rows = len(combo_labels)
    fig.update_layout(
        title=dict(
            text=(
                "Failover Phase Timeline — Cross-Combination Comparison<br>"
                f"<sup>Mean phase durations across up to {n_iterations} iterations"
                " | shorter = better</sup>"
            ),
            font=dict(size=18, family=FONT_FAMILY, color=DARK),
        ),
        font=dict(family=FONT_FAMILY, size=12, color=DARK),
        plot_bgcolor=WHITE,
        paper_bgcolor=WHITE,
        width=1200,
        height=max(350, n_rows * 70 + 180),
        margin=dict(l=220, r=80, t=130, b=70),
        barmode="stack",
        xaxis=dict(
            title="Time (seconds from first client failure)",
            showgrid=True,
            gridcolor="#ecf0f1",
        ),
        yaxis=dict(
            showgrid=False,
            categoryorder="array",
            categoryarray=list(reversed(combo_labels)),
        ),
        legend=dict(
            orientation="h",
            yanchor="bottom",
            y=1.08,
            xanchor="right",
            x=1,
        ),
    )
    return fig


# ---------------------------------------------------------------------------
# Chart 3: Recovery progress — one step-function line per combination
# X = time from first failure, Y = milestone index (0→4)
# shape="hv" draws "stay at milestone until next event, then jump"
# ---------------------------------------------------------------------------
def build_recovery_progress_chart(
    combo_data: list[dict], n_iterations: int
) -> go.Figure:
    fig = go.Figure()

    for idx, d in enumerate(combo_data):
        color = COMBO_PALETTE[idx % len(COMBO_PALETTE)]
        ph    = d["stats"]["phases"]

        def _mean(phase):
            s = ph[phase]
            return s["mean"] if s["mean"] is not None else 0.0

        t_dcs     = _mean("DCS Detection")
        t_promo   = _mean("Patroni Promotion")
        t_routing = _mean("Routing Detection")
        t_client  = _mean("Client Recovery")

        # Cumulative x-coordinates for each milestone
        x = [
            0.0,
            t_dcs,
            t_dcs + t_promo,
            t_dcs + t_promo + t_routing,
            t_dcs + t_promo + t_routing + t_client,
        ]
        y = [0, 1, 2, 3, 4]

        # Hover text per point
        dt_stats = d["stats"]["downtime"]
        total_s  = dt_stats["mean"]
        total_str = f"{total_s:.2f}s" if total_s is not None else "N/A"

        hover = [
            f"<b>{d['combination_id']}</b><br>Failure (t=0)",
            f"<b>{d['combination_id']}</b><br>DCS Detected @ t={x[1]:.2f}s",
            f"<b>{d['combination_id']}</b><br>Patroni Promoted @ t={x[2]:.2f}s",
            f"<b>{d['combination_id']}</b><br>Routing Updated @ t={x[3]:.2f}s",
            f"<b>{d['combination_id']}</b><br>Client Recovered @ t={x[4]:.2f}s<br>Total downtime: {total_str}",
        ]

        fig.add_trace(go.Scatter(
            x=x,
            y=y,
            mode="lines+markers",
            name=d["combination_id"],
            line=dict(color=color, width=2.5, shape="hv"),
            marker=dict(size=9, color=color,
                        line=dict(color=WHITE, width=1.5)),
            hovertext=hover,
            hoverinfo="text",
        ))

    fig.update_layout(
        title=dict(
            text=(
                "Failover Recovery Progress — Cross-Combination Comparison<br>"
                f"<sup>Mean milestones across up to {n_iterations} iterations"
                " | leftward = faster recovery</sup>"
            ),
            font=dict(size=18, family=FONT_FAMILY, color=DARK),
        ),
        font=dict(family=FONT_FAMILY, size=12, color=DARK),
        plot_bgcolor=WHITE,
        paper_bgcolor=WHITE,
        width=1200,
        height=500,
        margin=dict(l=60, r=60, t=120, b=80),
        xaxis=dict(
            title="Seconds from first client failure",
            showgrid=True,
            gridcolor="#ecf0f1",
            rangemode="tozero",
        ),
        yaxis=dict(
            title="Recovery milestone",
            tickvals=[0, 1, 2, 3, 4],
            ticktext=MILESTONE_LABELS,
            showgrid=True,
            gridcolor="#ecf0f1",
            range=[-0.3, 4.3],
        ),
        legend=dict(
            orientation="v",
            yanchor="middle",
            y=0.5,
            xanchor="left",
            x=1.02,
        ),
    )
    return fig


# ---------------------------------------------------------------------------
# CSV summary table
# ---------------------------------------------------------------------------
def write_csv(combo_data: list[dict], output_path: str):
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([
            "combination_id", "iterations_valid",
            "mean_downtime_s", "median_s", "stddev_s",
            "mean_dcs_s", "mean_promotion_s", "mean_routing_s", "mean_client_s",
        ])
        for d in combo_data:
            dt = d["stats"]["downtime"]
            ph = d["stats"]["phases"]

            def _fmt(val) -> str:
                return f"{val:.3f}" if val is not None else ""

            writer.writerow([
                d["combination_id"],
                dt["n"],
                _fmt(dt["mean"]),
                _fmt(dt["median"]),
                _fmt(dt["stddev"]),
                _fmt(ph["DCS Detection"]["mean"]),
                _fmt(ph["Patroni Promotion"]["mean"]),
                _fmt(ph["Routing Detection"]["mean"]),
                _fmt(ph["Client Recovery"]["mean"]),
            ])
    print(f"  Saved: {output_path}")


# ---------------------------------------------------------------------------
# Export helper — mirrors generate_gantt.py
# ---------------------------------------------------------------------------
def _kaleido_major_version() -> int:
    try:
        import kaleido
        return int(getattr(kaleido, "__version__", "0").split(".")[0])
    except Exception:
        return 0


def save_figure(fig, output_path: str, fmt: str = "png"):
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    if fmt == "html":
        fig.write_html(output_path, include_plotlyjs="cdn")
        print(f"  Saved: {output_path}")
        return

    scale = None if fmt == "svg" else 2
    if _kaleido_major_version() >= 1:
        import plotly.io as pio
        img = pio.to_image(fig, format=fmt, scale=scale)
        with open(output_path, "wb") as f:
            f.write(img)
    else:
        if fmt == "svg":
            fig.write_image(output_path, format="svg")
        else:
            fig.write_image(output_path, scale=2)
    print(f"  Saved: {output_path}")


# ---------------------------------------------------------------------------
# Console summary table
# ---------------------------------------------------------------------------
def print_summary_table(combo_data: list[dict]):
    col_w = 42
    header = (
        f"{'Combination':<{col_w}} {'N':>3}  "
        f"{'Mean':>7}  {'Median':>7}  {'Stddev':>7}  "
        f"{'DCS':>7}  {'Promo':>7}  {'Route':>7}  {'Client':>7}"
    )
    sep = "-" * len(header)
    print()
    print(header)
    print(sep)

    for d in combo_data:
        dt = d["stats"]["downtime"]
        ph = d["stats"]["phases"]

        def _s(val) -> str:
            return f"{val:.2f}" if val is not None else "   N/A"

        print(
            f"{d['combination_id']:<{col_w}} {dt['n']:>3}  "
            f"{_s(dt['mean']):>7}  {_s(dt['median']):>7}  {_s(dt['stddev']):>7}  "
            f"{_s(ph['DCS Detection']['mean']):>7}  "
            f"{_s(ph['Patroni Promotion']['mean']):>7}  "
            f"{_s(ph['Routing Detection']['mean']):>7}  "
            f"{_s(ph['Client Recovery']['mean']):>7}"
        )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Generate cross-combination failover comparison charts"
    )
    parser.add_argument(
        "--combinations",
        required=True,
        help="Comma-separated combination IDs, e.g. 06-haproxy-rest-polling,02-consul-dns",
    )
    parser.add_argument(
        "--output",
        default="comparison_chart.png",
        help=(
            "Output file base name; used as stem for derived chart filenames "
            "(default: comparison_chart.png). All files are saved under "
            "dashboard/charts/output/comparison/."
        ),
    )
    parser.add_argument(
        "--iterations",
        type=int,
        default=5,
        help="Use last N successful test runs per combination (default: 5)",
    )
    parser.add_argument(
        "--format",
        default="png",
        choices=["png", "svg", "html"],
        help="Output format for chart files (default: png)",
    )
    args = parser.parse_args()

    combinations = [c.strip() for c in args.combinations.split(",") if c.strip()]
    if not combinations:
        print("Error: --combinations must be a non-empty comma-separated list.")
        sys.exit(1)

    fmt      = args.format
    out_dir  = Path(__file__).parent / "output" / "comparison"
    out_stem = Path(args.output).stem  # e.g. "comparison_chart"
    out_dir.mkdir(parents=True, exist_ok=True)

    # --- Connect ---
    try:
        conn = get_connection()
    except Exception as e:
        print(f"Error connecting to TimescaleDB: {e}")
        sys.exit(1)

    print(f"Connected to TimescaleDB")
    print(f"Combinations : {combinations}")
    print(f"Max iterations: {args.iterations}")
    print(f"Output dir   : {out_dir}")
    print()

    # --- Fetch and aggregate per combination ---
    print("Fetching data...")
    combo_data: list[dict] = []
    for cid in combinations:
        result = aggregate_combination(conn, cid, args.iterations)
        if result:
            combo_data.append(result)

    conn.close()

    if not combo_data:
        print("No usable data found. Make sure the combinations have run and have test_runs entries.")
        sys.exit(1)

    n = len(combo_data)
    print(f"\nBuilding charts for {n} combination(s)...")

    # --- Chart 1: Grouped bar ---
    print("\n--- Grouped bar chart (phase durations) ---")
    bar_path = str(out_dir / f"{out_stem}_grouped.{fmt}")
    save_figure(build_grouped_bar_chart(combo_data, args.iterations), bar_path, fmt)

    # --- Chart 2: Phase timeline (stacked horizontal bars) ---
    print("\n--- Phase timeline chart ---")
    timeline_path = str(out_dir / f"{out_stem}_timeline.{fmt}")
    save_figure(
        build_phase_timeline_chart(combo_data, args.iterations), timeline_path, fmt
    )

    # --- Chart 3: Recovery progress step-function lines ---
    print("\n--- Recovery progress chart (overlapping lines) ---")
    progress_path = str(out_dir / f"{out_stem}_progress.{fmt}")
    save_figure(
        build_recovery_progress_chart(combo_data, args.iterations), progress_path, fmt
    )

    # --- CSV ---
    print("\n--- CSV summary ---")
    csv_path = str(out_dir / f"{out_stem}_summary.csv")
    write_csv(combo_data, csv_path)

    # --- Console summary ---
    print_summary_table(combo_data)

    print(f"\nAll outputs saved to: {out_dir}")
    print("Done!")


if __name__ == "__main__":
    main()
