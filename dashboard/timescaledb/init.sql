-------------------------------------------------------------------------------
-- patroni-routing-bench: TimescaleDB Bootstrap
-- init.sql
--
-- Runs on first container start via the /docker-entrypoint-initdb.d/ mechanism.
-- Enables TimescaleDB extension and applies all schema migrations in order.
-------------------------------------------------------------------------------

-- Enable TimescaleDB
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- Apply migrations
\i /docker-entrypoint-initdb.d/001_create_events.sql
\i /docker-entrypoint-initdb.d/002_create_hypertable.sql
\i /docker-entrypoint-initdb.d/003_create_views.sql
