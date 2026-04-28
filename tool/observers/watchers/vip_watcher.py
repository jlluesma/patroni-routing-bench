"""
patroni-failover-observer: VIP watcher

Monitors VIP (Virtual IP) binding events on the network interface.
Suitable for vip-manager and BGP/Anycast routing setups.

Emits events when:
  - A VIP address is bound to the interface
  - A VIP address is removed from the interface

Environment variables:
    VIP_ADDRESS   - The virtual IP to watch (e.g., 192.168.100.100)
    VIP_INTERFACE - Network interface to monitor (default: eth0)

Note: This watcher requires iproute2 (ip command) in the container.
"""

import os
import subprocess
import logging

from core.watcher import BaseWatcher

logger = logging.getLogger("watcher.vip")


class VIPWatcher(BaseWatcher):

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.vip_address = os.environ.get("VIP_ADDRESS", "")
        self.vip_interface = os.environ.get("VIP_INTERFACE", "eth0")
        self._last_bound = None

    def setup(self):
        if not self.vip_address:
            logger.warning("VIP_ADDRESS not set, watcher will monitor all IPs")
        logger.info(
            f"VIP watcher monitoring {self.vip_address} "
            f"on {self.vip_interface}"
        )
        self._check_vip(emit_initial=True)

    def poll(self):
        self._check_vip(emit_initial=False)

    def _check_vip(self, emit_initial: bool = False):
        try:
            result = subprocess.run(
                ["ip", "addr", "show", self.vip_interface],
                capture_output=True,
                text=True,
                timeout=5,
            )

            is_bound = self.vip_address in result.stdout if self.vip_address else False

            if is_bound != self._last_bound:
                if self._last_bound is not None or emit_initial:
                    self.emitter.emit_now(
                        event_type="vip_state_change",
                        old_value="bound" if self._last_bound else "unbound",
                        new_value="bound" if is_bound else "unbound",
                        detail=f"VIP {self.vip_address} on {self.vip_interface}",
                    )
                self._last_bound = is_bound

        except subprocess.TimeoutExpired:
            logger.warning("ip addr command timed out")
        except FileNotFoundError:
            logger.error("ip command not found - install iproute2")
