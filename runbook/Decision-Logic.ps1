<#
.SYNOPSIS
    Pure decision functions for the Fabric capacity autoscaler.
    No side effects, no Azure calls - unit-testable in isolation.

.DESCRIPTION
    Dot-source this from Invoke-CapacityAutoscale.ps1:
        . "$PSScriptRoot\Decision-Logic.ps1"

    Policy (documentation-grounded - see docs/scaling-policy.md):
      * Scale UP is asymmetric-fast: immediate on real throttling, else sustained >80%.
        Target can jump multiple steps to bring projected utilization under headroom.
      * Scale DOWN is conservative: sustained (many windows) <30% on 24h AND 7d,
        zero throttling, Healthy, one step at a time, never below the reserved floor,
        and only if the smaller SKU keeps projected utilization under headroom.
#>

Set-StrictMode -Version Latest

function Get-SkuCU {
    # F64 -> 64. The integer in an F-SKU name equals its base Capacity Units (CU/s).
    param([Parameter(Mandatory)][string]$Sku)
    if ($Sku -match '^[Ff](\d+)$') { return [int]$Matches[1] }
    throw "Unrecognized SKU '$Sku' (expected F<number>, e.g. F64)."
}

function Get-SkuIndex {
    param([Parameter(Mandatory)][string]$Sku, [Parameter(Mandatory)][string[]]$Ladder)
    return [array]::IndexOf($Ladder, $Sku.ToUpper())
}

function Get-NextSkuDown {
    param([Parameter(Mandatory)][string]$Sku, [Parameter(Mandatory)][string[]]$Ladder)
    $i = Get-SkuIndex -Sku $Sku -Ladder $Ladder
    if ($i -le 0) { return $null }
    return $Ladder[$i - 1]
}

function Resolve-TargetScaleUpSku {
    # Smallest SKU (>= current, <= maxSku) whose projected utilization < headroom.
    # projected = currentUtil * currentCU / candidateCU  (bigger SKU => lower %).
    param(
        [Parameter(Mandatory)][string]$CurrentSku,
        [Parameter(Mandatory)][double]$CurrentUtilPct,
        [Parameter(Mandatory)][string[]]$Ladder,
        [Parameter(Mandatory)][string]$MaxSku,
        [Parameter(Mandatory)][double]$HeadroomPct
    )
    $currentCU = Get-SkuCU $CurrentSku
    $maxIdx    = Get-SkuIndex -Sku $MaxSku -Ladder $Ladder
    $startIdx  = (Get-SkuIndex -Sku $CurrentSku -Ladder $Ladder) + 1
    for ($i = $startIdx; $i -le $maxIdx; $i++) {
        $candidate   = $Ladder[$i]
        $projected   = $CurrentUtilPct * $currentCU / (Get-SkuCU $candidate)
        if ($projected -lt $HeadroomPct) { return $candidate }
    }
    # Nothing fully fits under headroom within maxSku -> go as high as allowed.
    if ($maxIdx -ge $startIdx) { return $Ladder[$maxIdx] }
    return $null   # already at/above maxSku
}

function Test-NewestAll {
    # True if the newest $Count snapshots ALL satisfy $Predicate. Requires >= $Count rows.
    param(
        [Parameter(Mandatory)][object[]]$Snapshots,   # newest-first
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][scriptblock]$Predicate
    )
    if ($Snapshots.Count -lt $Count) { return $false }
    for ($i = 0; $i -lt $Count; $i++) {
        if (-not (& $Predicate $Snapshots[$i])) { return $false }
    }
    return $true
}

function Test-Unhealthy {
    param($RiskValue)
    if ($null -eq $RiskValue) { return $false }
    return ($RiskValue.ToString().Trim().ToLower() -ne 'healthy')
}

