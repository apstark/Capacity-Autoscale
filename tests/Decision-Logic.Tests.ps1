<#
    Pester v5 tests for runbook/Decision-Logic.ps1

    Run:
        Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser   # if needed
        Invoke-Pester -Path .\tests\Decision-Logic.Tests.ps1

    These lock in the documentation-grounded thresholds so future tuning of
    config/autoscale-config.json can't silently break the up/down math.
#>

BeforeAll {
    # Dot-source the runbook; its guard skips Start-Autoscale when dot-sourced,
    # so this just imports the decision functions for testing.
    . "$PSScriptRoot\..\runbook\Invoke-CapacityAutoscale.ps1"

    $script:ConfigJson = Get-Content -Raw "$PSScriptRoot\..\config\autoscale-config.json"
    function Get-FreshConfig { $script:ConfigJson | ConvertFrom-Json }
    $script:Config = Get-FreshConfig
    $script:CapCfg = [pscustomobject]@{
        enabled = $true; minSku = 'F8'; maxSku = 'F256'; reservedFloorSku = $null; resourceGroup = 'rg'
    }

    function New-Snap {
        param(
            [string]$Sku = 'F64', [string]$State = 'Active',
            [double]$U1 = 15, [double]$U24 = 15, [double]$U7 = 15,
            [double]$Thr1 = 0, [double]$Thr24 = 0,
            [double]$D1 = 10, [double]$R1 = 10, [double]$B1 = 8,
            [int]$Rej1 = 0, [int]$Rej24 = 0,
            [string]$Risk1 = 'Healthy', [string]$Risk24 = 'Healthy',
            [string]$Name = 'capA'
        )
        [pscustomobject]@{
            capacity_name = $Name; sku = $Sku; state = $State
            util_pct_1h = $U1; util_pct_24h = $U24; util_pct_7d = $U7
            throttling_s_1h = $Thr1; throttling_s_24h = $Thr24
            p95_int_delay_1h = $D1; p95_int_reject_1h = $R1; p95_bg_reject_1h = $B1
            rejected_ops_1h = $Rej1; rejected_ops_24h = $Rej24
            risk_1h = $Risk1; risk_24h = $Risk24
        }
    }
    # Build N identical snapshots (newest-first order doesn't matter when identical).
    function Repeat-Snap { param([int]$N, [hashtable]$Params = @{}) 1..$N | ForEach-Object { New-Snap @Params } }
}

Describe 'SKU helpers' {
    It 'Get-SkuCU parses the F-number' {
        Get-SkuCU 'F64'  | Should -Be 64
        Get-SkuCU 'F2'   | Should -Be 2
        Get-SkuCU 'F2048'| Should -Be 2048
    }
    It 'Get-SkuCU rejects a bad SKU' {
        { Get-SkuCU 'X9' } | Should -Throw
    }
    It 'Get-NextSkuDown steps down, and stops at the floor of the ladder' {
        Get-NextSkuDown -Sku 'F64' -Ladder $Config.skuLadder | Should -Be 'F32'
        Get-NextSkuDown -Sku 'F2'  -Ladder $Config.skuLadder | Should -BeNullOrEmpty
    }
    It 'Resolve-TargetScaleUpSku jumps enough to get under headroom' {
        # 95% on F64 -> F128 gives 95*64/128 = 47.5% (< 80% headroom)
        Resolve-TargetScaleUpSku -CurrentSku 'F64' -CurrentUtilPct 95 -Ladder $Config.skuLadder -MaxSku 'F256' -HeadroomPct 80 |
            Should -Be 'F128'
    }
    It 'Resolve-TargetScaleUpSku caps at MaxSku when nothing fully fits' {
        Resolve-TargetScaleUpSku -CurrentSku 'F64' -CurrentUtilPct 400 -Ladder $Config.skuLadder -MaxSku 'F128' -HeadroomPct 80 |
            Should -Be 'F128'
    }
}

