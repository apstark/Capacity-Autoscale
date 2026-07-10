<#
.SYNOPSIS
    Self-contained Fabric capacity autoscaler runbook. ONE file - import it, set the
    parameters in the Test pane, and run. No sibling scripts, no Automation
    variables, no config files required.

.DESCRIPTION
    Reads hourly metrics from a Lakehouse SQL analytics endpoint, decides per
    capacity, and resizes the base SKU via ARM.

    Setup:
      1. Assign the Automation account's Managed Identity, on each Fabric capacity:
           Microsoft.Fabric/capacities/read, Microsoft.Fabric/capacities/write
      2. Import Az.Accounts (pulls Az.Resources) into the Automation account.
      3. Create this runbook, paste this file, Publish.
      4. Test pane -> set SqlEndpoint + LakehouseName (and SubscriptionId +
         ResourceGroup when you're ready to really resize) -> Run.

    SAFETY: DryRun defaults to $true (log only). Set it to $false to actually
    resize. Anti-flap is built in and needs no stored state:
      * Hysteresis: N consecutive snapshots from the Lakehouse history must agree.
      * Cooldown: derived from the last observed SKU change in that same history.

.PARAMETER SqlEndpoint     Lakehouse SQL analytics endpoint (e.g. xxx.datawarehouse.fabric.microsoft.com).
.PARAMETER LakehouseName   Database name on that endpoint (holds capacity_metrics_history).
.PARAMETER DryRun          $true (default) logs only; $false performs resizes.
.PARAMETER SubscriptionId  Azure subscription of the capacities (required to resize).
.PARAMETER ResourceGroup   Default resource group for the capacities (required to resize).
.PARAMETER WebhookUrl      Optional Teams/Workflows webhook for notifications.
.PARAMETER CapacityFilter  Optional: only act on this capacity name (blank = all).
.PARAMETER LookbackHours   Hours of history to read for hysteresis/cooldown (default 8).
.PARAMETER ConfigPath      Optional: load config JSON from a file to override the embedded config.
#>
[CmdletBinding()]
param(
    [string]$SqlEndpoint    = '',
    [string]$LakehouseName  = '',
    [bool]$DryRun           = $true,
    [string]$SubscriptionId = '',
    [string]$ResourceGroup  = '',
    [string]$WebhookUrl     = '',
    [string]$CapacityFilter = '',
    [int]$LookbackHours     = 8,
    [string]$ConfigPath     = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ===========================================================================
# EMBEDDED CONFIG - thresholds, SKU ladder, per-capacity min/max/floor.
# Environment values (subscription, resource group, webhook) come from the
# PARAMETERS above. Edit the per-capacity limits / reserved floors here.
# ===========================================================================
$EmbeddedConfigJson = @'
{
  "evaluation": {
    "scaleUpUtilizationPct": 80,
    "scaleUpThrottleWarnPct": 80,
    "scaleDownPeakUtilizationPct": 30,
    "targetHeadroomPct": 80,
    "cooldownMinutes": 60,
    "consecutiveSignalsRequired": 3,
    "scaleDownConsecutiveSignalsRequired": 6
  },
  "notifications": { "notifyOnDryRun": true, "notifyOnNoAction": false },
  "skuLadder": ["F2","F4","F8","F16","F32","F64","F128","F256","F512","F1024","F2048"],
  "boundaries": { "slowResizePairs": [["F32","F64"]], "slowAtOrAbove": "F512" },
  "azure": { "apiVersion": "2023-11-01" },
  "defaults": { "enabled": true, "reservedFloorSku": null, "minSku": "F2", "maxSku": "F2048" },
  "capacities": {
    "tmcadlfabric": {
      "capacityId": "49B9055E-B898-4EB4-B829-0688D8BB6685",
      "region": "East US",
      "enabled": true,
      "minSku": "F8",
      "maxSku": "F256",
      "reservedFloorSku": null,
      "resourceGroup": ""
    }
  }
}
'@

# ===========================================================================
# DECISION LOGIC (pure functions - unit-tested by tests/Decision-Logic.Tests.ps1)
# ===========================================================================
function Get-SkuCU {
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
        if (($CurrentUtilPct * $currentCU / (Get-SkuCU $Ladder[$i])) -lt $HeadroomPct) { return $Ladder[$i] }
    }
    if ($maxIdx -ge $startIdx) { return $Ladder[$maxIdx] }
    return $null
}
function Test-NewestAll {
    param([Parameter(Mandatory)][object[]]$Snapshots, [Parameter(Mandatory)][int]$Count, [Parameter(Mandatory)][scriptblock]$Predicate)
    if ($Snapshots.Count -lt $Count) { return $false }
    for ($i = 0; $i -lt $Count; $i++) { if (-not (& $Predicate $Snapshots[$i])) { return $false } }
    return $true
}
function Test-Unhealthy {
    param($RiskValue)
    if ($null -eq $RiskValue) { return $false }
    return ($RiskValue.ToString().Trim().ToLower() -ne 'healthy')
}
function Get-CapacityDecision {
    param(
        [Parameter(Mandatory)][object[]]$Snapshots,   # newest-first, ONE capacity
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$CapConfig
    )
    $ev = $Config.evaluation; $ladder = $Config.skuLadder
    $newest = $Snapshots[0]; $name = $newest.capacity_name; $curSku = "$($newest.sku)".ToUpper()
    $decision = [pscustomobject]@{ CapacityName = $name; CurrentSku = $curSku; Action = 'none'; TargetSku = $curSku; Reasons = @() }

    if (-not $CapConfig.enabled) { $decision.Reasons += 'capacity disabled in config'; return $decision }
    if ("$($newest.state)".ToLower() -ne 'active') { $decision.Reasons += "state=$($newest.state) (not Active)"; return $decision }
    if ([string]::IsNullOrWhiteSpace($curSku)) { $decision.Reasons += 'SKU not reported'; return $decision }

    # SCALE UP - immediate on real throttling, else sustained hot.
    $hardThrottle = ($newest.throttling_s_1h -gt 0) -or ($newest.rejected_ops_1h -gt 0) -or
                    ($newest.p95_int_delay_1h -ge 100) -or ($newest.p95_int_reject_1h -ge 100) -or ($newest.p95_bg_reject_1h -ge 100)
    $sustainedHot = Test-NewestAll -Snapshots $Snapshots -Count $ev.consecutiveSignalsRequired -Predicate {
        param($s) ($s.util_pct_1h -gt $ev.scaleUpUtilizationPct) -or (Test-Unhealthy $s.risk_1h)
    }
    if ($hardThrottle -or $sustainedHot) {
        $target = Resolve-TargetScaleUpSku -CurrentSku $curSku -CurrentUtilPct ([double]$newest.util_pct_1h) `
                    -Ladder $ladder -MaxSku $CapConfig.maxSku -HeadroomPct $ev.targetHeadroomPct
        if ($target -and (Get-SkuIndex $target $ladder) -gt (Get-SkuIndex $curSku $ladder)) {
            $decision.Action = 'up'; $decision.TargetSku = $target
            if ($hardThrottle) { $decision.Reasons += 'active throttling on newest snapshot' }
            if ($sustainedHot) { $decision.Reasons += "sustained util > $($ev.scaleUpUtilizationPct)% over $($ev.consecutiveSignalsRequired) snapshots" }
        } else { $decision.Reasons += "up wanted but already at maxSku ($($CapConfig.maxSku))" }
        return $decision
    }

    # SCALE DOWN - sustained cold + fit check + floor.
    $sustainedCold = Test-NewestAll -Snapshots $Snapshots -Count $ev.scaleDownConsecutiveSignalsRequired -Predicate {
        param($s)
        ($s.util_pct_24h -lt $ev.scaleDownPeakUtilizationPct) -and ($s.util_pct_7d -lt $ev.scaleDownPeakUtilizationPct) -and
        ($s.throttling_s_24h -eq 0) -and ($s.rejected_ops_24h -eq 0) -and (-not (Test-Unhealthy $s.risk_24h))
    }
    if ($sustainedCold) {
        $nextDown = Get-NextSkuDown -Sku $curSku -Ladder $ladder
        $floor = if ($CapConfig.reservedFloorSku) { $CapConfig.reservedFloorSku } else { $CapConfig.minSku }
        if (-not $nextDown) {
            $decision.Reasons += 'already at smallest SKU on the ladder'
        } elseif ((Get-SkuIndex $nextDown $ladder) -lt (Get-SkuIndex $floor $ladder)) {
            $decision.Reasons += "down blocked by floor ($floor" + $(if ($CapConfig.reservedFloorSku) { ', reserved' } else { ', minSku' }) + ')'
        } else {
            $projected = [double]$newest.util_pct_24h * (Get-SkuCU $curSku) / (Get-SkuCU $nextDown)
            if ($projected -lt $ev.targetHeadroomPct) {
                $decision.Action = 'down'; $decision.TargetSku = $nextDown
                $decision.Reasons += "sustained util < $($ev.scaleDownPeakUtilizationPct)% (24h & 7d) over $($ev.scaleDownConsecutiveSignalsRequired) snapshots; projected $([math]::Round($projected,1))% on $nextDown"
            } else {
                $decision.Reasons += "down skipped: projected $([math]::Round($projected,1))% on $nextDown exceeds headroom $($ev.targetHeadroomPct)%"
            }
        }
        return $decision
    }

    $decision.Reasons += 'within band - no action'
    return $decision
}

# ===========================================================================
# RUNTIME HELPERS
# ===========================================================================
function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}
function Get-Config {
    param([string]$Path)
    if ($Path) { return (Get-Content -Raw -Path $Path | ConvertFrom-Json) }
    return ($EmbeddedConfigJson | ConvertFrom-Json)
}
function Get-SqlAccessToken {
    $t = Get-AzAccessToken -ResourceUrl 'https://database.windows.net/'
    if ($t.Token -is [System.Security.SecureString]) { return (New-Object System.Net.NetworkCredential('', $t.Token)).Password }
    return $t.Token
}
function Get-MetricSnapshots {
    param([string]$Endpoint, [string]$Database, [int]$Lookback)
    $query = @"
SELECT capacity_id, capacity_name, region, sku, state, snapshot_time_utc,
       util_pct_1h, util_pct_24h, util_pct_7d, throttling_s_1h, throttling_s_24h,
       p95_int_delay_1h, p95_int_reject_1h, p95_bg_reject_1h,
       rejected_ops_1h, rejected_ops_24h, risk_1h, risk_24h
FROM dbo.capacity_metrics_history
WHERE snapshot_time_utc >= DATEADD(HOUR, -@LookbackHours, SYSUTCDATETIME())
ORDER BY capacity_id, snapshot_time_utc DESC;
"@
    $conn = New-Object System.Data.SqlClient.SqlConnection
    $conn.ConnectionString = "Server=$Endpoint;Database=$Database;Encrypt=True;TrustServerCertificate=False;Connect Timeout=60;"
    $conn.AccessToken = Get-SqlAccessToken
    $conn.Open()
    try {
        $cmd = $conn.CreateCommand(); $cmd.CommandText = $query
        [void]$cmd.Parameters.AddWithValue('@LookbackHours', $Lookback)
        $reader = $cmd.ExecuteReader()
        $rows = New-Object System.Collections.Generic.List[object]
        while ($reader.Read()) {
            $o = [ordered]@{}
            for ($i = 0; $i -lt $reader.FieldCount; $i++) { $o[$reader.GetName($i)] = if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) } }
            $rows.Add([pscustomobject]$o)
        }
        return $rows
    } finally { $conn.Close() }
}
function Merge-CapConfig {
    param($Config, [string]$CapName, [string]$DefaultResourceGroup)
    $d = $Config.defaults; $c = Get-Prop $Config.capacities $CapName
    $rg = [string](Get-Prop $c 'resourceGroup' '')
    if ([string]::IsNullOrWhiteSpace($rg)) { $rg = $DefaultResourceGroup }
    return [pscustomobject]@{
        enabled          = [bool](Get-Prop $c 'enabled' (Get-Prop $d 'enabled' $true))
        minSku           = [string](Get-Prop $c 'minSku' (Get-Prop $d 'minSku' 'F2'))
        maxSku           = [string](Get-Prop $c 'maxSku' (Get-Prop $d 'maxSku' 'F2048'))
        reservedFloorSku = Get-Prop $c 'reservedFloorSku' (Get-Prop $d 'reservedFloorSku' $null)
        resourceGroup    = $rg
    }
}
function Get-MinutesSinceLastResize {
    param([object[]]$Snaps, [DateTime]$Now)
    $cur = "$($Snaps[0].sku)"
    for ($i = 1; $i -lt $Snaps.Count; $i++) {
        if ("$($Snaps[$i].sku)" -ne $cur) {
            $ct = [DateTime]::SpecifyKind([DateTime]$Snaps[$i - 1].snapshot_time_utc, [DateTimeKind]::Utc)
            return ($Now - $ct).TotalMinutes
        }
    }
    return [double]::PositiveInfinity
}
function Invoke-CapacityResize {
    param([string]$SubscriptionId, [string]$ResourceGroup, [string]$CapacityName, [string]$TargetSku, [string]$ApiVersion)
    $path = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Fabric/capacities/$CapacityName`?api-version=$ApiVersion"
    $payload = @{ sku = @{ name = $TargetSku; tier = 'Fabric' } } | ConvertTo-Json -Depth 4
    $resp = Invoke-AzRestMethod -Method PATCH -Path $path -Payload $payload
    if ($resp.StatusCode -ge 300) { throw "Resize $CapacityName -> $TargetSku failed: HTTP $($resp.StatusCode) $($resp.Content)" }
    return $resp.StatusCode
}
function Send-CapacityNotification {
    param([object[]]$Report, [string]$WebhookUrl, [bool]$NotifyOnDryRun, [bool]$NotifyOnNoAction, [bool]$IsDryRun, [DateTime]$Now)
    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) { return }
    $items = @($Report | Where-Object {
        switch ($_.Outcome) {
            'resized' { $true } 'error' { $true } 'blocked-no-rg' { $true }
            'would-scale' { $NotifyOnDryRun } 'cooldown' { $NotifyOnDryRun } default { $NotifyOnNoAction }
        }
    })
    if ($items.Count -eq 0) { return }
    $mode = if ($IsDryRun) { 'DRY RUN' } else { 'EXECUTE' }
    $facts = foreach ($r in $items) {
        $val = if ($r.Action -eq 'none') { "no action - $($r.Reasons)" }
               else { "$($r.Action.ToUpper()) $($r.CurrentSku) -> $($r.TargetSku)  [$($r.Outcome)]  -  $($r.Reasons)" }
        @{ name = "$($r.Capacity)"; value = "$val" }
    }
    $outcomes = @($items | ForEach-Object { $_.Outcome })
    $color = if ($outcomes -contains 'error') { 'D13438' } elseif ($outcomes -contains 'resized') { '107C10' } else { '0078D4' }
    $card = @{ '@type' = 'MessageCard'; '@context' = 'http://schema.org/extensions'; themeColor = $color
        summary = "Fabric Capacity Autoscale ($mode)"; title = "Fabric Capacity Autoscale - $mode"
        sections = @(@{ activitySubtitle = "Run at $($Now.ToString('u'))"; facts = @($facts); markdown = $true }) }
    try { Invoke-RestMethod -Method Post -Uri $WebhookUrl -ContentType 'application/json' -Body ($card | ConvertTo-Json -Depth 8) | Out-Null; Write-Output "Notification sent ($($items.Count) item(s))." }
    catch { Write-Warning "Notification failed: $_" }
}

# ===========================================================================
# MAIN
# ===========================================================================
function Start-Autoscale {
    if ([string]::IsNullOrWhiteSpace($SqlEndpoint) -or [string]::IsNullOrWhiteSpace($LakehouseName)) {
        throw "SqlEndpoint and LakehouseName are required (set them in the Test pane)."
    }
    Write-Output "=== Fabric Capacity Autoscale run (DryRun=$DryRun) ==="
    if (-not (Get-AzContext)) { Connect-AzAccount -Identity | Out-Null }

    $config    = Get-Config -Path $ConfigPath
    $subId     = if ($SubscriptionId) { $SubscriptionId } else { [string](Get-Prop $config.azure 'subscriptionId' '') }
    $apiVer    = [string](Get-Prop $config.azure 'apiVersion' '2023-11-01')
    $cool      = [int](Get-Prop $config.evaluation 'cooldownMinutes' 60)
    $notif     = Get-Prop $config 'notifications'
    $webhook   = if ($WebhookUrl) { $WebhookUrl } else { [string](Get-Prop $notif 'webhookUrl' '') }
    $notifyDry = [bool](Get-Prop $notif 'notifyOnDryRun' $true)
    $notifyNon = [bool](Get-Prop $notif 'notifyOnNoAction' $false)
    $nowUtc    = [DateTime]::UtcNow

    $allRows = Get-MetricSnapshots -Endpoint $SqlEndpoint -Database $LakehouseName -Lookback $LookbackHours
    if ($allRows.Count -eq 0) { Write-Warning "No snapshots in the last $LookbackHours h - is the notebook running?"; return }

    $report = New-Object System.Collections.Generic.List[object]
    foreach ($grp in ($allRows | Group-Object capacity_name)) {
        $capName = $grp.Name
        if ($CapacityFilter -and $capName -ne $CapacityFilter) { continue }
        $snaps    = @($grp.Group)
        $capCfg   = Merge-CapConfig -Config $config -CapName $capName -DefaultResourceGroup $ResourceGroup
        $decision = Get-CapacityDecision -Snapshots $snaps -Config $config -CapConfig $capCfg

        $line = "[$capName] $($decision.CurrentSku) -> $($decision.Action.ToUpper())"
        if ($decision.Action -ne 'none') { $line += " ($($decision.TargetSku))" }
        Write-Output ($line + " :: " + ($decision.Reasons -join '; '))

        $entry = [pscustomobject]@{ Capacity = $capName; CurrentSku = $decision.CurrentSku; Action = $decision.Action
            TargetSku = $decision.TargetSku; Outcome = 'none'; Reasons = ($decision.Reasons -join '; ') }
        if ($decision.Action -eq 'none') { $report.Add($entry); continue }

        $mins = Get-MinutesSinceLastResize -Snaps $snaps -Now $nowUtc
        if ($mins -lt $cool) {
            Write-Output "    -> skipped: cooldown ($([math]::Round($mins,0))/$cool min since last SKU change)"
            $entry.Outcome = 'cooldown'; $report.Add($entry); continue
        }
        if ($DryRun) {
            Write-Output "    -> DRY RUN: would resize to $($decision.TargetSku)"
            $entry.Outcome = 'would-scale'; $report.Add($entry); continue
        }
        if ([string]::IsNullOrWhiteSpace($subId)) {
            Write-Warning "    -> no SubscriptionId; cannot resize."; $entry.Outcome = 'error'; $entry.Reasons = 'missing SubscriptionId'; $report.Add($entry); continue
        }
        if ([string]::IsNullOrWhiteSpace($capCfg.resourceGroup)) {
            Write-Warning "    -> no ResourceGroup for $capName; skipping."; $entry.Outcome = 'blocked-no-rg'; $report.Add($entry); continue
        }
        try {
            $code = Invoke-CapacityResize -SubscriptionId $subId -ResourceGroup $capCfg.resourceGroup -CapacityName $capName -TargetSku $decision.TargetSku -ApiVersion $apiVer
            Write-Output "    -> RESIZED to $($decision.TargetSku) (HTTP $code)"; $entry.Outcome = 'resized'
        } catch { Write-Warning "    -> RESIZE FAILED: $_"; $entry.Outcome = 'error'; $entry.Reasons = "$_" }
        $report.Add($entry)
    }

    Send-CapacityNotification -Report $report.ToArray() -WebhookUrl $webhook -NotifyOnDryRun $notifyDry -NotifyOnNoAction $notifyNon -IsDryRun $DryRun -Now $nowUtc
    Write-Output "=== Done ==="
}

# Run main unless the file is being dot-sourced (e.g. by the Pester tests).
if ($MyInvocation.InvocationName -ne '.') { Start-Autoscale }
