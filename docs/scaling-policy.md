# Scaling policy (documentation-grounded)

This is the "why" behind the thresholds in [`config/autoscale-config.json`](../config/autoscale-config.json) and the logic in [`runbook/Decision-Logic.ps1`](../runbook/Decision-Logic.ps1). All thresholds trace to Microsoft docs (linked inline).

## 1. The signal that actually matters

Fabric **smooths** usage, so a capacity can exceed 100% utilization *without* throttling. The authoritative "in trouble" signal is **future‑committed compute**, expressed as the throttling threshold percentages ([Fabric throttling policy](https://learn.microsoft.com/fabric/enterprise/throttling), [capacity events](https://learn.microsoft.com/fabric/real-time-hub/explore-fabric-capacity-overview-events)):

| Stage | Future compute committed | Impact | Metric column |
|---|---|---|---|
| Overage protection | ≤ 10 min | none | — |
| **Interactive delay** | 10–60 min | 20 s query delay | `p95_int_delay_1h` |
| **Interactive rejection** | 60 min – 24 hr | queries error | `p95_int_reject_1h` |
| **Background rejection** | > 24 hr | refreshes/jobs rejected | `p95_bg_reject_1h` |

Each `p95_*` is **% of the throttling limit committed** — **≥ 100 % = actively throttling**. The app's `util_pct_*` is measured against **base** capacity units, excluding autoscale ([Compute page](https://learn.microsoft.com/fabric/enterprise/metrics-app-compute-page)).

## 2. Scale UP (asymmetric-fast)

Trigger if **any** of:
- **Immediate** (bypasses hysteresis — users are being hurt): `throttling_s_1h > 0`, `rejected_ops_1h > 0`, or any `p95_* ≥ 100`.
- **Sustained**: `util_pct_1h > 80` for `consecutiveSignalsRequired` snapshots, or `risk_1h ≠ Healthy`. The 80 % line is Microsoft's "consistently above ~80 % during peak" guidance ([growth guide](https://learn.microsoft.com/fabric/enterprise/capacity-planning-manage-capacity-growth-governance)); the Real‑Time alert tutorial uses ≥ 80 % as an early‑warning ([tutorial](https://learn.microsoft.com/fabric/real-time-hub/tutorial-monitor-capacity-threshold)).

**Target SKU:** jump to the smallest SKU whose *projected* utilization (`current% × currentCU / candidateCU`) is under `targetHeadroomPct` (80 %). Can move multiple steps to meet demand fast. Pick a size where highest usage "sits comfortably under 100 %" ([plan deployment](https://learn.microsoft.com/fabric/enterprise/capacity-planning-plan-deployment)).

## 3. Scale DOWN (conservative)

Trigger only if **all**, for `scaleDownConsecutiveSignalsRequired` snapshots:
- `util_pct_24h < 30` **and** `util_pct_7d < 30` — Microsoft's "peak usage remaining below 30 %" scale‑down bar ([growth guide](https://learn.microsoft.com/fabric/enterprise/capacity-planning-manage-capacity-growth-governance)),
- `throttling_s_24h = 0` **and** `rejected_ops_24h = 0`, `risk_24h = Healthy`,
- **fit check:** projected utilization on the next‑smaller SKU stays under `targetHeadroomPct`.

Then step **one SKU down** (never below `reservedFloorSku`/`minSku`).

> ⚠️ **Caveat baked into the config:** *"scaling below your reserved instance capacity doesn't affect your bill"* ([scale capacity](https://learn.microsoft.com/fabric/enterprise/scale-capacity)). If a capacity is on a reservation, set `reservedFloorSku` to the reserved size — scaling below it is pure risk with no savings.

> ⚠️ Some resizes are slower / have side effects: **F32↔F64 changes licensing**, and crossing **F256↔F512** can be slow. Flagged via `boundaries` in config.

## 4. Anti-flap

- **Hysteresis:** N consecutive snapshots must agree (up = `consecutiveSignalsRequired`, down = `scaleDownConsecutiveSignalsRequired`, higher).
- **Cooldown:** no second resize within `cooldownMinutes` (enforced from persisted state).
- React on the 1‑hour window; confirm scale‑down on 24 h **and** 7 d. Vertical scaling is fast with a short pause ([performance efficiency](https://learn.microsoft.com/azure/well-architected/microsoft-fabric/performance-efficiency)).

## 5. Let the built-in elastic features absorb spikes (recommended)

Microsoft's toolkit is **optimize → scale up → scale out**, plus elastic features that handle spikes better than an SKU loop. Turn these on so the runbook only chases *sustained* trends, not every spike.

### Capacity overage (preview, F16+)
Auto‑pays off transient overage at **3× PAYG**, up to an admin limit, preventing throttling for occasional/small spikes. *"If you're throttled regularly … scale up instead."* Caution scaling **down** with it enabled (can trigger big overages). ([overview](https://learn.microsoft.com/fabric/enterprise/capacity-overage-overview) · [enable](https://learn.microsoft.com/fabric/enterprise/enable-capacity-overage))
Enable: **Admin portal → Capacity settings → select capacity → Capacity overage**, set a rolling 24‑hour CU‑hour limit (needs quota = 1/24 of the limit).

### Surge protection
Caps background‑job CU to protect interactive users and helps the capacity recover after throttling. Rejects background jobs when active. Per capacity. ([surge protection](https://learn.microsoft.com/fabric/enterprise/surge-protection))
Enable: **Admin portal → Capacity settings → select capacity → Surge protection**, set a background rejection threshold; tune it from the Metrics app throttling charts.

### Autoscale Billing for Spark (F2+)
Offloads Spark to **serverless pay‑as‑you‑go** so Spark **doesn't consume capacity CU** — often lets you run a permanently **smaller base SKU**. If Spark is a real CU driver, this is the biggest single cost lever. ([overview](https://learn.microsoft.com/fabric/data-engineering/autoscale-billing-for-spark-overview) · [configure](https://learn.microsoft.com/fabric/data-engineering/configure-autoscale-billing))
Enable: **Admin portal → Capacity settings → Fabric Capacity tab → select capacity → Autoscale Billing for Fabric Spark**, set a max CU. (Then you can downsize the base SKU via pause → resume → resize.)

**Net design:** overage + surge protection (+ Spark autoscale billing if Spark‑heavy) absorb spikes; this runbook moves the **base SKU** only on sustained shifts, gated by hysteresis, cooldown, the 30 % scale‑down bar, and the reservation floor.
