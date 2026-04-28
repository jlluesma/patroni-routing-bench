"""
patroni-failover-observer: Consul watcher

Watches the Patroni leader key in Consul KV store for changes.
Uses Consul's blocking queries (long poll) for near-instant detection.

Emits events when:
  - The leader key value changes (new leader elected)
  - The leader key is deleted (leader lost)
  - The leader key is created (leader established)

Environment variables:
    CONSUL_URL    - Consul HTTP API URL (e.g., http://consul:8500)
    CONSUL_SCOPE  - Patroni scope/cluster name (required; no default)
"""

import os
import json
import logging

import requests

from core.watcher import BaseWatcher

logger = logging.getLogger("watcher.consul")


class ConsulWatcher(BaseWatcher):

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.consul_url = os.environ.get("CONSUL_URL", "http://localhost:8500")
        self.consul_scope = os.environ.get("CONSUL_SCOPE", "")
        if not self.consul_scope:
            self.consul_scope = "patroni"
            logger.warning("CONSUL_SCOPE not set; defaulting to 'patroni' — set explicitly for your cluster")
        self._last_leader = None
        self._last_modify_index = 0

    @property
    def leader_key_path(self) -> str:
        """Consul KV path for the Patroni leader key."""
        return f"service/{self.consul_scope}/leader"

    def setup(self):
        logger.info(f"Consul watcher targeting: {self.consul_url}")
        logger.info(f"  Leader key: {self.leader_key_path}")
        # Initial state capture (non-blocking)
        self._fetch_leader(blocking=False, emit_initial=True)

    def poll(self):
        # Use blocking query for near-instant detection
        # Consul will hold the request until the key changes or timeout
        self._fetch_leader(blocking=True, emit_initial=False)

    def _fetch_leader(self, blocking: bool = False, emit_initial: bool = False):
        try:
            params = {}
            timeout = 3

            if blocking and self._last_modify_index > 0:
                # Consul blocking query: wait up to 5s for changes
                # Consul will return immediately if ModifyIndex has changed
                params["index"] = self._last_modify_index
                params["wait"] = "5s"
                timeout = 10  # must be > Consul wait time

            resp = requests.get(
                f"{self.consul_url}/v1/kv/{self.leader_key_path}",
                params=params,
                timeout=timeout,
            )

            if resp.status_code == 404:
                # Key doesn't exist (no leader)
                if self._last_leader is not None:
                    self.emitter.emit_now(
                        event_type="leader_key_deleted",
                        old_value=self._last_leader,
                        new_value="",
                        detail="Leader key removed from Consul KV",
                    )
                    self._last_leader = None
                return

            resp.raise_for_status()
            data = resp.json()

            if not data:
                return

            entry = data[0]
            modify_index = entry.get("ModifyIndex", 0)

            # Decode the leader value (base64 encoded in Consul KV API)
            import base64
            leader_value = base64.b64decode(
                entry.get("Value", "")
            ).decode("utf-8", errors="replace")

            # Update modify index for next blocking query
            self._last_modify_index = modify_index

            # Detect leader change
            if leader_value != self._last_leader:
                detail = json.dumps({
                    "modify_index": modify_index,
                    "create_index": entry.get("CreateIndex"),
                    "session": entry.get("Session", ""),
                })

                if self._last_leader is None and not emit_initial:
                    # Key went from missing (404) to present → created
                    self.emitter.emit_now(
                        event_type="leader_key_created",
                        old_value="",
                        new_value=leader_value,
                        detail=detail,
                    )
                elif self._last_leader is not None or emit_initial:
                    # Key value changed (different leader name)
                    self.emitter.emit_now(
                        event_type="leader_key_change",
                        old_value=self._last_leader or "none",
                        new_value=leader_value,
                        detail=detail,
                    )
                self._last_leader = leader_value

        except requests.RequestException as e:
            logger.warning(f"Consul request failed: {e}")
        except (ValueError, KeyError, IndexError) as e:
            logger.warning(f"Failed to parse Consul response: {e}")