Describe 'Get-CapacityDecision - scale UP' {
    It 'scales up immediately on active throttling (even one snapshot)' {
        $snaps = @(New-Snap -Sku 'F64' -U1 95 -Thr1 120 -Rej1 5 -D1 140 -Risk1 'At risk')
        $d = Get-CapacityDecision -Snapshots $snaps -Config $Config -CapConfig $CapCfg
        $d.Action | Should -Be 'up'
        $d.TargetSku | Should -Be 'F128'
    }
    It 'scales up on sustained >80% with no throttling' {
        $snaps = Repeat-Snap -N 3 -Params @{ Sku = 'F64'; U1 = 90 }
        $d = Get-CapacityDecision -Snapshots $snaps -Config $Config -CapConfig $CapCfg
        $d.Action | Should -Be 'up'
    }
    It 'does NOT scale up on a single hot snapshot (hysteresis)' {
        $snaps = @(New-Snap -Sku 'F64' -U1 90)   # 1 snap, requires 3
        $d = Get-CapacityDecision -Snapshots $snaps -Config $Config -CapConfig $CapCfg
        $d.Action | Should -Be 'none'
    }
    It 'reports no action when already at maxSku' {
        $cap = [pscustomobject]@{ enabled = $true; minSku = 'F8'; maxSku = 'F64'; reservedFloorSku = $null; resourceGroup = 'rg' }
        $snaps = @(New-Snap -Sku 'F64' -U1 99 -Thr1 300)
        $d = Get-CapacityDecision -Snapshots $snaps -Config $Config -CapConfig $cap
        $d.Action | Should -Be 'none'
        ($d.Reasons -join ' ') | Should -Match 'maxSku'
    }
}

Describe 'Get-CapacityDecision - scale DOWN' {
    It 'scales down one step on sustained idle (real F64 ~21% case)' {
        $snaps = Repeat-Snap -N 6 -Params @{ Sku = 'F64'; U1 = 21; U24 = 21; U7 = 19.5 }
        $d = Get-CapacityDecision -Snapshots $snaps -Config $Config -CapConfig $CapCfg
        $d.Action | Should -Be 'down'
        $d.TargetSku | Should -Be 'F32'
    }
    It 'is blocked by the reserved floor' {
        $cap = [pscustomobject]@{ enabled = $true; minSku = 'F8'; maxSku = 'F256'; reservedFloorSku = 'F64'; resourceGroup = 'rg' }
        $snaps = Repeat-Snap -N 6 -Params @{ Sku = 'F64'; U1 = 21; U24 = 21; U7 = 19.5 }
        $d = Get-CapacityDecision -Snapshots $snaps -Config $Config -CapConfig $cap
        $d.Action | Should -Be 'none'
        ($d.Reasons -join ' ') | Should -Match 'floor'
    }
    It 'does NOT scale down without enough sustained snapshots' {
        $snaps = Repeat-Snap -N 3 -Params @{ Sku = 'F64'; U24 = 21; U7 = 19.5 }  # needs 6
        $d = Get-CapacityDecision -Snapshots $snaps -Config $Config -CapConfig $CapCfg
        $d.Action | Should -Be 'none'
    }
    It 'is blocked by the projected-fit check' {
        $cfg = Get-FreshConfig
        $cfg.evaluation.scaleDownPeakUtilizationPct = 50   # allow "cold" at 45%
        $snaps = Repeat-Snap -N 6 -Params @{ Sku = 'F64'; U1 = 45; U24 = 45; U7 = 45 }
        $d = Get-CapacityDecision -Snapshots $snaps -Config $cfg -CapConfig $CapCfg
        # 45% on F64 -> 90% on F32 exceeds 80% headroom, so down is refused.
        $d.Action | Should -Be 'none'
        ($d.Reasons -join ' ') | Should -Match 'headroom'
    }
}

Describe 'Get-CapacityDecision - guards' {
    It 'takes no action when the capacity is disabled' {
        $cap = [pscustomobject]@{ enabled = $false; minSku = 'F8'; maxSku = 'F256'; reservedFloorSku = $null; resourceGroup = 'rg' }
        $d = Get-CapacityDecision -Snapshots @(New-Snap -U1 99 -Thr1 500) -Config $Config -CapConfig $cap
        $d.Action | Should -Be 'none'
        ($d.Reasons -join ' ') | Should -Match 'disabled'
    }
    It 'takes no action when the capacity is not Active' {
        $d = Get-CapacityDecision -Snapshots @(New-Snap -State 'Paused' -U1 99 -Thr1 500) -Config $Config -CapConfig $CapCfg
        $d.Action | Should -Be 'none'
    }
    It 'takes no action within the healthy band' {
        $snaps = Repeat-Snap -N 6 -Params @{ Sku = 'F64'; U1 = 50; U24 = 50; U7 = 50 }
        $d = Get-CapacityDecision -Snapshots $snaps -Config $Config -CapConfig $CapCfg
        $d.Action | Should -Be 'none'
    }
}
