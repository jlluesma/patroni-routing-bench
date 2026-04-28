"""
patroni-failover-observer: observer agent

Main daemon that loads the appropriate watcher based on OBSERVER_COMPONENT
and pushes timestamped state-change events to TimescaleDB.

Each watcher monitors a specific component (Patroni, Consul, HAProxy, VIP, PostgreSQL)
and emits events through the common Emitter interface.

Usage:
    python -m core.agent

Environment variables:
    OBSERVER_COMPONENT    - Which watcher to load: patroni|consul|haproxy|vip|postgres
    TIMESCALE_CONNSTRING  - TimescaleDB connection string for events
    COMBINATION_ID        - Identifier for the current combination
    TEST_RUN_ID           - Unique identifier for this test run
    NODE_NAME             - Name of the node being observed (single-target mode)
    POLL_INTERVAL_MS      - Polling interval in milliseconds (default: 200)

    Multi-target mode (patroni and postgres only):
    WATCHER_TARGETS       - Comma-separated list of "node_name:target" pairs.
                            Spawns one watcher thread per target, each emitting
                            events with its own node_name.
                            Examples:
                              patroni: "patroni-node1:http://patroni-node1:8008,..."
                              postgres: "patroni-node1:/var/log/pg1/postgresql.log,..."
                            When set, NODE_NAME is ignored for event labelling.

    Component-specific (single-target mode, passed through to watcher):
    PATRONI_URL           - Patroni REST API URL (for patroni watcher)
    CONSUL_URL            - Consul HTTP API URL (for consul watcher)
    HAPROXY_STATS_SOCKET  - HAProxy stats socket path (for haproxy watcher)
    HAPROXY_STATS_URL     - HAProxy stats URL (for haproxy watcher)
    PG_LOG_PATH           - PostgreSQL log file path (for postgres watcher)
"""

import os
import sys
import signal
import logging
import threading
import importlib

from core.emitter import Emitter

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [%(name)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S%z",
)
logger = logging.getLogger("observer")

# Registry of available watchers
WATCHER_REGISTRY = {
    "patroni": "watchers.patroni_watcher.PatroniWatcher",
    "consul": "watchers.consul_watcher.ConsulWatcher",
    "haproxy": "watchers.haproxy_watcher.HAProxyWatcher",
    "vip": "watchers.vip_watcher.VIPWatcher",
    "postgres": "watchers.postgres_sql_watcher.PostgresSQLWatcher",
}

# Constructor kwarg used to pass the per-target value in multi-target mode.
# Components not listed here do not support WATCHER_TARGETS.
WATCHER_TARGET_KWARG = {
    "patroni": "patroni_url",
    "postgres": "pg_connstring",
}


def load_watcher_class(component: str):
    """Dynamically load a watcher class from the registry."""
    if component not in WATCHER_REGISTRY:
        logger.error(
            f"Unknown component: {component}. "
            f"Available: {', '.join(WATCHER_REGISTRY.keys())}"
        )
        sys.exit(1)

    module_path, class_name = WATCHER_REGISTRY[component].rsplit(".", 1)

    try:
        module = importlib.import_module(module_path)
        return getattr(module, class_name)
    except (ImportError, AttributeError) as e:
        logger.error(f"Failed to load watcher for {component}: {e}")
        sys.exit(1)


def _parse_targets(targets_str: str) -> list[tuple[str, str]]:
    """
    Parse WATCHER_TARGETS into (node_name, target) pairs.

    Format: "name1:value1,name2:value2,..."
    The split uses partition(":") so values containing colons (URLs) are safe.
    """
    result = []
    for item in targets_str.split(","):
        item = item.strip()
        if not item:
            continue
        name, sep, value = item.partition(":")
        if not sep:
            logger.warning(f"Ignoring malformed WATCHER_TARGETS entry: {item!r}")
            continue
        result.append((name.strip(), value.strip()))
    return result


