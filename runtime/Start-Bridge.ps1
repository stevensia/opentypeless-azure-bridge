. (Join-Path $PSScriptRoot 'Guardian.Common.ps1')
$cfg = Read-GuardianConfig
$task = Get-VerifiedGuardianTask $cfg
if (-not $task) { throw 'Guardian task is missing. Run Upgrade-Guardian.ps1 from the setup package.' }
$pause = Join-Path $PSScriptRoot 'guardian.paused'
if (Test-Path -LiteralPath $pause) { Remove-Item -LiteralPath $pause }
if ($cfg.autoStart) {
    Enable-ScheduledTask -TaskName $cfg.taskName -TaskPath '\' | Out-Null
    Start-ScheduledTask -TaskName $cfg.taskName -TaskPath '\'
} else {
    Disable-ScheduledTask -TaskName $cfg.taskName -TaskPath '\' | Out-Null
    Start-Process -FilePath (Join-Path $PSScriptRoot 'BridgeGuardian.exe') -ArgumentList '--run' -WorkingDirectory $PSScriptRoot -WindowStyle Hidden
}
for ($attempt=0; $attempt -lt 40; $attempt++) {
    $health = Get-LocalBridgeHealth $cfg.port
    if ($health -and $health.service -eq 'OpenTypeless Foundry Bridge' -and @(Get-LiveGuardian).Count -eq 1) {
        Write-Host 'Guardian and bridge are running. Automatic recovery follows the installed task settings.'
        return
    }
    Start-Sleep -Milliseconds 500
}
throw 'Guardian start did not become healthy within 20 seconds. Run Get-BridgeStatus.ps1 and inspect guardian.log.'
