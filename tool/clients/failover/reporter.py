"""
patroni-routing-bench: reporter module

Handles pushing client-side events to TimescaleDB.
Currently the flush logic lives directly in heartbeat.py.
This module will be expanded when we add additional benchmark modes
(connection_time, steady_state_latency, connection_storm).

Future responsibilities:
  - Abstract the TimescaleDB connection management
  - Support different event schemas per benchmark mode
  - Batch insert optimization with COPY
  - Retry logic with backoff
"""

# TODO: Extract flush logic from heartbeat.py into a reusable Reporter class
