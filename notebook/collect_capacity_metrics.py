# ============================================================================
# collect_capacity_metrics.py
# ----------------------------------------------------------------------------
# Fabric notebook (schedule it hourly). Runs the Tier-1 fleet DAX against the
# Fabric Capacity Metrics semantic model via semantic-link (sempy), then appends
# one row per capacity to a Lakehouse Delta table for history.
#
# Prereqs:
#   * Attach this notebook to the Lakehouse that holds capacity_metrics_history.
#   * The notebook's running identity needs BUILD permission on the
#     "Fabric Capacity Metrics" semantic model (same permission we granted for
#     the DAX query view).
#   * pip: semantic-link is preinstalled in Fabric runtimes. If missing:
#         %pip install semantic-link
#
# The DAX below MUST stay in sync with dax/fleet-metrics.dax.
# ============================================================================

from datetime import datetime, timezone

import sempy.fabric as fabric
from pyspark.sql import functions as F
from pyspark.sql.types import (
    StructType, StructField, StringType, DoubleType, LongType, TimestampType,
)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
WORKSPACE = "Microsoft Fabric Capacity Metrics"   # semantic model's workspace
DATASET   = "Fabric Capacity Metrics"             # semantic model name
TARGET_TABLE = "capacity_metrics_history"         # Delta table in the attached Lakehouse

DAX_QUERY = r"""
EVALUATE
SUMMARIZECOLUMNS(
    'Capacities'[Uppercase capacity Id],
    'Capacities'[Capacity name],
    'Capacities'[Region without default],
    'Capacities'[SKU],
    'Capacities'[State],
    "Util % 1h",          [Average utilization by capacity (last 1 hour)],
    "Util % 24h",         [Average utilization by capacity (last 24 hours)],
    "Util % 7d",          [Average utilization by capacity (last 7 days)],
    "Variance 1h",        [Usage variance by capacity (last 1 hour)],
    "Throttling s 1h",    [Throttling(s) by capacity (last 1 hour)],
    "Throttling s 24h",   [Throttling(s) by capacity (last 24 hours)],
    "P95 int delay 1h",   [P95 interactive delay by capacity (last 1 hour)],
    "P95 int reject 1h",  [P95 interactive rejection by capacity (last 1 hour)],
    "P95 bg reject 1h",   [P95 background rejection by capacity (last 1 hour)],
    "Rejected ops 1h",    [Rejected operations by capacity (last 1 hour)],
    "Rejected ops 24h",   [Rejected operations by capacity (last 24 hours)],
    "Users 1h",           [Users by capacity (last 1 hour)],
    "Users 24h",          [Users by capacity (last 24 hours)],
    "Successful ops 24h", [Successful operations by capacity (last 24 hours)],
    "Risk 1h",            [Risk status by capacity (last 1 hour)],
    "Risk 24h",           [Risk status by capacity (last 24 hours)]
)
"""

# Map raw sempy column names -> tidy Delta column names.
COLUMN_MAP = {
    "Capacities[Uppercase capacity Id]": "capacity_id",
    "Capacities[Capacity name]":         "capacity_name",
    "Capacities[Region without default]": "region",
    "Capacities[SKU]":                   "sku",
    "Capacities[State]":                 "state",
    "[Util % 1h]":          "util_pct_1h",
    "[Util % 24h]":         "util_pct_24h",
    "[Util % 7d]":          "util_pct_7d",
    "[Variance 1h]":        "variance_1h",
    "[Throttling s 1h]":    "throttling_s_1h",
    "[Throttling s 24h]":   "throttling_s_24h",
    "[P95 int delay 1h]":   "p95_int_delay_1h",
    "[P95 int reject 1h]":  "p95_int_reject_1h",
    "[P95 bg reject 1h]":   "p95_bg_reject_1h",
    "[Rejected ops 1h]":    "rejected_ops_1h",
    "[Rejected ops 24h]":   "rejected_ops_24h",
    "[Users 1h]":           "users_1h",
    "[Users 24h]":          "users_24h",
    "[Successful ops 24h]": "successful_ops_24h",
    "[Risk 1h]":            "risk_1h",
    "[Risk 24h]":           "risk_24h",
}

DOUBLE_COLS = [
    "util_pct_1h", "util_pct_24h", "util_pct_7d", "variance_1h",
    "throttling_s_1h", "throttling_s_24h",
    "p95_int_delay_1h", "p95_int_reject_1h", "p95_bg_reject_1h",
]
LONG_COLS = [
    "rejected_ops_1h", "rejected_ops_24h",
    "users_1h", "users_24h", "successful_ops_24h",
]
STRING_COLS = ["capacity_id", "capacity_name", "region", "sku", "state", "risk_1h", "risk_24h"]

TARGET_SCHEMA = StructType(
    [StructField("snapshot_time_utc", TimestampType(), False)]
    + [StructField(c, StringType(), True) for c in STRING_COLS]
    + [StructField(c, DoubleType(), True) for c in DOUBLE_COLS]
    + [StructField(c, LongType(), True) for c in LONG_COLS]
)


def main():
    # 1) Run the DAX against the semantic model.
    pdf = fabric.evaluate_dax(dataset=DATASET, workspace=WORKSPACE, dax_string=DAX_QUERY)
    if pdf.empty:
        print("No rows returned from the semantic model - nothing to write.")
        return

    # 2) Tidy column names; keep only mapped columns.
    pdf = pdf.rename(columns=COLUMN_MAP)
    pdf = pdf[[c for c in COLUMN_MAP.values() if c in pdf.columns]]

    # 3) Coerce types (blank measures come back as None/NaN -> keep as null).
    import pandas as pd  # available in Fabric runtime
    for c in DOUBLE_COLS:
        if c in pdf.columns:
            pdf[c] = pd.to_numeric(pdf[c], errors="coerce")
    for c in LONG_COLS:
        if c in pdf.columns:
            pdf[c] = pd.to_numeric(pdf[c], errors="coerce").astype("Int64")
    for c in STRING_COLS:
        if c in pdf.columns:
            pdf[c] = pdf[c].astype("string")

    # 4) Stamp one snapshot time for the whole batch (UTC, minute precision).
    snapshot = datetime.now(timezone.utc).replace(second=0, microsecond=0)
    pdf.insert(0, "snapshot_time_utc", snapshot)

    # 5) Ensure every target column exists, in order.
    for field in TARGET_SCHEMA.fields:
        if field.name not in pdf.columns:
            pdf[field.name] = None
    pdf = pdf[[f.name for f in TARGET_SCHEMA.fields]]

    # 6) Write to the Lakehouse Delta table (append). Creates it on first run.
    sdf = spark.createDataFrame(pdf, schema=TARGET_SCHEMA)  # noqa: F821 (spark provided by Fabric)
    (
        sdf.write
        .format("delta")
        .mode("append")
        .option("mergeSchema", "true")
        .saveAsTable(TARGET_TABLE)
    )
    print(f"Wrote {sdf.count()} capacity row(s) at {snapshot.isoformat()} to {TARGET_TABLE}.")


main()