function Get-CapacityDecision {
    <#
      Returns: [pscustomobject] @{
          CapacityName; CurrentSku; Action ('up'|'down'|'none'); TargetSku; Reasons[] }
      $Snapshots: newest-first array of rows for ONE capacity (SQL column names).
    #>
    param(
        [Parameter(Mandatory)][object[]]$Snapshots,
        [Parameter(Mandatory)][object]$Config,       # parsed autoscale-config.json .evaluation etc.
        [Parameter(Mandatory)][object]$CapConfig     # merged per-capacity settings (enabled/min/max/floor)
    )

    $ev     = $Config.evaluation
    $ladder = $Config.skuLadder
    $newest = $Snapshots[0]
    $name   = $newest.capacity_name
    $curSku = "$($newest.sku)".ToUpper()

    $decision = [pscustomobject]@{
        CapacityName = $name
        CurrentSku   = $curSku
        Action       = 'none'
        TargetSku    = $curSku
        Reasons      = @()
    }

    if (-not $CapConfig.enabled) { $decision.Reasons += 'capacity disabled in config'; return $decision }
    if ("$($newest.state)".ToLower() -ne 'active') { $decision.Reasons += "state=$($newest.state) (not Active)"; return $decision }
    if ([string]::IsNullOrWhiteSpace($curSku)) { $decision.Reasons += 'SKU not reported'; return $decision }

    # ---- SCALE UP -----------------------------------------------------------
    # Immediate: real user-visible throttling on the newest snapshot.
    $hardThrottle = ($newest.throttling_s_1h -gt 0) -or ($newest.rejected_ops_1h -gt 0) -or
                    ($newest.p95_int_delay_1h -ge 100) -or ($newest.p95_int_reject_1h -ge 100) -or
                    ($newest.p95_bg_reject_1h -ge 100)

    # Sustained: newest N snapshots all hot (util>threshold or unhealthy risk).
    $sustainedHot = Test-NewestAll -Snapshots $Snapshots -Count $ev.consecutiveSignalsRequired -Predicate {
        param($s) ($s.util_pct_1h -gt $ev.scaleUpUtilizationPct) -or (Test-Unhealthy $s.risk_1h)
    }

    if ($hardThrottle -or $sustainedHot) {
        $target = Resolve-TargetScaleUpSku -CurrentSku $curSku -CurrentUtilPct ([double]$newest.util_pct_1h) `
                    -Ladder $ladder -MaxSku $CapConfig.maxSku -HeadroomPct $ev.targetHeadroomPct
        if ($target -and (Get-SkuIndex $target $ladder) -gt (Get-SkuIndex $curSku $ladder)) {
            $decision.Action    = 'up'
            $decision.TargetSku = $target
            if ($hardThrottle) { $decision.Reasons += 'active throttling on newest snapshot' }
            if ($sustainedHot) { $decision.Reasons += "sustained util > $($ev.scaleUpUtilizationPct)% over $($ev.consecutiveSignalsRequired) snapshots" }
        } else {
            $decision.Reasons += "up wanted but already at maxSku ($($CapConfig.maxSku))"
        }
        return $decision
    }

    # ---- SCALE DOWN ---------------------------------------------------------
    $sustainedCold = Test-NewestAll -Snapshots $Snapshots -Count $ev.scaleDownConsecutiveSignalsRequired -Predicate {
        param($s)
        ($s.util_pct_24h -lt $ev.scaleDownPeakUtilizationPct) -and
        ($s.util_pct_7d  -lt $ev.scaleDownPeakUtilizationPct) -and
        ($s.throttling_s_24h -eq 0) -and ($s.rejected_ops_24h -eq 0) -and
        (-not (Test-Unhealthy $s.risk_24h))
    }

    if ($sustainedCold) {
        $nextDown = Get-NextSkuDown -Sku $curSku -Ladder $ladder
        $floor    = if ($CapConfig.reservedFloorSku) { $CapConfig.reservedFloorSku } else { $CapConfig.minSku }
        if (-not $nextDown) {
            $decision.Reasons += 'already at smallest SKU on the ladder'
        } elseif ((Get-SkuIndex $nextDown $ladder) -lt (Get-SkuIndex $floor $ladder)) {
            $decision.Reasons += "down blocked by floor ($floor" + $(if ($CapConfig.reservedFloorSku) { ', reserved' } else { ', minSku' }) + ')'
        } else {
            # Fit check: projected utilization on the smaller SKU must stay under headroom.
            $projected = [double]$newest.util_pct_24h * (Get-SkuCU $curSku) / (Get-SkuCU $nextDown)
            if ($projected -lt $ev.targetHeadroomPct) {
                $decision.Action    = 'down'
                $decision.TargetSku = $nextDown
                $decision.Reasons  += "sustained util < $($ev.scaleDownPeakUtilizationPct)% (24h & 7d) over $($ev.scaleDownConsecutiveSignalsRequired) snapshots; projected $([math]::Round($projected,1))% on $nextDown"
            } else {
                $decision.Reasons += "down skipped: projected $([math]::Round($projected,1))% on $nextDown exceeds headroom $($ev.targetHeadroomPct)%"
            }
        }
        return $decision
    }

    $decision.Reasons += 'within band - no action'
    return $decision
}