def _run_multi_target(
    component: str,
    watcher_class,
    targets: list[tuple[str, str]],
    target_kwarg: str,
    timescale_connstring: str,
    combination_id: str,
    test_run_id: str,
    poll_interval_ms: int,
):
    """Spawn one watcher thread per target; block until all finish."""
    watchers = []
    emitters = []
    threads = []

    for node_name, target in targets:
        em = Emitter(
            timescale_connstring=timescale_connstring,
            combination_id=combination_id,
            test_run_id=test_run_id,
            node_name=node_name,
            component=component,
        )
        w = watcher_class(
            emitter=em,
            poll_interval_ms=poll_interval_ms,
            **{target_kwarg: target},
        )
        emitters.append(em)
        watchers.append(w)
        t = threading.Thread(
            target=w.run,
            daemon=True,
            name=f"watcher-{node_name}",
        )
        threads.append(t)
        logger.info(f"  Target: {node_name} → {target}")

    def shutdown(signum, frame):
        logger.info(f"Received signal {signum}, shutting down all watchers...")
        for w in watchers:
            w.stop()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    for t in threads:
        t.start()
    for t in threads:
        t.join()
    for em in emitters:
        em.stop()


def main():
    component = os.environ.get("OBSERVER_COMPONENT", "")
    if not component:
        logger.error("OBSERVER_COMPONENT is required")
        sys.exit(1)

    timescale_connstring = os.environ.get("TIMESCALE_CONNSTRING", "")
    combination_id = os.environ.get("COMBINATION_ID", "")
    if not combination_id:
        logger.error("COMBINATION_ID is required")
        sys.exit(1)
    test_run_id = os.environ.get("TEST_RUN_ID", "")
    node_name = os.environ.get("NODE_NAME", "unknown")
    poll_interval_ms = int(os.environ.get("POLL_INTERVAL_MS", "200"))
    watcher_targets_str = os.environ.get("WATCHER_TARGETS", "")

    logger.info("Starting observer agent")
    logger.info(f"  Component:    {component}")
    logger.info(f"  Combination:  {combination_id}")
    logger.info(f"  Poll interval: {poll_interval_ms}ms")

    watcher_class = load_watcher_class(component)

    # Multi-target mode: WATCHER_TARGETS overrides single NODE_NAME / URL env vars.
    if watcher_targets_str and component in WATCHER_TARGET_KWARG:
        targets = _parse_targets(watcher_targets_str)
        if not targets:
            logger.error("WATCHER_TARGETS is set but contains no valid entries")
            sys.exit(1)
        logger.info(f"  Mode: multi-target ({len(targets)} targets)")
        _run_multi_target(
            component=component,
            watcher_class=watcher_class,
            targets=targets,
            target_kwarg=WATCHER_TARGET_KWARG[component],
            timescale_connstring=timescale_connstring,
            combination_id=combination_id,
            test_run_id=test_run_id,
            poll_interval_ms=poll_interval_ms,
        )
        logger.info("Observer agent stopped.")
        return

    # Single-target mode (original behaviour, unchanged).
    if watcher_targets_str and component not in WATCHER_TARGET_KWARG:
        logger.warning(
            f"WATCHER_TARGETS is set but component '{component}' does not support "
            "multi-target mode — falling back to single-target"
        )

    logger.info(f"  Mode: single-target")
    logger.info(f"  Node: {node_name}")
    logger.info(f"  Test run: {test_run_id}")

    emitter = Emitter(
        timescale_connstring=timescale_connstring,
        combination_id=combination_id,
        test_run_id=test_run_id,
        node_name=node_name,
        component=component,
    )

    watcher = watcher_class(emitter=emitter, poll_interval_ms=poll_interval_ms)

    def shutdown(signum, frame):
        logger.info(f"Received signal {signum}, shutting down...")
        watcher.stop()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    try:
        watcher.run()
    except Exception as e:
        logger.error(f"Watcher crashed: {e}", exc_info=True)
        sys.exit(1)
    finally:
        emitter.stop()
        logger.info("Observer agent stopped.")


if __name__ == "__main__":
    main()
