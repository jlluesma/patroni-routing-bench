"""
patroni-failover-observer: HAProxy watcher

Monitors HAProxy backend server states via the stats interface.
Emits events when backend servers transition between UP/DOWN/MAINT states.

Supports two modes:
  - Stats URL (CSV endpoint): http://haproxy:8404/stats;csv
  - Stats socket (future): /var/run/haproxy/admin.sock

Environment variables:
    HAPROXY_STATS_URL  - HAProxy stats CSV URL (e.g., http://haproxy:8404/stats;csv)
"""

import os
import csv
import io
import json
import logging

import requests

from core.watcher import BaseWatcher

logger = logging.getLogger("watcher.haproxy")


class HAProxyWatcher(BaseWatcher):

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.stats_url = os.environ.get(
            "HAPROXY_STATS_URL", "http://localhost:8404/stats;csv"
        )
        # Track state per backend server: {(backend, server): status}
        self._server_states: dict[tuple[str, str], str] = {}

    def setup(self):
        logger.info(f"HAProxy watcher targeting: {self.stats_url}")
        self._poll_stats(emit_initial=True)

    def poll(self):
        self._poll_stats(emit_initial=False)

    def _poll_stats(self, emit_initial: bool = False):
        try:
            resp = requests.get(self.stats_url, timeout=3)
            resp.raise_for_status()
        except requests.RequestException as e:
            logger.warning(f"HAProxy stats request failed: {e}")
            return

        # Parse CSV stats
        # HAProxy CSV starts with "# " header line
        content = resp.text
        if content.startswith("# "):
            content = content[2:]  # strip leading "# "

        reader = csv.DictReader(io.StringIO(content))

        current_states: dict[tuple[str, str], str] = {}

        for row in reader:
            pxname = row.get("pxname", "")   # backend/frontend name
            svname = row.get("svname", "")   # server name
            status = row.get("status", "")   # UP, DOWN, MAINT, etc.

            # Skip frontends and stats, focus on backend servers
            if svname in ("FRONTEND", "BACKEND", ""):
                continue

            key = (pxname, svname)
            current_states[key] = status

            # Detect state change
            prev_status = self._server_states.get(key)
            if status != prev_status:
                if prev_status is not None or emit_initial:
                    self.emitter.emit_now(
                        event_type="backend_state_change",
                        old_value=prev_status or "none",
                        new_value=status,
                        detail=json.dumps({
                            "backend": pxname,
                            "server": svname,
                            "check_status": row.get("check_status", ""),
                            "check_duration": row.get("check_duration", ""),
                            "last_chk": row.get("last_chk", ""),
                        }),
                    )

        self._server_states = current_states
