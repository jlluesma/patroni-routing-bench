"""
patroni-failover-observer: Patroni watcher

Monitors the Patroni REST API (/patroni endpoint) for role changes.
Emits events when:
  - Node role changes (primary -> replica, replica -> primary)
  - Node state changes (running, starting, stopped, etc.)
  - Timeline changes (indicates promotion)

Environment variables:
    PATRONI_URL  - Patroni REST API base URL (e.g., http://patroni-node1:8008)
"""

import os
import json
import logging

import requests

from core.watcher import BaseWatcher

logger = logging.getLogger("watcher.patroni")


class PatroniWatcher(BaseWatcher):

    def __init__(self, patroni_url: str = None, **kwargs):
        super().__init__(**kwargs)
        self.patroni_url = patroni_url or os.environ.get("PATRONI_URL", "http://localhost:8008")
        self._last_role = None
        self._last_state = None
        self._last_timeline = None

    def setup(self):
        logger.info(f"Patroni watcher targeting: {self.patroni_url}")
        # Initial state capture
        self._poll_state(emit_initial=True)

    def poll(self):
        self._poll_state(emit_initial=False)

    def _poll_state(self, emit_initial: bool = False):
        try:
            resp = requests.get(
                f"{self.patroni_url}/patroni",
                timeout=2,
            )
            data = resp.json()
        except requests.RequestException as e:
            # Connection failure is itself a meaningful event
            if self._last_state != "unreachable":
                self.emitter.emit_now(
                    event_type="node_state_change",
                    old_value=self._last_state or "unknown",
                    new_value="unreachable",
                    detail=str(e)[:200],
                )
                self._last_state = "unreachable"
            return
        except (ValueError, KeyError) as e:
            logger.warning(f"Invalid response from Patroni API: {e}")
            return

        role = data.get("role", "unknown")
        state = data.get("state", "unknown")
        timeline = data.get("timeline")

        # Detect role change (the most important event)
        if role != self._last_role:
            if self._last_role is not None or emit_initial:
                self.emitter.emit_now(
                    event_type="role_change",
                    old_value=self._last_role or "none",
                    new_value=role,
                    detail=json.dumps({
                        "state": state,
                        "timeline": timeline,
                        "server_version": data.get("server_version"),
                    }),
                )
            self._last_role = role

        # Detect state change
        if state != self._last_state:
            if self._last_state is not None or emit_initial:
                self.emitter.emit_now(
                    event_type="node_state_change",
                    old_value=self._last_state or "none",
                    new_value=state,
                    detail=json.dumps({"role": role}),
                )
            self._last_state = state

        # Detect timeline change (promotion indicator)
        if timeline != self._last_timeline:
            if self._last_timeline is not None:
                self.emitter.emit_now(
                    event_type="timeline_change",
                    old_value=str(self._last_timeline),
                    new_value=str(timeline),
                    detail=json.dumps({"role": role, "state": state}),
                )
            self._last_timeline = timeline
