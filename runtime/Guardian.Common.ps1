$ErrorActionPreference = 'Stop'
$script:GuardianRoot = $PSScriptRoot
function Read-GuardianConfig {
    Get-Content -LiteralPath (Join-Path $script:GuardianRoot 'guardian-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Write-GuardianJson {
    param([string]$Path, $Value)
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
}
function Get-VerifiedGuardianTask {
    param($Config)
    $task = Get-ScheduledTask -TaskName $Config.taskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($task) {
        $expected = Join-Path $script:GuardianRoot 'BridgeGuardian.exe'
        if (@($task.Actions).Count -ne 1 -or $task.Actions[0].Execute -ne $expected -or $task.Actions[0].Arguments -ne '--run') {
            throw 'Task name belongs to a different action. No task was changed.'
        }
    }
    return $task
}
function Get-LiveGuardian {
    $expected = Join-Path $script:GuardianRoot 'BridgeGuardian.exe'
    @(Get-CimInstance Win32_Process -Filter "Name='BridgeGuardian.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -eq $expected -and $_.CommandLine -match '\s--run\s*$'
    })
}
function Get-LocalBridgeHealth {
    param([int]$Port)
    try { Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2 } catch { $null }
}
