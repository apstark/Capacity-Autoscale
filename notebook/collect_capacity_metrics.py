# ============================================================================
# collect_capacity_metrics.py
# ----------------------------------------------------------------------------
# Fabric notebook (schedule it HOURLY). Extracts per-capacity metrics from the
# "Fabric Capacity Metrics" semantic model and appends one row per capacity to
# the Lakehouse Delta table `capacity_metrics_history`, which the autoscaler
# runbook (runbook/Invoke-CapacityAutoscale.ps1) reads for its decisions.
#
# WHY THIS SHAPE (this is the fix vs. the old sempy.evaluate_dax version):
#   The Metrics App fact tables are DirectQuery to a REGION-SCOPED backend,
#   gated by two dynamic M parameters (CapacitiesList + a region parameter).
#     1) Transport: this model BLOCKS the XMLA / Discover calls that
#        sempy.fabric.evaluate_dax relies on, so evaluate_dax returns nothing.
#        We use the Power BI **executeQueries** REST API instead (works on Pro
#        AND Direct Lake, no XMLA).
#     2) Context: a bare measure query (SUMMARIZECOLUMNS over all capacities,
#        no parameters) returns 0/blank for any capacity outside the model's
#        default region. So we query **per capacity** with BOTH M parameters
#        set via MPARAMETER, which points DirectQuery at the right regional
#        backend.
#
#   The metric SET below is the autoscaler's richer set (throttling, P95
#   throttling-risk, rejected ops, risk status, etc.), NOT just utilization.
#   The output schema is unchanged, so the runbook / SQL / Pester tests keep
#   working as-is.
#
# Prereqs:
#   * Attach this notebook to the Lakehouse that holds capacity_metrics_history.
#   * The notebook identity needs BUILD (or Read + the tenant "Dataset Execute
#     Queries REST API" setting) on the "Fabric Capacity Metrics" semantic model.
#   * sempy is preinstalled in Fabric runtimes (used only to resolve the
#     workspace id). If missing: %pip install semantic-link
# ============================================================================

# ---------------------------------------------------------------------------
# CELL 1 - parameters
# ---------------------------------------------------------------------------
METRICS_WORKSPACE = "Microsoft Fabric Capacity Metrics"   # name OR workspace GUID
METRICS_DATASET   = "Fabric Capacity Metrics"             # name OR dataset GUID
# If multiple Metrics App installs share that name, pin the GUIDs of the
# POPULATED one (the install that sits on a Fabric capacity):
WORKSPACE_ID = ""   # optional GUID override
DATASET_ID   = ""   # optional GUID override

TARGET_TABLE = "capacity_metrics_history"   # Delta table in the attached Lakehouse

# ---------------------------------------------------------------------------
# CELL 2 - setup: token, ids, executeQueries helper, region-parameter discovery
# ---------------------------------------------------------------------------
import time
import requests
import notebookutils
import pandas as pd
import sempy.fabric as fabric
from datetime import datetime, timezone

from pyspark.sql.types import (
    StructType, StructField, StringType, DoubleType, LongType, TimestampType,
)

# One snapshot time for the whole batch (UTC, minute precision - matches history design).
SNAPSHOT_UTC = datetime.now(timezone.utc).replace(second=0, microsecond=0)


def _token():
    # Power BI / Analysis Services audience. "pbi" is the short alias in Fabric.
    try:
        return notebookutils.credentials.getToken("pbi")
    except Exception:
        return notebookutils.credentials.getToken(
            "https://analysis.windows.net/powerbi/api"
        )


if not WORKSPACE_ID:
    WORKSPACE_ID = fabric.resolve_workspace_id(METRICS_WORKSPACE)
if not DATASET_ID:
    r = requests.get(
        f"https://api.powerbi.com/v1.0/myorg/groups/{WORKSPACE_ID}/datasets",
        headers={"Authorization": f"Bearer {_token()}"},
    )
    r.raise_for_status()
    DATASET_ID = next(d["id"] for d in r.json()["value"] if d["name"] == METRICS_DATASET)
print("workspace:", WORKSPACE_ID, "| dataset:", DATASET_ID)


