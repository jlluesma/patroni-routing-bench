"""
patroni-routing-bench: PostgreSQL SQL watcher

Monitors PostgreSQL state by connecting directly via SQL (no log file needed).
Works remotely — connects to each node over the network.

Detects:
  - pg_promote_detected: node transitions from recovery to primary
    (pg_is_in_recovery() changes from true to false)
  - pg_ready_accept_connections: node accepts SQL connections after being down
  - pg_connection_lost: node stops accepting connections
  - pg_timeline_change: timeline_id changes (promotion indicator)

Environment variables:
    PG_CONNSTRING  - PostgreSQL connection string for direct node connection
                     (NOT through routing layer — connect to the node directly)
                     Example: host=10.0.1.11 port=5432 dbname=postgres user=postgres password=xxx

Multi-target mode:
    WATCHER_TARGETS - Comma-separated name:connstring pairs
                      Example: node1:host=10.0.1.11 port=5432 ...,node2:host=10.0.1.12 port=5432 ...

Note: This watcher connects to PostgreSQL nodes DIRECTLY, not through
the routing layer. The routing layer is what the CLIENT measures.
This watcher measures what PostgreSQL itself is doing during failover.
"""

import os
import json
import logging

from core.watcher import BaseWatcher

logger = logging.getLogger("watcher.postgres_sql")


class PostgresSQLWatcher(BaseWatcher):

    def __init__(self, pg_connstring: str = None, **kwargs):
        super().__init__(**kwargs)
        self.pg_connstring = pg_connstring or os.environ.get(
            "PG_CONNSTRING",
            "host=localhost port=5432 dbname=postgres user=postgres"
        )
        self._last_in_recovery = None
        self._last_timeline = None
        self._last_reachable = None

    def setup(self):
        logger.info(f"PostgreSQL SQL watcher targeting: {self._safe_connstring()}")
        self._poll_state(emit_initial=True)

    def poll(self):
        self._poll_state(emit_initial=False)

    def teardown(self):
        pass

    def _safe_connstring(self):
        """Return connection string with password masked."""
        parts = self.pg_connstring.split()
        return " ".join(
            "password=***" if p.startswith("password=") else p
            for p in parts
        )

    def _connect(self):
        """Establish a connection to PostgreSQL."""
        try:
            import psycopg
            return psycopg.connect(
                self.pg_connstring,
                autocommit=True,
                connect_timeout=3,
            )
        except ImportError:
            import psycopg2
            conn = psycopg2.connect(self.pg_connstring)
            conn.autocommit = True
            return conn

    def _poll_state(self, emit_initial: bool = False):
        try:
            conn = self._connect()
            cur = conn.cursor()

            cur.execute("""
                SELECT pg_is_in_recovery(),
                       timeline_id
                FROM pg_control_checkpoint()
            """)
            row = cur.fetchone()
            in_recovery = row[0]
            timeline = row[1]

            cur.execute("""
                SELECT count(*) FROM pg_stat_activity
                WHERE state IS NOT NULL
            """)
            conn_count = cur.fetchone()[0]

            cur.close()
            conn.close()

            # Detect: node was unreachable, now it's back
            if self._last_reachable is False:
                self.emitter.emit_now(
                    event_type="pg_ready_accept_connections",
                    old_value="unreachable",
                    new_value="accepting_connections",
                    detail=json.dumps({
                        "in_recovery": in_recovery,
                        "timeline": timeline,
                        "connections": conn_count,
                    }),
                )
            self._last_reachable = True

            # Detect: promotion (in_recovery: true -> false)
            if in_recovery != self._last_in_recovery:
                if self._last_in_recovery is not None or emit_initial:
                    if self._last_in_recovery is True and in_recovery is False:
                        self.emitter.emit_now(
                            event_type="pg_promote_detected",
                            old_value="in_recovery",
                            new_value="primary",
                            detail=json.dumps({
                                "timeline": timeline,
                                "connections": conn_count,
                            }),
                        )
                    elif self._last_in_recovery is False and in_recovery is True:
                        self.emitter.emit_now(
                            event_type="pg_demote_detected",
                            old_value="primary",
                            new_value="in_recovery",
                            detail=json.dumps({
                                "timeline": timeline,
                                "connections": conn_count,
                            }),
                        )
                    elif emit_initial:
                        self.emitter.emit_now(
                            event_type="pg_state_detected",
                            old_value="none",
                            new_value="primary" if not in_recovery else "in_recovery",
                            detail=json.dumps({
                                "timeline": timeline,
                                "connections": conn_count,
                            }),
                        )
                self._last_in_recovery = in_recovery

            # Detect: timeline change
            if timeline != self._last_timeline:
                if self._last_timeline is not None:
                    self.emitter.emit_now(
                        event_type="pg_timeline_change",
                        old_value=str(self._last_timeline),
                        new_value=str(timeline),
                        detail=json.dumps({
                            "in_recovery": in_recovery,
                            "connections": conn_count,
                        }),
                    )
                self._last_timeline = timeline

        except Exception as e:
            if self._last_reachable is not False:
                if self._last_reachable is not None:
                    self.emitter.emit_now(
                        event_type="pg_connection_lost",
                        old_value="accepting_connections",
                        new_value="unreachable",
                        detail=str(e)[:200],
                    )
                self._last_reachable = False
