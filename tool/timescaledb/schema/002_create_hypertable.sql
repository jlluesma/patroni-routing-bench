-------------------------------------------------------------------------------
-- patroni-routing-bench: TimescaleDB Hypertables
-- 002_create_hypertable.sql
--
-- Convert event tables to hypertables for time-series optimization.
-- Hypertables automatically partition data by time, giving us:
--   - Fast range queries on timestamp (e.g., "events during failover window")
--   - Efficient compression for historical data
--   - Automatic chunk management
-------------------------------------------------------------------------------

-- Observer events: partitioned by time, 1-hour chunks
-- (failover tests are short, so small chunks keep queries fast)
SELECT create_hypertable(
    'observer_events',
    'ts',
    chunk_time_interval => INTERVAL '1 hour',
    if_not_exists => TRUE
);

-- Client events: partitioned by time, 1-hour chunks
SELECT create_hypertable(
    'client_events',
    'ts',
    chunk_time_interval => INTERVAL '1 hour',
    if_not_exists => TRUE
);

-- Indexes for common query patterns

-- Observer: find all events for a specific test run
CREATE INDEX IF NOT EXISTS idx_observer_test_run
    ON observer_events (test_run_id, ts);

-- Observer: find events by component type
CREATE INDEX IF NOT EXISTS idx_observer_component
    ON observer_events (component, ts);

-- Observer: find events by combination
CREATE INDEX IF NOT EXISTS idx_observer_combination
    ON observer_events (combination_id, ts);

-- Client: find all events for a specific test run
CREATE INDEX IF NOT EXISTS idx_client_test_run
    ON client_events (test_run_id, ts);

-- Client: find failures quickly (for failover window detection)
CREATE INDEX IF NOT EXISTS idx_client_failures
    ON client_events (test_run_id, ts)
    WHERE success = FALSE;