def run_dax(dax, retries=3, delay=5):
    """Execute a DAX query via the Power BI executeQueries REST API (no XMLA)."""
    url = (
        f"https://api.powerbi.com/v1.0/myorg/groups/{WORKSPACE_ID}"
        f"/datasets/{DATASET_ID}/executeQueries"
    )
    body = {"queries": [{"query": dax}], "serializerSettings": {"includeNulls": True}}
    last = None
    for a in range(1, retries + 1):
        try:
            resp = requests.post(
                url, json=body, timeout=300,
                headers={"Authorization": f"Bearer {_token()}",
                         "Content-Type": "application/json"},
            )
            if resp.status_code == 200:
                return pd.DataFrame(resp.json()["results"][0]["tables"][0].get("rows", []))
            last = RuntimeError(f"{resp.status_code}: {resp.text[:300]}")
        except Exception as e:
            last = e
        if a < retries:
            time.sleep(delay)
    raise last


# Discover the region parameter that drives the DirectQuery data location.
REGION_PARAM = None
try:
    pr = requests.get(
        f"https://api.powerbi.com/v1.0/myorg/groups/{WORKSPACE_ID}"
        f"/datasets/{DATASET_ID}/parameters",
        headers={"Authorization": f"Bearer {_token()}"},
    )
    pr.raise_for_status()
    REGION_PARAM = next(
        (p["name"] for p in pr.json()["value"] if "region" in p["name"].lower()), None
    )
except Exception as e:
    print("  (could not list parameters:", str(e)[:100], ")")
print("region parameter:", REGION_PARAM)

# ---------------------------------------------------------------------------
# CELL 3 - capacities dimension (id / name / region / sku / state)
# SKU + State come from the dimension; the [Latest SKU] measure is unreliable.
# ---------------------------------------------------------------------------
caps = run_dax("EVALUATE 'Capacities'")
caps.columns = [c.split("[")[-1].rstrip("]") for c in caps.columns]  # strip Table[...] qualifier


def cap_col(*names, required=True, default=None):
    for n in names:
        if n in caps.columns:
            return n
    if required:
        raise KeyError(f"None of {names} in {list(caps.columns)}")
    return default


ID_COL     = cap_col("Uppercase capacity Id", "Capacity Id")
NAME_COL   = cap_col("Capacity name")
SKU_COL    = cap_col("SKU")
# For the M parameter, use the value proven to work with CapacitiesList/region.
REGION_COL = cap_col("Region", "Region without default")
# State is optional in some installs; default to Active so live capacities aren't skipped.
STATE_COL  = cap_col("State", "Capacity state", required=False)

caps[ID_COL] = caps[ID_COL].astype(str)
print(f"{len(caps)} capacities | regions: {sorted(set(caps[REGION_COL].astype(str)))}")

# ---------------------------------------------------------------------------
# CELL 4 - per-capacity metrics with BOTH M parameters set (region-scoped DQ)
# The measure set the autoscaler needs. output_column -> DAX measure expression.
# ---------------------------------------------------------------------------
MEASURES = [
    ("util_pct_1h",        "[Average utilization by capacity (last 1 hour)]"),
    ("util_pct_24h",       "[Average utilization by capacity (last 24 hours)]"),
    ("util_pct_7d",        "[Average utilization by capacity (last 7 days)]"),
    ("variance_1h",        "[Usage variance by capacity (last 1 hour)]"),
    ("throttling_s_1h",    "[Throttling(s) by capacity (last 1 hour)]"),
    ("throttling_s_24h",   "[Throttling(s) by capacity (last 24 hours)]"),
    ("p95_int_delay_1h",   "[P95 interactive delay by capacity (last 1 hour)]"),
    ("p95_int_reject_1h",  "[P95 interactive rejection by capacity (last 1 hour)]"),
    ("p95_bg_reject_1h",   "[P95 background rejection by capacity (last 1 hour)]"),
    ("rejected_ops_1h",    "[Rejected operations by capacity (last 1 hour)]"),
    ("rejected_ops_24h",   "[Rejected operations by capacity (last 24 hours)]"),
    ("users_1h",           "[Users by capacity (last 1 hour)]"),
    ("users_24h",          "[Users by capacity (last 24 hours)]"),
    ("successful_ops_24h", "[Successful operations by capacity (last 24 hours)]"),
    ("risk_1h",            "[Risk status by capacity (last 1 hour)]"),
    ("risk_24h",           "[Risk status by capacity (last 24 hours)]"),
]


def _mparam_prefix(cid, region):
    defines = [f'MPARAMETER \'CapacitiesList\' = {{"{cid}"}}']
    if REGION_PARAM and region:
        defines.append(f'MPARAMETER \'{REGION_PARAM}\' = "{region}"')
    return "DEFINE " + " ".join(defines) + " "


