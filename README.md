# Fabric Capacity Autoscale

Automatically right‑size Microsoft Fabric capacity **F‑SKUs** — scale up to meet demand, scale down to save cost — driven by the **Fabric Capacity Metrics** semantic model. Works across multiple capacities and regions.

The policy is documentation‑grounded (see **[docs/scaling-policy.md](docs/scaling-policy.md)**): react on real throttling / sustained >80% utilization, shrink only on sustained <30% peak, with hysteresis, cooldown, and a reservation floor.

## Architecture

```
┌─────────────────────────┐   hourly    ┌──────────────────────────┐
│ Fabric Notebook         │  DAX via    │ Fabric Capacity Metrics  │
│ collect_capacity_       │◀───sempy────│ semantic model           │
│ metrics.py              │             └──────────────────────────┘
│  → writes Delta table   │
└───────────┬─────────────┘
            │ append
            ▼
┌─────────────────────────┐
│ Lakehouse               │
│ capacity_metrics_history│  (Delta; read via SQL analytics endpoint)
└───────────┬─────────────┘
            │ SQL (AAD token)
            ▼
┌─────────────────────────┐   PATCH sku   ┌──────────────────────────┐
│ Azure Automation Runbook│──────ARM─────▶│ Microsoft.Fabric/        │
│ Invoke-CapacityAutoscale│  (Managed ID) │ capacities/{name}        │
│  + Decision-Logic.ps1   │               └──────────────────────────┘
└─────────────────────────┘
```

- **Collect** ([notebook/collect_capacity_metrics.py](notebook/collect_capacity_metrics.py)) — runs [dax/fleet-metrics.dax](dax/fleet-metrics.dax) and appends one row per capacity to a Lakehouse Delta table.
- **Decide + act** ([runbook/Invoke-CapacityAutoscale.ps1](runbook/Invoke-CapacityAutoscale.ps1)) — reads recent snapshots from the Lakehouse SQL endpoint, applies [runbook/Decision-Logic.ps1](runbook/Decision-Logic.ps1), and resizes via ARM.
- **Policy** ([config/autoscale-config.json](config/autoscale-config.json)) — thresholds, SKU ladder, per‑capacity min/max and reservation floor.

## Repository layout

| Path | Purpose |
|---|---|
| `config/autoscale-config.json` | Thresholds, SKU ladder, per‑capacity overrides |
| `dax/fleet-metrics.dax` | Tier‑1 per‑capacity extract (source of truth for the notebook) |
| `notebook/collect_capacity_metrics.py` | Fabric notebook: DAX → Delta table |
| `sql/create_lakehouse_tables.sql` | Delta table schema + the runbook's read query |
| `runbook/Decision-Logic.ps1` | Pure, testable decision functions |
| `runbook/Invoke-CapacityAutoscale.ps1` | Main runbook (dry‑run by default) |
| `docs/scaling-policy.md` | Documentation‑grounded thresholds + elastic‑feature setup |

## Setup

### 1. Semantic model access
The notebook identity needs **Build** permission on the *Fabric Capacity Metrics* semantic model (service → dataset → Manage permissions → Build).

### 2. Lakehouse + notebook
1. Create (or pick) a Lakehouse.
2. Import `notebook/collect_capacity_metrics.py` as a notebook, attach that Lakehouse.
3. Run once — it creates `capacity_metrics_history` (schema in `sql/create_lakehouse_tables.sql`).
4. Schedule it **hourly**. (Capacity Metrics data lags ~15–30 min, so hourly is the right cadence — sub‑15‑min is noise.)

### 3. Azure Automation
1. **Managed identity** on the Automation account. Grant it, on each target Fabric capacity (or the resource group), a custom role with:
   `Microsoft.Fabric/capacities/read`, `Microsoft.Fabric/capacities/write`
   (add `suspend/action`, `resume/action` if you later add pause/resume).
2. **Modules:** import `Az.Accounts` (and it pulls `Az.Resources` for `Invoke-AzRestMethod`).
3. **Config is embedded in the runbook** — edit the `$EmbeddedConfigJson` block in `runbook/Invoke-CapacityAutoscale.ps1` (fill in `subscriptionId`, each capacity's `resourceGroup`, and `reservedFloorSku` if reserved). No `AutoscaleConfig` variable is required. *(Optional override: keep config external by creating an Automation variable and passing `-ConfigVariableName`, or a file via `-ConfigPath`.)*
4. **Variables:** `AutoscaleState` — initial value `{}` (holds cooldown/audit state).
5. Import both `runbook/*.ps1` (keep them in the same runbook or publish `Decision-Logic.ps1` as a child/module — in Automation, inline the functions if you can't dot‑source `$PSScriptRoot`).
6. **Schedule** `Invoke-CapacityAutoscale` hourly, a few minutes after the notebook.

### 4. Go live safely
Runbook parameters:
```
-SqlEndpoint   "<lakehouse>.datawarehouse.fabric.microsoft.com"   # SQL analytics endpoint
-LakehouseName "<lakehouse name>"
-LookbackHours 8
# add -Execute ONLY when you're ready to allow real resizes
```
- **First runs: omit `-Execute`** → dry run, logs proposed actions only.
- Watch the logs for a few cycles, confirm the decisions look right, then add `-Execute`.

## Local testing (dry run)

```powershell
# Requires Az.Accounts; uses your interactive login for the SQL token.
Connect-AzAccount
.\runbook\Invoke-CapacityAutoscale.ps1 `
    -ConfigPath   .\config\autoscale-config.json `
    -SqlEndpoint  "<endpoint>" `
    -LakehouseName "<lakehouse>" `
    -LookbackHours 8
# (no -Execute => nothing is resized)
```

## Current state / notes

- Tenant today: **1 capacity — `tmcadlfabric`, F64, East US, ~20% utilized** → a scale‑down candidate once history accrues and (if reserved) the floor is set.
- **v2 ideas:** Tier‑2 interactive‑vs‑background CU split (needs `TREATAS` capacity+timepoint injection); pause/resume off‑hours; per‑capacity target headroom; email/Teams notification on each action.
- See `docs/scaling-policy.md` for the recommended built‑in elastic features (capacity overage, surge protection, Spark autoscale billing) that absorb spikes so this runbook only handles sustained trends.
