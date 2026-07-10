<#
.SYNOPSIS
    Fabric capacity autoscaler runbook: read hourly metrics from the Lakehouse SQL
    analytics endpoint, decide per capacity, and resize the base SKU via ARM.

.DESCRIPTION
    Intended to run in Azure Automation on a schedule (e.g. hourly, a few minutes
    after the collection notebook). Uses the Automation account's Managed Identity,
    which must hold on each target Fabric capacity:
        Microsoft.Fabric/capacities/read
        Microsoft.Fabric/capacities/write
    and (for pause/resume, optional) suspend/action, resume/action.

    SAFETY: dry-run by default. It only logs proposed actions unless you pass
    -Execute. Cooldown + hysteresis are enforced from persisted state so it can't
    flap. See docs/scaling-policy.md and README.md.

.PARAMETER Execute
    Actually perform resizes. Omit for a no-op dry run (recommended first).

.PARAMETER ConfigPath
    Optional override. Local path to autoscale-config.json (handy for local
    testing). If omitted, the config EMBEDDED in this runbook is used, so the
    runbook is self-contained - no Automation variable required.

.PARAMETER ConfigVariableName
    Optional override. Name of an Automation variable holding config JSON. Leave
    empty (default) to use the embedded config. Precedence: -ConfigPath > this
    variable > embedded.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$ConfigVariableName = '',
    [string]$StateVariableName  = 'AutoscaleState',
    [Parameter(Mandatory)][string]$SqlEndpoint,     # Lakehouse SQL analytics endpoint (server)
    [Parameter(Mandatory)][string]$LakehouseName,   # database name on that endpoint
    [int]$LookbackHours = 8,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Decision-Logic.ps1"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

# ---------------------------------------------------------------------------
# EMBEDDED CONFIG  (self-contained default; source of truth for the runbook)
# Mirror of config/autoscale-config.json - keep the two in sync. Edit the values
# below for your environment (subscriptionId, each capacity's resourceGroup, and
# reservedFloorSku if the capacity is on an Azure reservation).
# ---------------------------------------------------------------------------
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
  "skuLadder": ["F2","F4","F8","F16","F32","F64","F128","F256","F512","F1024","F2048"],
  "boundaries": { "slowResizePairs": [["F32","F64"]], "slowAtOrAbove": "F512" },
  "azure": { "subscriptionId": "<SET_ME>", "apiVersion": "2023-11-01" },
  "defaults": { "enabled": true, "reservedFloorSku": null, "minSku": "F2", "maxSku": "F2048" },
  "capacities": {
    "tmcadlfabric": {
      "capacityId": "49B9055E-B898-4EB4-B829-0688D8BB6685",
      "resourceGroup": "<SET_ME>",
      "region": "East US",
      "enabled": true,
      "minSku": "F8",
      "maxSku": "F256",
      "reservedFloorSku": null
    }
  }
}
'@

function Get-Config {
    # Precedence: -ConfigPath (file) > -ConfigVariableName (Automation var) > embedded default.
    if ($ConfigPath) { return (Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json) }
    if (-not [string]::IsNullOrWhiteSpace($ConfigVariableName)) {
        try {
            $raw = Get-AutomationVariable -Name $ConfigVariableName
            if (-not [string]::IsNullOrWhiteSpace($raw)) { return ($raw | ConvertFrom-Json) }
        } catch { Write-Warning "Config variable '$ConfigVariableName' not usable; using embedded config. $_" }
    }
    return ($EmbeddedConfigJson | ConvertFrom-Json)
}

function Get-State {
    try {
        $raw = Get-AutomationVariable -Name $StateVariableName
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    } catch {
        Write-Warning "No persisted state ($StateVariableName); starting empty. $_"
        return @{}
    }
}

function Set-State {
    param([hashtable]$State)
    $json = $State | ConvertTo-Json -Depth 6
    try { Set-AutomationVariable -Name $StateVariableName -Value $json }
    catch { Write-Warning "Could not persist state: $_" }
}

function Get-SqlAccessToken {
    $t = Get-AzAccessToken -ResourceUrl 'https://database.windows.net/'
    if ($t.Token -is [System.Security.SecureString]) {
        return (New-Object System.Net.NetworkCredential('', $t.Token)).Password
    }
    return $t.Token
}

function Get-MetricSnapshots {
    param([string]$Endpoint, [string]$Database, [int]$Lookback)
    $query = @"
SELECT capacity_id, capacity_name, region, sku, state, snapshot_time_utc,
       util_pct_1h, util_pct_24h, util_pct_7d,
       throttling_s_1h, throttling_s_24h,
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
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        [void]$cmd.Parameters.AddWithValue('@LookbackHours', $Lookback)
        $reader = $cmd.ExecuteReader()
        $rows = New-Object System.Collections.Generic.List[object]
        while ($reader.Read()) {
            $o = [ordered]@{}
            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                $val = if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) }
                $o[$reader.GetName($i)] = $val
            }
            $rows.Add([pscustomobject]$o)
        }
        return $rows
    } finally { $conn.Close() }
}

