. (Join-Path $PSScriptRoot 'Guardian.Common.ps1')
$cfg = Read-GuardianConfig
$existing = Get-VerifiedGuardianTask $cfg
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$action = New-ScheduledTaskAction -Execute (Join-Path $PSScriptRoot 'BridgeGuardian.exe') -Argument '--run' -WorkingDirectory $PSScriptRoot
$logon = New-ScheduledTaskTrigger -AtLogOn -User $sid
$fallback = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(15) -RepetitionInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$settings.Enabled = $false
$task = New-ScheduledTask -Action $action -Trigger @($logon,$fallback) -Principal $principal -Settings $settings -Description 'OpenTypeless local Azure bridge watchdog. Runs as the signed-in user; Stop-Bridge pauses recovery until Start-Bridge resumes it.'
Register-ScheduledTask -TaskName $cfg.taskName -TaskPath '\' -InputObject $task -Force | Out-Null
$verified = Get-VerifiedGuardianTask $cfg
if (-not $verified -or $verified.Principal.LogonType -ne 'Interactive' -or $verified.Settings.ExecutionTimeLimit -ne 'PT0S') { throw 'Registered task did not match the intended settings.' }
Write-Host ('Guardian task registered (paused until Start): ' + $cfg.taskName)
