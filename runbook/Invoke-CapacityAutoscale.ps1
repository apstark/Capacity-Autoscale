<#
.SYNOPSIS
    Self-contained Fabric capacity autoscaler runbook. ONE file - import it, set the
    parameters in the Test pane, and run. No sibling scripts, no Automation
    variables, no config files required.

.DESCRIPTION
    Reads hourly metrics from a Lakehouse SQL analytics endpoint, decides per
    capacity, and resizes the base SKU via ARM.

    Setup:
      1. Assign the Automation account's Managed Identity these roles at the
         subscription or resource-group scope that contains your capacities:
           Reader (to auto-discover each capacity's subscription + resource group),
           Microsoft.Fabric/capacities/read + write (to resize).
      2. Import Az.Accounts into the Automation account.
      3. Create this runbook, paste this file, Publish.
      4. Test pane -> set SqlEndpoint + LakehouseName -> Run (DryRun stays True).

    Subscription + resource group are resolved automatically from the capacity
    name, so they are not parameters. (Override in the embedded config only if the
    identity can't list capacities: set azure.subscriptionId + the capacity's
    resourceGroup.) Webhook URL and lookback hours are in the embedded config.

    SAFETY: DryRun defaults to $true (log only). Set it to $false to actually
    resize. Anti-flap is built in and needs no stored state:
      * Hysteresis: N consecutive snapshots from the Lakehouse history must agree.
      * Cooldown: derived from the last observed SKU change in that same history.

.PARAMETER SqlEndpoint    Lakehouse SQL analytics endpoint (e.g. xxx.datawarehouse.fabric.microsoft.com).
.PARAMETER LakehouseName  Database name on that endpoint (holds capacity_metrics_history).
.PARAMETER DryRun         $true (default) logs only; $false performs resizes.
.PARAMETER MinSku         Global floor SKU - never scale below this (default F2). Per-capacity overrides live in the embedded config.
.PARAMETER MaxSku         Global ceiling SKU - never scale above this (default F2048). Per-capacity overrides live in the embedded config.
#>
[CmdletBinding()]
param(
    [string]$SqlEndpoint   = '',
    [string]$LakehouseName = '',
    [bool]$DryRun          = $true,
    [string]$MinSku        = 'F2',
    [string]$MaxSku        = 'F2048'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$VerbosePreference  = 'SilentlyContinue'   # hide "Importing cmdlet/alias" module-load spam
$ProgressPreference = 'SilentlyContinue'

# ===========================================================================
# EMBEDDED CONFIG - thresholds, SKU ladder, optional per-capacity overrides.
# MinSku/MaxSku come from the PARAMETERS above (a capacity can override them here).
# Subscription + resource group are auto-discovered by capacity name; set them
# here only if the identity can't list capacities. Webhook + lookback here too.
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
    "scaleDownConsecutiveSignalsRequired": 6,
    "lookbackHours": 8
  },
  "notifications": { "webhookUrl": "", "notifyOnDryRun": true, "notifyOnNoAction": false },
  "skuLadder": ["F2","F4","F8","F16","F32","F64","F128","F256","F512","F1024","F2048"],
  "boundaries": { "slowResizePairs": [["F32","F64"]], "slowAtOrAbove": "F512" },
  "azure": { "apiVersion": "2023-11-01", "subscriptionId": "" },
  "defaults": { "enabled": true, "reservedFloorSku": null },
  "capacities": {
    "_example": {
      "_note": "Optional per-capacity overrides. Add a block keyed by the capacity name.",
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
function Fmt1 { param($v) if ($null -eq $v) { 'n/a' } else { [math]::Round([double]$v, 1) } }

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
    if ($curSku -notmatch '^F\d+$') { $decision.Reasons += "SKU '$curSku' is not an F-SKU - not auto-scalable (e.g. trial capacity)"; return $decision }

    # SCALE UP - immediate on real throttling, else sustained hot. Name the metric that tripped.
    $thr = @()
    if ($newest.throttling_s_1h  -gt 0)  { $thr += "throttling $(Fmt1 $newest.throttling_s_1h)s (1h)" }
    if ($newest.rejected_ops_1h  -gt 0)  { $thr += "$([int]$newest.rejected_ops_1h) rejected ops (1h)" }
    if ($newest.p95_int_delay_1h  -ge 100) { $thr += "interactive-delay P95 $(Fmt1 $newest.p95_int_delay_1h)%" }
    if ($newest.p95_int_reject_1h -ge 100) { $thr += "interactive-rejection P95 $(Fmt1 $newest.p95_int_reject_1h)%" }
    if ($newest.p95_bg_reject_1h  -ge 100) { $thr += "background-rejection P95 $(Fmt1 $newest.p95_bg_reject_1h)%" }
    $hardThrottle = $thr.Count -gt 0

    $sustainedHot = Test-NewestAll -Snapshots $Snapshots -Count $ev.consecutiveSignalsRequired -Predicate {
        param($s) ($s.util_pct_1h -gt $ev.scaleUpUtilizationPct) -or (Test-Unhealthy $s.risk_1h)
    }
    if ($hardThrottle -or $sustainedHot) {
        $target = Resolve-TargetScaleUpSku -CurrentSku $curSku -CurrentUtilPct ([double]$newest.util_pct_1h) `
                    -Ladder $ladder -MaxSku $CapConfig.maxSku -HeadroomPct $ev.targetHeadroomPct
        if ($target -and (Get-SkuIndex $target $ladder) -gt (Get-SkuIndex $curSku $ladder)) {
            $decision.Action = 'up'; $decision.TargetSku = $target
            if ($hardThrottle) { $decision.Reasons += "active throttling: $($thr -join ', ')" }
            if ($sustainedHot) { $decision.Reasons += "sustained util 1h > $($ev.scaleUpUtilizationPct)% (now $(Fmt1 $newest.util_pct_1h)%) over $($ev.consecutiveSignalsRequired) snapshots" }
            $proj = [double]$newest.util_pct_1h * (Get-SkuCU $curSku) / (Get-SkuCU $target)
            $decision.Reasons += "-> $target brings projected util ~$(Fmt1 $proj)% (target headroom $($ev.targetHeadroomPct)%)"
        } else { $decision.Reasons += "up wanted (util 1h $(Fmt1 $newest.util_pct_1h)%) but already at maxSku ($($CapConfig.maxSku))" }
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
                $decision.Reasons += "sustained low: util 24h $(Fmt1 $newest.util_pct_24h)% & 7d $(Fmt1 $newest.util_pct_7d)% both < $($ev.scaleDownPeakUtilizationPct)% over $($ev.scaleDownConsecutiveSignalsRequired) snapshots, no throttling; -> $nextDown projects ~$(Fmt1 $projected)% (< headroom $($ev.targetHeadroomPct)%)"
            } else {
                $decision.Reasons += "down skipped: -> $nextDown would project $(Fmt1 $projected)% (>= headroom $($ev.targetHeadroomPct)%) from util 24h $(Fmt1 $newest.util_pct_24h)%"
            }
        }
        return $decision
    }

    # No action: say which side of the band, with the numbers.
    $bits = @("util 1h/24h/7d = $(Fmt1 $newest.util_pct_1h)/$(Fmt1 $newest.util_pct_24h)/$(Fmt1 $newest.util_pct_7d)%")
    if ($newest.util_pct_24h -ge $ev.scaleDownPeakUtilizationPct) { $bits += "24h >= scale-down $($ev.scaleDownPeakUtilizationPct)%" }
    else { $bits += "cold but not for $($ev.scaleDownConsecutiveSignalsRequired) consecutive snapshots (have $($Snapshots.Count))" }
    if (($newest.throttling_s_24h -gt 0) -or ($newest.rejected_ops_24h -gt 0)) { $bits += "recent throttling blocks scale-down" }
    $decision.Reasons += "within band ($($bits -join '; '))"
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
function Get-Config { return ($EmbeddedConfigJson | ConvertFrom-Json) }
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
    param($Config, [string]$CapName, [string]$DefaultMinSku, [string]$DefaultMaxSku)
    $d = $Config.defaults; $c = Get-Prop $Config.capacities $CapName
    return [pscustomobject]@{
        enabled          = [bool](Get-Prop $c 'enabled' (Get-Prop $d 'enabled' $true))
        minSku           = [string](Get-Prop $c 'minSku' $DefaultMinSku)
        maxSku           = [string](Get-Prop $c 'maxSku' $DefaultMaxSku)
        reservedFloorSku = Get-Prop $c 'reservedFloorSku' (Get-Prop $d 'reservedFloorSku' $null)
        resourceGroup    = [string](Get-Prop $c 'resourceGroup' '')
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
function Get-FabricCapacityIndex {
    # Map lowercased capacity name -> full ARM resource id, across accessible subscriptions.
    param([string]$ApiVersion)
    $map = @{}
    foreach ($sub in (Get-AzSubscription -ErrorAction SilentlyContinue)) {
        try {
            $resp = Invoke-AzRestMethod -Method GET -Path "/subscriptions/$($sub.Id)/providers/Microsoft.Fabric/capacities?api-version=$ApiVersion"
            if ($resp.StatusCode -eq 200) {
                foreach ($c in (($resp.Content | ConvertFrom-Json).value)) { $map[$c.name.ToLower()] = $c.id }
            }
        } catch { }
    }
    return $map
}
function Invoke-CapacityResize {
    param([string]$ResourceId, [string]$TargetSku, [string]$ApiVersion)
    $payload = @{ sku = @{ name = $TargetSku; tier = 'Fabric' } } | ConvertTo-Json -Depth 4
    $resp = Invoke-AzRestMethod -Method PATCH -Path "$ResourceId`?api-version=$ApiVersion" -Payload $payload
    if ($resp.StatusCode -ge 300) { throw "Resize -> $TargetSku failed: HTTP $($resp.StatusCode) $($resp.Content)" }
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
        $val = if ($r.Action -eq 'none') { "HOLD - $($r.Reasons)" }
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
    if (-not (Get-AzContext)) {
        Import-Module Az.Accounts -Verbose:$false -ErrorAction SilentlyContinue *> $null
        Connect-AzAccount -Identity -WarningAction SilentlyContinue | Out-Null
    }

    $config    = Get-Config
    $subId     = [string](Get-Prop $config.azure 'subscriptionId' '')
    $apiVer    = [string](Get-Prop $config.azure 'apiVersion' '2023-11-01')
    $cool      = [int](Get-Prop $config.evaluation 'cooldownMinutes' 60)
    $lookback  = [int](Get-Prop $config.evaluation 'lookbackHours' 8)
    $notif     = Get-Prop $config 'notifications'
    $webhook   = [string](Get-Prop $notif 'webhookUrl' '')
    $notifyDry = [bool](Get-Prop $notif 'notifyOnDryRun' $true)
    $notifyNon = [bool](Get-Prop $notif 'notifyOnNoAction' $false)
    $nowUtc    = [DateTime]::UtcNow
    $capIndex  = $null   # lazily built ARM name->id map (only when a real resize is needed)

    $allRows = Get-MetricSnapshots -Endpoint $SqlEndpoint -Database $LakehouseName -Lookback $lookback
    if ($allRows.Count -eq 0) { Write-Warning "No snapshots in the last $lookback h - is the notebook running?"; return }

    $report = New-Object System.Collections.Generic.List[object]
    foreach ($grp in ($allRows | Group-Object capacity_name)) {
        $capName  = $grp.Name
        $snaps    = @($grp.Group)
        $capCfg   = Merge-CapConfig -Config $config -CapName $capName -DefaultMinSku $MinSku -DefaultMaxSku $MaxSku
        $decision = Get-CapacityDecision -Snapshots $snaps -Config $config -CapConfig $capCfg

        $m = $snaps[0]
        $entry = [pscustomobject]@{
            Capacity = $capName; CurrentSku = $decision.CurrentSku; Action = $decision.Action
            TargetSku = $decision.TargetSku; Outcome = 'none'; Reasons = ($decision.Reasons -join '; ')
            Util  = "$(Fmt1 $m.util_pct_1h)/$(Fmt1 $m.util_pct_24h)/$(Fmt1 $m.util_pct_7d)"
            Thr   = "$(Fmt1 $m.throttling_s_1h)/$(Fmt1 $m.throttling_s_24h)"
            Rej   = "$([int]$m.rejected_ops_1h)/$([int]$m.rejected_ops_24h)"
            P95   = "$(Fmt1 $m.p95_int_delay_1h)/$(Fmt1 $m.p95_int_reject_1h)/$(Fmt1 $m.p95_bg_reject_1h)"
            Risk  = "$($m.risk_1h)"
            Snaps = $snaps.Count
        }
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
        # Resolve the ARM resource id: config override (sub + RG) else auto-discover by name.
        if ($subId -and $capCfg.resourceGroup) {
            $resourceId = "/subscriptions/$subId/resourceGroups/$($capCfg.resourceGroup)/providers/Microsoft.Fabric/capacities/$capName"
        } else {
            if ($null -eq $capIndex) { $capIndex = Get-FabricCapacityIndex -ApiVersion $apiVer }
            $resourceId = $capIndex[$capName.ToLower()]
        }
        if ([string]::IsNullOrWhiteSpace($resourceId)) {
            Write-Warning "    -> couldn't resolve ARM id for $capName. Give the identity Reader on the subscription, or set azure.subscriptionId + the capacity's resourceGroup in the embedded config."
            $entry.Outcome = 'error'; $entry.Reasons = 'ARM resource id not found'; $report.Add($entry); continue
        }
        try {
            $code = Invoke-CapacityResize -ResourceId $resourceId -TargetSku $decision.TargetSku -ApiVersion $apiVer
            Write-Output "    -> RESIZED to $($decision.TargetSku) (HTTP $code)"; $entry.Outcome = 'resized'
        } catch { Write-Warning "    -> RESIZE FAILED: $_"; $entry.Outcome = 'error'; $entry.Reasons = "$_" }
        $report.Add($entry)
    }

    # ---- Table summary + reasons (hand-rendered, pipe-separated for readability) ----
    $cols = @(
        @{ H = 'Capacity';         W = 26; Get = { param($e) if ($e.Capacity.Length -gt 26) { $e.Capacity.Substring(0, 25) + '~' } else { $e.Capacity } } }
        @{ H = 'SKU';              W = 5;  Get = { param($e) "$($e.CurrentSku)" } }
        @{ H = 'Decision';         W = 26; Get = { param($e) if ($e.Action -eq 'none') { 'HOLD' } else { "$($e.Action.ToUpper()) -> $($e.TargetSku) [$($e.Outcome)]" } } }
        @{ H = 'Util% 1h/24h/7d';  W = 16; Get = { param($e) $e.Util } }
        @{ H = 'Thr(s) 1h/24h';    W = 13; Get = { param($e) $e.Thr } }
        @{ H = 'Rej 1h/24h';       W = 10; Get = { param($e) $e.Rej } }
        @{ H = 'P95 d/r/b';        W = 16; Get = { param($e) $e.P95 } }
        @{ H = 'Risk';             W = 8;  Get = { param($e) $e.Risk } }
        @{ H = 'Sn';               W = 3;  Get = { param($e) "$($e.Snaps)" } }
    )
    $pad = { param($s, $w) $s = "$s"; if ($s.Length -gt $w) { $s.Substring(0, $w) } else { $s.PadRight($w) } }
    Write-Output ''
    Write-Output (($cols | ForEach-Object { & $pad $_.H $_.W }) -join ' | ')
    Write-Output (($cols | ForEach-Object { '-' * $_.W }) -join '-+-')
    foreach ($e in $report) {
        Write-Output (($cols | ForEach-Object { & $pad (& $_.Get $e) $_.W }) -join ' | ')
    }
    Write-Output "`nReasons (the metric(s) behind each decision):"
    foreach ($r in $report) { Write-Output ("  - [$($r.Capacity)] $($r.Reasons)") }

    $ev = $config.evaluation
    Write-Output "`nHow to read this (policy from config):"
    Write-Output ("  UP    when there is throttling now (Thr(s) > 0, Rej > 0, or any P95 >= 100%), OR Util% 1h stays above $($ev.scaleUpUtilizationPct)% for $($ev.consecutiveSignalsRequired) snapshots in a row.")
    Write-Output ("        -> jumps to the smallest SKU that brings projected Util% under $($ev.targetHeadroomPct)%.")
    Write-Output ("  DOWN  when Util% 24h AND 7d both stay below $($ev.scaleDownPeakUtilizationPct)% for $($ev.scaleDownConsecutiveSignalsRequired) snapshots with zero throttling; steps down one SKU, never below the floor.")
    Write-Output  "  HOLD  none of the above: inside the healthy band, not enough consistent history yet, or a non-F/trial SKU."
    Write-Output  "  Columns: Util% = avg utilization vs base compute (1h/24h/7d)."
    Write-Output  "           Thr(s) = seconds throttled; Rej = operations rejected (1h/24h) - any nonzero means users/jobs are being hit now."
    Write-Output  "           P95 d/r/b = throttling-RISK %: interactive Delay / interactive Rejection / Background rejection (100% = throttling starts)."
    Write-Output  "           Risk = Metrics-app health; Sn = hourly snapshots of history available (UP needs $($ev.consecutiveSignalsRequired), DOWN needs $($ev.scaleDownConsecutiveSignalsRequired))."
    Write-Output ''

    Send-CapacityNotification -Report $report.ToArray() -WebhookUrl $webhook -NotifyOnDryRun $notifyDry -NotifyOnNoAction $notifyNon -IsDryRun $DryRun -Now $nowUtc
    Write-Output "=== Done ==="
}

# Run main unless the file is being dot-sourced (e.g. by the Pester tests).
if ($MyInvocation.InvocationName -ne '.') { Start-Autoscale }
