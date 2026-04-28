-------------------------------------------------------------------------------
-- patroni-routing-bench: TimescaleDB Schema
-- 001_create_events.sql
--
-- Core tables for storing failover timing data from:
--   1. Observer agents (server-side component events)
--   2. Client heartbeat (client-side query success/failure)
--   3. Test run metadata
-------------------------------------------------------------------------------

-- Track test runs across combinations
CREATE TABLE IF NOT EXISTS test_runs (
    id              TEXT        PRIMARY KEY,
    combination_id  TEXT        NOT NULL,
    dcs             TEXT        NOT NULL DEFAULT 'consul',
    provider        TEXT        NOT NULL DEFAULT 'local',
    started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at        TIMESTAMPTZ,
    failover_type   TEXT,           -- how failover was triggered: sigkill, sigstop, docker_stop, patroni_switchover
    config          JSONB       DEFAULT '{}',  -- test parameters: interval_ms, iterations, etc.
    notes           TEXT        DEFAULT ''
);

-- Server-side events from observer agents
-- One row per state change detected by any watcher (Patroni, Consul, HAProxy, VIP, PostgreSQL)
CREATE TABLE IF NOT EXISTS observer_events (
    ts              TIMESTAMPTZ NOT NULL,
    combination_id  TEXT        NOT NULL,
    test_run_id     TEXT        NOT NULL,
    component       TEXT        NOT NULL,   -- patroni, consul, haproxy, vip, postgres
    node            TEXT        NOT NULL,   -- node name within the combination
    event_type      TEXT        NOT NULL,   -- role_change, leader_key_change, backend_state_change, etc.
    old_value       TEXT        DEFAULT '',
    new_value       TEXT        NOT NULL,
    detail          TEXT        DEFAULT ''
);

-- Client-side events from the heartbeat traffic generator
-- One row per query attempt (INSERT into the target database)
CREATE TABLE IF NOT EXISTS client_events (
    ts              TIMESTAMPTZ NOT NULL,
    combination_id  TEXT        NOT NULL,
    test_run_id     TEXT        NOT NULL,
    sequence        BIGINT      NOT NULL,   -- monotonically increasing per test run
    success         BOOLEAN     NOT NULL,
    latency_us      BIGINT      NOT NULL,   -- microseconds from connect() to query complete
    error           TEXT        DEFAULT ''
);
