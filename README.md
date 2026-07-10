# Fabric Capacity Autoscale

Automatically right‑size Microsoft Fabric capacity **F‑SKUs** — scale up to meet demand, scale down to save cost — driven by the **Fabric Capacity Metrics** semantic model. Multi‑capacity, multi‑region.

Policy is documentation‑grounded (see **[docs/scaling-policy.md](docs/scaling-policy.md)**): react on real throttling / sustained >80% utilization, shrink only on sustained <30%, with hysteresis and cooldown.

## Architecture

```text
Fabric Notebook (hourly)              Azure Automation Runbook (hourly)
collect_capacity_metrics.py           Invoke-CapacityAutoscale.ps1
  runs fleet DAX via sempy              reads recent snapshots (SQL, AAD token)
  → appends Delta table                 decides per capacity (embedded logic)
        │                               → PATCH sku via ARM (Managed Identity)
        ▼                                        ▲
  Lakehouse: capacity_metrics_history  ──────────┘  (also the source for
                                                     hysteresis + cooldown)
```

Two moving parts:
- **Collect** — [notebook/collect_capacity_metrics.py](notebook/collect_capacity_metrics.py) runs [dax/fleet-metrics.dax](dax/fleet-metrics.dax) and appends one row per capacity to a Lakehouse Delta table.
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
The **notebook** identity needs **Build** permission on the *Fabric Capacity Metrics* semantic model (service → dataset → Manage permissions → Build).

### 2. Lakehouse + collection notebook
1. Create/pick a Lakehouse; import `notebook/collect_capacity_metrics.py`; attach the Lakehouse.
2. Run once — it creates `capacity_metrics_history`.
3. Schedule it **hourly** (Capacity Metrics data lags ~15–30 min, so hourly is the right cadence).

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

Subscription and resource group are discovered automatically from each capacity's name — no need to supply them. Leave `DryRun = True` for the first runs and read the output; when the decisions look right, set `DryRun = False`, then **schedule** the runbook hourly (a few minutes after the notebook).

## Anti‑flap (no state to manage)
- **Hysteresis:** N consecutive hourly snapshots must agree before acting (from the Lakehouse history).
- **Cooldown:** derived from the last observed SKU change in that same history — no Automation variable needed.

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
- Tenant today: one capacity — **`tmcadlfabric`, F64, East US, ~20% utilized** → a scale‑down candidate once history accrues (set `reservedFloorSku` if it's on a reservation).
- See `docs/scaling-policy.md` for the recommended built‑in elastic features (capacity overage, surge protection, Spark autoscale billing) that absorb spikes so the runbook only handles sustained trends.
- Possible v2: interactive‑vs‑background CU split per capacity (needs the `TREATAS` timepoint deep‑dive), off‑hours pause/resume, per‑capacity headroom.
