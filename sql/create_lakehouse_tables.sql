-- ============================================================================
-- Lakehouse tables for the Fabric capacity autoscaler
-- ----------------------------------------------------------------------------
-- IMPORTANT: A Lakehouse *SQL analytics endpoint* is READ-ONLY. You cannot
-- CREATE TABLE through it. The metrics table below is created automatically by
-- notebook/collect_capacity_metrics.py (spark ... .saveAsTable), which writes a
-- managed Delta table. This file documents (a) the resulting schema for
-- reference and (b) the exact read query the runbook uses.
--
-- Scale-action audit + cooldown state do NOT live here (read-only endpoint).
-- They are stored by the runbook in an Azure Automation variable / Storage Table
-- (see runbook/Invoke-CapacityAutoscale.ps1 and README).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Reference schema: capacity_metrics_history  (Delta table, created by notebook)
-- ---------------------------------------------------------------------------
-- COLUMN                 TYPE           NOTES
-- snapshot_time_utc      datetime2      One extract run == one timestamp, all capacities share it
-- capacity_id            varchar(50)    Uppercase capacity GUID (join key to Capacities)
-- capacity_name          varchar(200)   ARM resource name (target of the resize)
-- region                 varchar(50)    Real Azure region (Region without default)
-- sku                    varchar(20)    Latest SKU reported, e.g. F64
-- state                  varchar(20)    Active / Paused / ...
-- util_pct_1h            float          Average utilization % vs BASE capacity units (last 1 hour)
-- util_pct_24h           float          Average utilization % (last 24 hours)
-- util_pct_7d            float          Average utilization % (last 7 days)
-- variance_1h            float          Usage variance (last 1 hour)
-- throttling_s_1h        float          Throttling seconds (last 1 hour)  -- >0 means real throttling
-- throttling_s_24h       float          Throttling seconds (last 24 hours)
-- p95_int_delay_1h       float          P95 interactive DELAY threshold % (10-min window). >=100 == throttling
-- p95_int_reject_1h      float          P95 interactive REJECTION threshold % (60-min window)
-- p95_bg_reject_1h       float          P95 background REJECTION threshold % (24-hr window)
-- rejected_ops_1h        bigint         Rejected operations (last 1 hour)
-- rejected_ops_24h       bigint         Rejected operations (last 24 hours)
-- users_1h               bigint         Distinct users (last 1 hour)
-- users_24h              bigint         Distinct users (last 24 hours)
-- successful_ops_24h     bigint         Successful operations (last 24 hours)
-- risk_1h                varchar(20)    Risk status (last 1 hour): Healthy / At risk / ...
-- risk_24h               varchar(20)    Risk status (last 24 hours)


-- ---------------------------------------------------------------------------
-- Runbook read query: latest N hours of snapshots per capacity.
-- The runbook applies hysteresis by requiring the last K snapshots to agree,
-- so it needs recent history, not just the newest row.
-- Parameter @LookbackHours is injected by the runbook (default 8).
-- ---------------------------------------------------------------------------
SELECT
    h.capacity_id,
    h.capacity_name,
    h.region,
    h.sku,
    h.state,
    h.snapshot_time_utc,
    h.util_pct_1h,
    h.util_pct_24h,
    h.util_pct_7d,
    h.throttling_s_1h,
    h.throttling_s_24h,
    h.p95_int_delay_1h,
    h.p95_int_reject_1h,
    h.p95_bg_reject_1h,
    h.rejected_ops_1h,
    h.rejected_ops_24h,
    h.risk_1h,
    h.risk_24h
FROM dbo.capacity_metrics_history AS h
WHERE h.snapshot_time_utc >= DATEADD(HOUR, -@LookbackHours, SYSUTCDATETIME())
ORDER BY h.capacity_id, h.snapshot_time_utc DESC;