def fetch_capacity_metrics(cid, region):
    """Return {output_col: value}. One REST call on the happy path; on failure
    fall back to probing each measure individually so a single bad/absent
    measure name doesn't wipe out the whole row (and we learn which one)."""
    prefix = _mparam_prefix(cid, region)
    row_body = ", ".join(f'"{col}", {expr}' for col, expr in MEASURES)
    try:
        res = run_dax(prefix + f"EVALUATE ROW({row_body})").iloc[0]
        return {col: res.get(f"[{col}]") for col, _ in MEASURES}
    except Exception as e:
        print(f"    combined query failed ({str(e)[:80]}); probing measures individually")
        out = {}
        for col, expr in MEASURES:
            try:
                out[col] = run_dax(prefix + f'EVALUATE ROW("{col}", {expr})').iloc[0].get(f"[{col}]")
            except Exception as ie:
                print(f"      measure unavailable, set null: {col} ({str(ie)[:60]})")
                out[col] = None
        return out


rows = []
for _, c in caps.iterrows():
    cid    = c[ID_COL]
    region = str(c[REGION_COL]) if pd.notna(c[REGION_COL]) else ""
    rec = {
        "capacity_id":   cid,
        "capacity_name": c[NAME_COL],
        "region":        region,
        "sku":           c[SKU_COL],
        "state":         (str(c[STATE_COL]) if STATE_COL and pd.notna(c[STATE_COL]) else "Active"),
    }
    try:
        rec.update(fetch_capacity_metrics(cid, region))
    except Exception as e:
        print(f"  {c[NAME_COL]} ({region}) FAILED entirely: {str(e)[:120]}")
        rec.update({col: None for col, _ in MEASURES})
    rows.append(rec)

df = pd.DataFrame(rows)
df.insert(0, "snapshot_time_utc", SNAPSHOT_UTC)

# Sanity check: if every capacity reports 0/blank utilization, the region
# parameter probably wasn't applied or this is the wrong (empty) install.
_u = pd.to_numeric(df["util_pct_1h"], errors="coerce").fillna(0)
if _u.eq(0).all():
    print("WARNING: all util_pct_1h are 0/blank. Check that REGION_PARAM was discovered "
          "and that WORKSPACE_ID/DATASET_ID point at the populated install "
          "(the Metrics App install that sits on a Fabric capacity).")
try:
    display(df)  # noqa: F821  (display provided by Fabric)
except Exception:
    print(df.to_string())

# ---------------------------------------------------------------------------
# CELL 5 - type coercion + write to the Lakehouse Delta table (append)
# ---------------------------------------------------------------------------
STRING_COLS = ["capacity_id", "capacity_name", "region", "sku", "state", "risk_1h", "risk_24h"]
DOUBLE_COLS = [
    "util_pct_1h", "util_pct_24h", "util_pct_7d", "variance_1h",
    "throttling_s_1h", "throttling_s_24h",
    "p95_int_delay_1h", "p95_int_reject_1h", "p95_bg_reject_1h",
]
LONG_COLS = [
    "rejected_ops_1h", "rejected_ops_24h",
    "users_1h", "users_24h", "successful_ops_24h",
]

TARGET_SCHEMA = StructType(
    [StructField("snapshot_time_utc", TimestampType(), False)]
    + [StructField(c, StringType(), True) for c in STRING_COLS]
    + [StructField(c, DoubleType(), True) for c in DOUBLE_COLS]
    + [StructField(c, LongType(), True) for c in LONG_COLS]
)

for c in DOUBLE_COLS:
    df[c] = pd.to_numeric(df.get(c), errors="coerce")
for c in LONG_COLS:
    df[c] = pd.to_numeric(df.get(c), errors="coerce").astype("Int64")
for c in STRING_COLS:
    df[c] = df.get(c).astype("string")

# Ensure every target column exists, in schema order.
for field in TARGET_SCHEMA.fields:
    if field.name not in df.columns:
        df[field.name] = None
df = df[[f.name for f in TARGET_SCHEMA.fields]]

sdf = spark.createDataFrame(df, schema=TARGET_SCHEMA)  # noqa: F821 (spark provided by Fabric)
(
    sdf.write
    .format("delta")
    .mode("append")
    .option("mergeSchema", "true")
    .saveAsTable(TARGET_TABLE)
)
print(f"Wrote {sdf.count()} capacity row(s) at {SNAPSHOT_UTC.isoformat()} to {TARGET_TABLE}.")
