param([switch]$DisableAutoStart)
. (Join-Path $PSScriptRoot 'Guardian.Common.ps1')
$cfg = Read-GuardianConfig
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'guardian.paused'), (Get-Date).ToUniversalTime().ToString('o'))
$task = Get-VerifiedGuardianTask $cfg
if ($task) { Disable-ScheduledTask -TaskName $cfg.taskName -TaskPath '\' | Out-Null }
$control = Start-Process -FilePath (Join-Path $PSScriptRoot 'BridgeGuardian.exe') -ArgumentList '--stop' -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -PassThru -Wait
if ($control.ExitCode -ne 0) { throw 'Guardian stop failed its ownership check. No unknown process was terminated.' }
for ($attempt=0; $attempt -lt 32 -and @(Get-LiveGuardian).Count -gt 0; $attempt++) { Start-Sleep -Milliseconds 250 }
if ($task) { Stop-ScheduledTask -TaskName $cfg.taskName -TaskPath '\' -ErrorAction SilentlyContinue }
foreach ($process in @(Get-LiveGuardian)) {
    $current = Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
    if ($current -and $current.Path -eq (Join-Path $PSScriptRoot 'BridgeGuardian.exe') -and [Math]::Abs(($current.StartTime.ToUniversalTime() - $process.CreationDate.ToUniversalTime()).TotalMilliseconds) -lt 1) {
        Stop-Process -Id $current.Id
    }
}
Write-Host 'Bridge stopped and recovery paused persistently. Run Start-Bridge.ps1 to resume.'
