# charts — Unified Chart Generation

Single entry point for all chart generation in this project.

- `generate_charts.py` — three subcommands: per-iteration Gantt charts, per-combination HTML reports, and cross-combination batch reports
- Runs inside the `charts` Docker container (defined in `dashboard/docker-compose.yml`)

---

## Usage

All chart generation runs via the `charts` service in the dashboard compose stack.

```bash
# Per-iteration Gantt chart (called by runner after each iteration)
docker compose --profile charts run --rm charts iteration \
    --test-run-id <UUID> \
    --output-dir /results/<session>/charts

# Per-combination HTML report (called by runner after a session)
docker compose --profile charts run --rm charts combo-report \
    --combination-id 06-haproxy-rest-polling \
    --session-dir /results/<session> \
    --output /results/<session>/report.html

# Cross-combination batch report
docker compose --profile charts run --rm charts batch-report \
    --batch-csv /results/batch_<ts>/results.csv \
    --batch-dir /results/batch_<ts> \
    --output /results/batch_<ts>/batch_report.html
```

The container mounts `runner/results` at `/results`. Host paths under `runner/results/` map to `/results/` inside the container.

---

## Subcommands

### `iteration`

Generates a Gantt chart for a single test run.

| Argument | Description |
|---|---|
| `--test-run-id ID` | UUID from the `test_runs` table |
| `--output-dir PATH` | Directory to write `gantt_<id>.html` into |

Reads `observer_events` and `client_events` from TimescaleDB. Produces an interactive Plotly HTML file showing the full event timeline for every component (Patroni, Consul, HAProxy/VIP, PostgreSQL, client).

### `combo-report`

Generates a multi-iteration HTML report for one combination session.

| Argument | Description |
|---|---|
| `--combination-id ID` | e.g. `06-haproxy-rest-polling` |
| `--session-dir PATH` | Path to the session folder (contains per-iteration charts) |
| `--output PATH` | Output HTML file path |

Includes: header with Patroni config summary, per-iteration sections (Gantt + phase breakdown), cross-iteration comparison chart.

### `batch-report`

Generates a cross-combination HTML report from a batch CSV.

| Argument | Description |
|---|---|
| `--batch-csv PATH` | CSV produced by `run_batch.sh` |
| `--batch-dir PATH` | Directory containing combo session subfolders |
| `--output PATH` | Output HTML file path |

Includes: heatmap (combo × scenario), scenario bar charts, leaderboard, waterfall phase stacks, per-combination summary tables.

---

## Charts produced

| Chart | Builder | Description |
|---|---|---|
| Gantt | `build_gantt_chart` | Multi-row timeline; each component gets a row, events coloured by state |
| Phase bar | `build_phase_chart` | Horizontal stacked bar: DCS Detection → Patroni Promotion → Routing Detection → Client Recovery |
| Overlap phase | `build_overlap_phase_chart` | Phases with real start/end times, highlights gap between Routing Detection end and Client Recovery start |
| Batch heatmap | `_render_batch_heatmap` | Grid: combo × scenario, cell = median downtime |
| Scenario bars | `_render_batch_scenario_bars` | Grouped bars: downtime by scenario across all combos |
| Leaderboard | `_render_batch_family_charts` | Ranked horizontal bars annotated with pass rate |
| Waterfall | `_render_batch_waterfall` | Stacked incremental phase durations per combo |

---

## Dependencies

| Package | Purpose |
|---|---|
| `plotly` | All charts (interactive HTML output) |
| `pandas` | Data manipulation and aggregation |
| `psycopg` | TimescaleDB queries (binary driver) |

`kaleido` is **not** used — all output is interactive HTML, never static images.

---

## Container

The `charts` service is defined under the `charts` profile in `dashboard/docker-compose.yml`. The dashboard stack must be running before generating charts:

```bash
cd dashboard && docker compose up -d
```

---

## Development (host Python)

```bash
cd dashboard/charts
pip install -r requirements.txt
TIMESCALE_HOST=localhost TIMESCALE_PORT=5433 \
python generate_charts.py iteration --test-run-id <UUID> --output-dir /tmp/out
```

`generate_comparison.py` is a separate standalone script for ad-hoc cross-combination comparisons; the runner does not call it.
