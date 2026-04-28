"""
patroni-routing-bench: heartbeat client

Continuously attempts INSERT queries against the PostgreSQL cluster and records
per-query timing with microsecond precision. Each query attempt is logged with:
  - timestamp (monotonic + wall clock)
  - success/failure
  - latency
  - error details (if any)

Results are pushed to TimescaleDB via the reporter module.

Usage:
    python heartbeat.py

Environment variables:
    PG_CONNSTRING     - PostgreSQL connection string (required)
    TIMESCALE_CONNSTRING - TimescaleDB connection string for results (required)
    COMBINATION_ID    - Identifier for the current combination (e.g., "06")
    TEST_RUN_ID       - Unique identifier for this test run
    INTERVAL_MS       - Milliseconds between queries (default: 100)
"""

import os
import sys
import time
import signal
import logging
from datetime import datetime, timezone
from dataclasses import dataclass, field

import psycopg

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S%z",
)
logger = logging.getLogger("heartbeat")


@dataclass
class QueryResult:
    """Result of a single heartbeat query attempt."""
    wall_ts: datetime
    mono_ns: int
    success: bool
    latency_us: int
    error: str = ""
    sequence: int = 0


class HeartbeatClient:
    """
    Runs a continuous INSERT loop against PostgreSQL, recording the outcome
    of every query attempt for failover analysis.
    """

    def __init__(self):
        self.pg_connstring = os.environ.get("PG_CONNSTRING", "")
        self.timescale_connstring = os.environ.get("TIMESCALE_CONNSTRING", "")
        self.combination_id = os.environ.get("COMBINATION_ID", "unknown")
        self.test_run_id = os.environ.get("TEST_RUN_ID", "")
        self.interval_ms = int(os.environ.get("INTERVAL_MS", "100"))

        if not self.pg_connstring:
            logger.error("PG_CONNSTRING is required")
            sys.exit(1)

        self.running = True
        self.sequence = 0
        self.results: list[QueryResult] = []
        self.batch_size = 50  # flush to TimescaleDB every N results

        signal.signal(signal.SIGINT, self._shutdown)
        signal.signal(signal.SIGTERM, self._shutdown)

    def _shutdown(self, signum, frame):
        logger.info(f"Received signal {signum}, shutting down...")
        self.running = False

    def _ensure_heartbeat_table(self, conn):
        """Create the heartbeat target table if it doesn't exist."""
        conn.execute("""
            CREATE TABLE IF NOT EXISTS heartbeat (
                id BIGSERIAL PRIMARY KEY,
                ts TIMESTAMPTZ NOT NULL DEFAULT now(),
                client_ts TIMESTAMPTZ NOT NULL,
                sequence BIGINT NOT NULL
            )
        """)
        conn.commit()

    def _attempt_query(self) -> QueryResult:
        """Execute a single heartbeat INSERT and measure timing."""
        self.sequence += 1
        wall_ts = datetime.now(timezone.utc)
        mono_start = time.monotonic_ns()

        try:
            with psycopg.connect(self.pg_connstring, autocommit=True,
                                 connect_timeout=5) as conn:
                self._ensure_heartbeat_table(conn)
                conn.execute(
                    "INSERT INTO heartbeat (client_ts, sequence) VALUES (%s, %s)",
                    (wall_ts, self.sequence),
                )

            mono_end = time.monotonic_ns()
            latency_us = (mono_end - mono_start) // 1000

            return QueryResult(
                wall_ts=wall_ts,
                mono_ns=mono_start,
                success=True,
                latency_us=latency_us,
                sequence=self.sequence,
            )

        except Exception as e:
            mono_end = time.monotonic_ns()
            latency_us = (mono_end - mono_start) // 1000

            return QueryResult(
                wall_ts=wall_ts,
                mono_ns=mono_start,
                success=False,
                latency_us=latency_us,
                error=str(e)[:500],
                sequence=self.sequence,
            )

    def _flush_results(self):
        """Send accumulated results to TimescaleDB."""
        if not self.results or not self.timescale_connstring:
            self.results.clear()
            return

        try:
            with psycopg.connect(self.timescale_connstring, autocommit=True) as conn:
                with conn.cursor() as cur:
                    for r in self.results:
                        cur.execute(
                            """
                            INSERT INTO client_events
                                (ts, combination_id, test_run_id, sequence,
                                 success, latency_us, error)
                            VALUES (%s, %s, %s, %s, %s, %s, %s)
                            """,
                            (r.wall_ts, self.combination_id, self.test_run_id,
                             r.sequence, r.success, r.latency_us, r.error),
                        )
            self.results.clear()
        except Exception as e:
            logger.warning(f"Failed to flush results to TimescaleDB: {e}")

    def run(self):
        """Main heartbeat loop."""
        logger.info(f"Starting heartbeat client")
        logger.info(f"  Combination: {self.combination_id}")
        logger.info(f"  Test run:    {self.test_run_id}")
        logger.info(f"  Interval:    {self.interval_ms}ms")
        logger.info(f"  Target:      {self.pg_connstring[:60]}...")

        interval_s = self.interval_ms / 1000.0
        success_count = 0
        failure_count = 0

        while self.running:
            result = self._attempt_query()
            self.results.append(result)

            if result.success:
                success_count += 1
            else:
                failure_count += 1
                logger.warning(
                    f"seq={result.sequence} FAIL latency={result.latency_us}us "
                    f"error={result.error[:100]}"
                )

            # Periodic status log
            if self.sequence % 100 == 0:
                total = success_count + failure_count
                rate = (success_count / total * 100) if total else 0
                logger.info(
                    f"seq={self.sequence} success={success_count} "
                    f"fail={failure_count} rate={rate:.1f}%"
                )

            # Flush batch to TimescaleDB
            if len(self.results) >= self.batch_size:
                self._flush_results()

            time.sleep(interval_s)

        # Final flush
        self._flush_results()
        logger.info(
            f"Shutdown complete. Total: {success_count + failure_count} "
            f"queries, {success_count} success, {failure_count} failures"
        )


if __name__ == "__main__":
    client = HeartbeatClient()
    client.run()
