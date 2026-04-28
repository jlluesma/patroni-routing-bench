-------------------------------------------------------------------------------
-- patroni-routing-bench: Analytical Views
-- 003_create_views.sql
--
-- Views that power the Grafana dashboards. These pre-compute the most
-- common queries so dashboard panels stay fast and simple.
-------------------------------------------------------------------------------

-- =============================================================================
-- VIEW: failover_timeline
-- Full event timeline for a given test run, merging server and client events
-- into a single chronological stream. This powers the "Waterfall" dashboard.
-- =============================================================================
CREATE OR REPLACE VIEW failover_timeline AS
SELECT
    ts,
    test_run_id,
    combination_id,
    'server'        AS perspective,
    component       AS source,
    node,
    event_type,
    old_value,
    new_value,
    detail
FROM observer_events

UNION ALL

SELECT
    ts,
    test_run_id,
    combination_id,
    'client'        AS perspective,
    'client'        AS source,
    ''              AS node,
    CASE
        WHEN success THEN 'query_success'
        ELSE 'query_failure'
    END             AS event_type,
    ''              AS old_value,
    CASE
        WHEN success THEN 'ok'
        ELSE error
    END             AS new_value,
    'latency_us=' || latency_us::text AS detail
FROM client_events

ORDER BY ts;


-- =============================================================================
-- VIEW: failover_window
-- Per test run: when did the client first see a failure, and when did it
-- recover? This is the core "total failover time" metric.
-- =============================================================================
CREATE OR REPLACE VIEW failover_window AS
SELECT
    test_run_id,
    combination_id,
    MIN(ts) FILTER (WHERE success = FALSE)  AS first_failure,
    MAX(ts) FILTER (WHERE success = FALSE)  AS last_failure,
    MIN(ts) FILTER (
        WHERE success = TRUE
        AND ts > (SELECT MIN(ts) FROM client_events c2
                  WHERE c2.test_run_id = client_events.test_run_id
                  AND c2.success = FALSE)
    )                                        AS first_recovery,
    COUNT(*) FILTER (WHERE success = FALSE)  AS total_failures,
    COUNT(*) FILTER (WHERE success = TRUE)   AS total_successes,
    EXTRACT(EPOCH FROM (
        MIN(ts) FILTER (
            WHERE success = TRUE
            AND ts > (SELECT MIN(ts) FROM client_events c2
                      WHERE c2.test_run_id = client_events.test_run_id
                      AND c2.success = FALSE)
        )
        - MIN(ts) FILTER (WHERE success = FALSE)
    )) * 1000                                AS downtime_ms
FROM client_events
GROUP BY test_run_id, combination_id;


-- =============================================================================
-- VIEW: component_timing
-- Per test run: when did each component detect the failover?
-- Shows the propagation delay through the stack.
-- =============================================================================
CREATE OR REPLACE VIEW component_timing AS
SELECT
    test_run_id,
    combination_id,
    component,
    node,
    event_type,
    MIN(ts)     AS first_detected,
    old_value,
    new_value
FROM observer_events
WHERE event_type IN (
    'role_change',
    'leader_key_change',
    'backend_state_change',
    'vip_state_change',
    'timeline_change',
    'pg_promote_requested',
    'pg_ready_accept_connections'
)
GROUP BY test_run_id, combination_id, component, node, event_type,
         old_value, new_value
ORDER BY first_detected;


-- =============================================================================
-- VIEW: combination_comparison
-- Aggregate failover metrics per combination for side-by-side comparison.
-- =============================================================================
CREATE OR REPLACE VIEW combination_comparison AS
SELECT
    fw.combination_id,
    COUNT(DISTINCT fw.test_run_id)          AS test_runs,
    ROUND(AVG(fw.downtime_ms)::numeric, 1) AS avg_downtime_ms,
    ROUND(MIN(fw.downtime_ms)::numeric, 1) AS min_downtime_ms,
    ROUND(MAX(fw.downtime_ms)::numeric, 1) AS max_downtime_ms,
    ROUND(STDDEV(fw.downtime_ms)::numeric, 1) AS stddev_downtime_ms,
    ROUND(AVG(fw.total_failures)::numeric, 0) AS avg_failed_queries,
    tr.dcs,
    tr.provider,
    tr.failover_type
FROM failover_window fw
JOIN test_runs tr ON tr.id = fw.test_run_id
GROUP BY fw.combination_id, tr.dcs, tr.provider, tr.failover_type
ORDER BY avg_downtime_ms;


-- =============================================================================
-- VIEW: client_latency_buckets
-- Latency distribution during steady state vs. failover window.
-- Useful for understanding connection storm behavior.
-- =============================================================================
CREATE OR REPLACE VIEW client_latency_buckets AS
SELECT
    ce.test_run_id,
    ce.combination_id,
    CASE
        WHEN ce.ts BETWEEN fw.first_failure AND fw.first_recovery THEN 'failover'
        WHEN ce.ts < fw.first_failure THEN 'before'
        ELSE 'after'
    END AS phase,
    ce.success,
    COUNT(*)                                    AS query_count,
    ROUND(AVG(ce.latency_us)::numeric, 0)       AS avg_latency_us,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY ce.latency_us)::numeric, 0) AS p50_latency_us,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY ce.latency_us)::numeric, 0) AS p95_latency_us,
    ROUND(PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY ce.latency_us)::numeric, 0) AS p99_latency_us
FROM client_events ce
LEFT JOIN failover_window fw
    ON fw.test_run_id = ce.test_run_id
GROUP BY ce.test_run_id, ce.combination_id, phase, ce.success;
