# Fabric Capacity Autoscale

Automatically right‑size Microsoft Fabric capacity **F‑SKUs** — scale up to meet demand, scale down to save cost — driven by the **Fabric Capacity Metrics** semantic model. Multi‑capacity, multi‑region.

Policy is documentation‑grounded (see **[docs/scaling-policy.md](docs/scaling-policy.md)**): react on real throttling / sustained >80% utilization, shrink only on sustained <30%, with hysteresis and cooldown.

## Architecture

```text
Fabric Notebook (every 3h, :30)       Azure Automation Runbook (every 3h, +1h)
collect_capacity_metrics.py           Invoke-CapacityAutoscale.ps1
  runs fleet DAX via executeQueries     reads recent snapshots (SQL, AAD token)
  → appends Delta table                 decides per capacity (embedded logic)
        │                               → PATCH sku via ARM (Managed Identity)
        ▼                                        ▲
  Lakehouse: capacity_metrics_history  ──────────┘  (also the source for
                                                     hysteresis + cooldown)
```

Two moving parts:
- **Collect** — [notebook/collect_capacity_metrics.py](notebook/collect_capacity_metrics.py) runs the per‑capacity metric queries in [dax/fleet-metrics.dax](dax/fleet-metrics.dax) via the Power BI **executeQueries** REST API (the model blocks the XMLA/Discover calls `sempy.evaluate_dax` needs) and appends one row per capacity to a Lakehouse Delta table. Each query sets the model's `CapacitiesList` + region M parameters so its region‑scoped DirectQuery backend returns data instead of blanks.
- **Decide + act** — [runbook/Invoke-CapacityAutoscale.ps1](runbook/Invoke-CapacityAutoscale.ps1) is a **single self‑contained runbook**: reads the history, decides, resizes via ARM. No sibling scripts, no Automation variables, no required config file.

## Repository layout

| Path | Purpose |
|------|---------|
| `runbook/Invoke-CapacityAutoscale.ps1` | The whole autoscaler — one file. Dry‑run by default. |
| `notebook/collect_capacity_metrics.py` | Fabric notebook: fleet DAX → Delta table |
| `dax/fleet-metrics.dax` | Tier‑1 per‑capacity extract (mirrored in the notebook) |
| `sql/create_lakehouse_tables.sql` | Delta table schema + the runbook's read query |
| `tests/Decision-Logic.Tests.ps1` | Pester v5 tests for the decision logic |
| `config/autoscale-config.json` | Reference config + `-ConfigPath` override + threshold source for tests |
| `docs/scaling-policy.md` | Documentation‑grounded thresholds + elastic‑feature setup |

## Setup

### 1. Semantic model access
The **notebook** identity needs **Build** permission on the *Fabric Capacity Metrics* semantic model (service → dataset → Manage permissions → Build). Build also authorizes the executeQueries REST call the notebook uses; the tenant setting **Dataset Execute Queries REST API** must be enabled (Admin portal → Tenant settings).

### 2. Lakehouse + collection notebook
1. Create/pick a Lakehouse; import `notebook/collect_capacity_metrics.py`; attach the Lakehouse.
2. Run once — it creates `capacity_metrics_history`. Check the output: `region parameter:` should print a discovered name (not `None`), and `util_pct_1h` should be non‑zero.
3. Schedule it **every 3 hours at :30** past the hour. On a Pro capacity the Metrics App model refreshes every 3 hours (8×/day from 12am); running at :30 picks up each refresh after it completes. (On a Fabric capacity you can refresh — and therefore collect and scale — more often.)

### 3. The runbook (one thing to create)
1. **Managed identity:** grant the Automation account's identity, at the subscription or resource‑group scope containing your capacities: **Reader** (so it can auto‑discover each capacity's subscription + resource group by name) plus `Microsoft.Fabric/capacities/read` and `Microsoft.Fabric/capacities/write` (to resize).
2. **Modules:** import `Az.Accounts`.
3. **Create a PowerShell runbook**, paste `runbook/Invoke-CapacityAutoscale.ps1`, and **Publish**.
4. **Edit the embedded config** (the `$EmbeddedConfigJson` block near the top) only if you need per‑capacity overrides (`minSku`/`maxSku`/`reservedFloorSku`), a notification `webhookUrl`, or a subscription/resourceGroup override for a narrowly‑scoped identity. Otherwise defaults are fine.