function Merge-CapConfig {
    param($Config, [string]$CapName)
    $d = $Config.defaults
    $c = Get-Prop $Config.capacities $CapName
    return [pscustomobject]@{
        enabled          = [bool](Get-Prop $c 'enabled' (Get-Prop $d 'enabled' $true))
        minSku           = [string](Get-Prop $c 'minSku' (Get-Prop $d 'minSku' 'F2'))
        maxSku           = [string](Get-Prop $c 'maxSku' (Get-Prop $d 'maxSku' 'F2048'))
        reservedFloorSku = Get-Prop $c 'reservedFloorSku' (Get-Prop $d 'reservedFloorSku' $null)
        resourceGroup    = [string](Get-Prop $c 'resourceGroup' '')
    }
}

function Invoke-CapacityResize {
    param([string]$SubscriptionId, [string]$ResourceGroup, [string]$CapacityName,
          [string]$TargetSku, [string]$ApiVersion)
    $path = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Fabric/capacities/$CapacityName`?api-version=$ApiVersion"
    $payload = @{ sku = @{ name = $TargetSku; tier = 'Fabric' } } | ConvertTo-Json -Depth 4
    $resp = Invoke-AzRestMethod -Method PATCH -Path $path -Payload $payload
    if ($resp.StatusCode -ge 300) {
        throw "Resize $CapacityName -> $TargetSku failed: HTTP $($resp.StatusCode) $($resp.Content)"
    }
    return $resp.StatusCode
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Output "=== Fabric Capacity Autoscale run (Execute=$($Execute.IsPresent)) ==="
Connect-AzAccount -Identity | Out-Null

$config = Get-Config
$subId  = Get-Prop $config.azure 'subscriptionId'
$apiVer = Get-Prop $config.azure 'apiVersion' '2023-11-01'
$cool   = [int](Get-Prop $config.evaluation 'cooldownMinutes' 60)
$nowUtc = [DateTime]::UtcNow   # single 'now' for the whole run

$allRows = Get-MetricSnapshots -Endpoint $SqlEndpoint -Database $LakehouseName -Lookback $LookbackHours
if ($allRows.Count -eq 0) { Write-Warning "No snapshots in the last $LookbackHours h - is the notebook running?"; return }

$byCapacity = $allRows | Group-Object capacity_name
$state = Get-State

foreach ($grp in $byCapacity) {
    $capName   = $grp.Name
    $snaps     = @($grp.Group)                       # already newest-first from ORDER BY
    $capCfg    = Merge-CapConfig -Config $config -CapName $capName
    $decision  = Get-CapacityDecision -Snapshots $snaps -Config $config -CapConfig $capCfg

    $line = "[$capName] $($decision.CurrentSku) -> $($decision.Action.ToUpper())"
    if ($decision.Action -ne 'none') { $line += " ($($decision.TargetSku))" }
    $line += " :: " + ($decision.Reasons -join '; ')
    Write-Output $line

    if ($decision.Action -eq 'none') { continue }

    # Cooldown check.
    $capState = if ($state.ContainsKey($capName)) { $state[$capName] } else { $null }
    if ($capState -and (Get-Prop $capState 'lastActionUtc')) {
        $mins = ($nowUtc - [DateTime]::Parse((Get-Prop $capState 'lastActionUtc')).ToUniversalTime()).TotalMinutes
        if ($mins -lt $cool) {
            Write-Output "    -> skipped: cooldown ($([math]::Round($mins,0))/$cool min since last action)"
            continue
        }
    }

    if (-not $Execute) {
        Write-Output "    -> DRY RUN: would resize to $($decision.TargetSku)"
        continue
    }

    if ([string]::IsNullOrWhiteSpace($capCfg.resourceGroup)) {
        Write-Warning "    -> no resourceGroup configured for $capName; skipping resize."
        continue
    }

    $code = Invoke-CapacityResize -SubscriptionId $subId -ResourceGroup $capCfg.resourceGroup `
                -CapacityName $capName -TargetSku $decision.TargetSku -ApiVersion $apiVer
    Write-Output "    -> RESIZED to $($decision.TargetSku) (HTTP $code)"

    $state[$capName] = [pscustomobject]@{
        lastActionUtc = $nowUtc.ToString('o')
        lastAction    = $decision.Action
        fromSku       = $decision.CurrentSku
        toSku         = $decision.TargetSku
        reasons       = ($decision.Reasons -join '; ')
    }
}

if ($Execute) { Set-State -State $state }
Write-Output "=== Done ==="
