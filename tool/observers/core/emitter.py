"""
patroni-routing-bench: event emitter

Buffers and pushes timestamped state-change events to TimescaleDB.
All watchers use this common interface to emit events, ensuring a
consistent schema across all components.

Event schema:
    ts              - Wall clock timestamp (UTC, microsecond precision)
    combination_id  - Which routing combination is being tested
    test_run_id     - Unique identifier for this test run
    component       - Component type (patroni, consul, haproxy, vip, postgres)
    node            - Node name within the combination
    event_type      - Type of event (e.g., role_change, key_update, backend_switch)
    old_value       - Previous state value (if applicable)
    new_value       - New state value
    detail          - Additional JSON context
"""

import logging
import threading
from datetime import datetime, timezone
from dataclasses import dataclass, field

import psycopg

logger = logging.getLogger("emitter")


@dataclass
class Event:
    """A single state-change event from a component."""
    ts: datetime
    event_type: str
    new_value: str
    old_value: str = ""
    detail: str = ""


class Emitter:
    """
    Buffers events in memory and flushes them to TimescaleDB.
    A background daemon thread flushes every 1 second so that
    low-volume watchers (like Consul) never lose events in the buffer.
    """

    def __init__(
        self,
        timescale_connstring: str,
        combination_id: str,
        test_run_id: str,
        node_name: str,
        component: str,
        batch_size: int = 5,
    ):
        self.timescale_connstring = timescale_connstring
        self.combination_id = combination_id
        self.test_run_id = test_run_id
        self.node_name = node_name
        self.component = component
        self.batch_size = batch_size
        self._buffer: list[Event] = []
        self._lock = threading.Lock()
        self._stop_event = threading.Event()

        # Background flush thread — daemon so it won't block shutdown
        self._flush_thread = threading.Thread(
            target=self._flush_loop, daemon=True, name=f"emitter-flush-{component}"
        )
        self._flush_thread.start()

    def _flush_loop(self):
        """Background loop: flush pending events every 1 second."""
        while not self._stop_event.is_set():
            self._stop_event.wait(timeout=1.0)
            self.flush()

    def emit(self, event: Event):
        """
        Buffer an event. Automatically flushes when batch_size is reached.
        """
        with self._lock:
            self._buffer.append(event)
        logger.info(
            f"EVENT {event.event_type}: "
            f"{event.old_value} -> {event.new_value} "
            f"({event.detail[:100]})"
        )

        with self._lock:
            should_flush = len(self._buffer) >= self.batch_size
        if should_flush:
            self.flush()

    def emit_now(
        self,
        event_type: str,
        new_value: str,
        old_value: str = "",
        detail: str = "",
    ):
        """Convenience method: create and buffer an event with current timestamp."""
        event = Event(
            ts=datetime.now(timezone.utc),
            event_type=event_type,
            new_value=new_value,
            old_value=old_value,
            detail=detail,
        )
        self.emit(event)

    def flush(self):
        """Push all buffered events to TimescaleDB."""
        with self._lock:
            if not self._buffer:
                return
            events = list(self._buffer)
            self._buffer.clear()

        if not self.timescale_connstring:
            logger.debug(
                f"No TimescaleDB connection configured, "
                f"discarding {len(events)} events"
            )
            return

        try:
            with psycopg.connect(
                self.timescale_connstring, autocommit=True
            ) as conn:
                with conn.cursor() as cur:
                    for event in events:
                        cur.execute(
                            """
                            INSERT INTO observer_events
                                (ts, combination_id, test_run_id, component,
                                 node, event_type, old_value, new_value, detail)
                            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                            """,
                            (
                                event.ts,
                                self.combination_id,
                                self.test_run_id,
                                self.component,
                                self.node_name,
                                event.event_type,
                                event.old_value,
                                event.new_value,
                                event.detail,
                            ),
                        )
            logger.debug(f"Flushed {len(events)} events to TimescaleDB")

        except Exception as e:
            logger.warning(f"Failed to flush events to TimescaleDB: {e}")
            # Put events back so they're not lost
            with self._lock:
                self._buffer = events + self._buffer

    def stop(self):
        """Signal the flush thread to exit and perform a final flush."""
        self._stop_event.set()
        self._flush_thread.join(timeout=5)
        self.flush()
        logger.info("Emitter stopped.")