### 4. Run it from the Test pane
Open **Test pane** — the only parameters are:

| Parameter | For first (safe) run | To actually resize |
|-----------|----------------------|--------------------|
| `SqlEndpoint` | `<lakehouse>.datawarehouse.fabric.microsoft.com` | same |
| `LakehouseName` | your Lakehouse name | same |
| `DryRun` | **True** (log only) | **False** |
| `MinSku` | global floor, e.g. `F2` | same |
| `MaxSku` | global ceiling, e.g. `F256` | same |

Subscription and resource group are discovered automatically from each capacity's name — no need to supply them. Leave `DryRun = True` for the first runs and read the output; when the decisions look right, set `DryRun = False`, then **schedule** the runbook **every 3 hours at 1:00** — i.e. ~30 min after the collection notebook, so it reads that cycle's fresh snapshot.

## Reading the runbook output

Each run prints one row per capacity, a plain‑language reason for every decision, and a legend. Here's an annotated example (dry run):

```text
Capacity           | SKU   | Decision                  | Util% 1h/24h/7d  | Thr(s) 1h/24h | Rej 1h/24h | P95 d/r/b     | Risk    | Sn
-------------------+-------+---------------------------+------------------+---------------+------------+---------------+---------+---
prod-fabric-01     | F64   | UP -> F128 [would-scale]  | 92.4/71.2/68.9   | 0/0           | 0/0        | 45.1/0/0      | At risk | 4
analytics-cap      | F32   | DOWN -> F16 [would-scale] | 12.1/9.8/11.2    | 0/0           | 0/0        | 0/0/0         | Healthy | 6
reporting-cap      | F8    | HOLD                      | 48.0/44.5/50.3   | 0/0           | 0/0        | 0/0/0         | Healthy | 6

Reasons (the metric(s) behind each decision):
  - [prod-fabric-01] sustained util 1h > 80% (now 92.4%) over 2 snapshots; -> F128 brings projected util ~46.2% (target headroom 80%)
  - [analytics-cap] sustained low: util 24h 9.8% & 7d 11.2% both < 30% over 4 snapshots, no throttling; -> F16 projects ~19.6% (< headroom 80%)
  - [reporting-cap] within band (util 1h/24h/7d = 48/44.5/50.3%; 24h >= scale-down 30%)
```

### The Decision column
`UP -> <sku>` / `DOWN -> <sku>` / `HOLD`, and for any non‑HOLD row a bracketed **outcome** tag telling you what actually happened to that intended action:

| Tag | Meaning |
|-----|---------|
| `[would-scale]` | Dry run — this is the resize it *would* have performed. Nothing changed. |
| `[resized]` | `DryRun=$false` and the ARM resize succeeded — the SKU was changed. |
| `[cooldown]` | It wanted to act, but the last SKU change was too recent (within `cooldownMinutes`). Skipped. |
| `[error]` | The resize failed, or the capacity's ARM resource id couldn't be resolved (identity needs Reader, or set the subscription/resourceGroup in config). |
| *(HOLD, no tag)* | No action — inside the healthy band, not enough consistent history yet, or a non‑F/trial SKU. |

### The metric columns
Every number comes straight from the *Fabric Capacity Metrics* semantic model — the same values you'd see in the Metrics app, snapshotted hourly-ish (every ~3h here) into the Lakehouse.

