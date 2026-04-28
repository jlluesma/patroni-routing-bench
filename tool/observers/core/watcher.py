"""
patroni-routing-bench: base watcher

Abstract base class for all component watchers. Each watcher implements
a polling loop that detects state changes in its component and emits
events through the Emitter.

Subclasses must implement:
    - setup()       : one-time initialization (validate connectivity, etc.)
    - poll()        : single poll iteration, called every poll_interval_ms
    - teardown()    : cleanup on shutdown
"""

import time
import logging
from abc import ABC, abstractmethod

from core.emitter import Emitter

logger = logging.getLogger("watcher")


class BaseWatcher(ABC):
    """Abstract base class for component watchers."""

    def __init__(self, emitter: Emitter, poll_interval_ms: int = 200):
        self.emitter = emitter
        self.poll_interval_ms = poll_interval_ms
        self._running = False

    @abstractmethod
    def setup(self):
        """Initialize the watcher. Called once before the poll loop starts."""
        ...

    @abstractmethod
    def poll(self):
        """
        Execute a single poll iteration.
        Should detect state changes and call self.emitter.emit_now() for each.
        """
        ...

    def teardown(self):
        """Cleanup on shutdown. Override if needed."""
        pass

    def stop(self):
        """Signal the watcher to stop."""
        self._running = False

    def run(self):
        """Main polling loop."""
        self._running = True
        logger.info(
            f"Starting {self.__class__.__name__} "
            f"(poll interval: {self.poll_interval_ms}ms)"
        )

        try:
            self.setup()
        except Exception as e:
            logger.error(f"Setup failed: {e}", exc_info=True)
            raise

        interval_s = self.poll_interval_ms / 1000.0

        while self._running:
            try:
                self.poll()
            except Exception as e:
                logger.warning(f"Poll error: {e}")

            time.sleep(interval_s)

        try:
            self.teardown()
        except Exception as e:
            logger.warning(f"Teardown error: {e}")

        logger.info(f"{self.__class__.__name__} stopped.")