| Column | What it is | How to read it |
|--------|-----------|----------------|
| **Util% 1h/24h/7d** | Average utilization vs **base** capacity units (autoscale excluded), over the last 1 hour / 24 hours / 7 days. | The primary up/down signal. `1h` drives scale‑**up** (sustained > 80%); `24h` **and** `7d` together drive scale‑**down** (both < 30%). Fabric smooths usage, so this can read > 100% without throttling. |
| **Thr(s) 1h/24h** | Seconds the capacity was actually **throttled** in the last hour / day. | Any nonzero = users or jobs are being delayed/rejected *now*. `1h > 0` forces an **immediate** scale‑up (bypasses hysteresis); `24h > 0` **blocks** scale‑down. |
| **Rej 1h/24h** | Count of **operations rejected** (queries/jobs turned away) in the last hour / day. | Same role as throttling: `1h > 0` → immediate up; `24h > 0` → no down. |
| **P95 d/r/b** | The three throttling‑**risk** percentages: interactive **D**elay / interactive **R**ejection / **B**ackground rejection. Each is the P95 of *future compute committed* as a % of the throttling limit. | These are the early‑warning gauges. **100% = throttling is starting.** Any of the three reading `>= 100` in the 1h window forces an immediate scale‑up, before `Thr(s)` even registers. Rising‑but‑under‑100 means headroom is tightening. |
| **Risk** | The Metrics app's own health label for the capacity (`Healthy` / `At risk` / …). | Anything other than `Healthy`, sustained, counts as a scale‑up signal even if raw utilization hasn't crossed 80%. |
| **Sn** | How many snapshots of history were in the lookback window for this capacity. | Confidence gate. Scale‑**up** needs `consecutiveSignalsRequired` snapshots (2), scale‑**down** needs `scaleDownConsecutiveSignalsRequired` (4). If **Sn is below the required count, the runbook can't act yet** even if the numbers look extreme — it's still accumulating confirmations. Right after you first deploy, expect several HOLDs purely because `Sn` is low. |

### Putting it together
Read a row left‑to‑right: **Util%** tells you the load, **Thr(s)/Rej/P95** tell you whether that load is actually hurting anyone yet, **Risk** is the model's summary judgment, and **Sn** tells you whether there's enough history to trust the decision. The **Reasons** block underneath always names the specific metric(s) that produced the decision — so if a capacity is holding when you expected a move, the reason line tells you exactly which gate it's sitting behind (too few snapshots, recent throttling, projected‑fit, reserved floor, etc.). The runbook also prints a full **"How to read this"** legend after the table on every run, so the output is self‑documenting.

## Anti‑flap (no state to manage)
- **Hysteresis:** N consecutive snapshots (each ~3h apart) must agree before acting (from the Lakehouse history) — currently 2 to scale up (~6h), 4 to scale down (~12h). Real throttling bypasses hysteresis and scales up immediately.
- **Cooldown:** derived from the last observed SKU change in that same history — no Automation variable needed. Set to 360 min so a resize skips the next scheduled run before another can occur.

## Local testing (dry run)

```powershell
Connect-AzAccount     # your interactive login provides the SQL token
.\runbook\Invoke-CapacityAutoscale.ps1 `
    -SqlEndpoint  "<endpoint>" `
    -LakehouseName "<lakehouse>" `
    -DryRun $true
```

## Unit tests

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser   # if needed (v3 won't work)
Invoke-Pester .\tests\Decision-Logic.Tests.ps1
```

The tests dot‑source the runbook (a guard skips the main body when dot‑sourced) and lock in the up/down math against `config/autoscale-config.json`, so threshold tuning can't silently break behavior.

## Notifications
Set `WebhookUrl` (Teams Incoming Webhook or Power Automate Workflows URL) to get a summary card each run: what scaled, what *would* have scaled in dry‑run, cooldown skips, and errors. Empty = off. Tune `notifyOnDryRun` / `notifyOnNoAction` in the embedded config.

## Current state / notes
- The autoscaler is capacity‑agnostic: it evaluates **every** F‑SKU capacity the collection notebook reports, each independently. Any capacity sitting well under 30% once enough history accrues becomes a scale‑down candidate (set `reservedFloorSku` for any capacity on an Azure reservation so it never scales below the reserved size).
- See `docs/scaling-policy.md` for the recommended built‑in elastic features (capacity overage, surge protection, Spark autoscale billing) that absorb spikes so the runbook only handles sustained trends.
- Possible v2: interactive‑vs‑background CU split per capacity (needs the `TREATAS` timepoint deep‑dive), off‑hours pause/resume, per‑capacity headroom.
