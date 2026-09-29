param([Parameter(Mandatory=$true)][string]$BackupDirectory)
$ErrorActionPreference = 'Stop'
$saved = Get-Content -LiteralPath (Join-Path $BackupDirectory 'restore.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$runtime = [IO.Path]::GetFullPath($saved.installDir).TrimEnd('\')
$backupFull = [IO.Path]::GetFullPath($BackupDirectory)
if (-not $backupFull.StartsWith(($runtime+'\backups\guardian-'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Backup location does not belong to the recorded bridge.' }
if (Test-Path -LiteralPath (Join-Path $runtime 'guardian-config.json')) { & (Join-Path $runtime 'Stop-Bridge.ps1') }
$task = Get-ScheduledTask -TaskName $saved.taskName -TaskPath '\' -ErrorAction SilentlyContinue
if ($task) {
    if (@($task.Actions).Count -ne 1 -or $task.Actions[0].Execute -ne (Join-Path $runtime 'BridgeGuardian.exe')) { throw 'Task action changed; rollback stopped.' }
    Unregister-ScheduledTask -TaskName $saved.taskName -TaskPath '\' -Confirm:$false
}
foreach ($name in $saved.managed) {
    if ($name -ne [IO.Path]::GetFileName($name)) { throw 'Invalid backup filename.' }
    $target = Join-Path $runtime $name
    if ($name -in $saved.existed) { Copy-Item -LiteralPath (Join-Path $BackupDirectory $name) -Destination $target -Force }
    elseif (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target }
}
$pause = Join-Path $runtime 'guardian.paused'
if ($saved.previouslyPaused) { [IO.File]::WriteAllText($pause,'restored-pause') }
elseif (Test-Path -LiteralPath $pause) { Remove-Item -LiteralPath $pause }
if ($saved.previousTaskXml) { Register-ScheduledTask -TaskName $saved.taskName -TaskPath '\' -Xml $saved.previousTaskXml -Force | Out-Null }
$runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName = 'OpenTypelessFoundryBridge'
if ($saved.previousRun) { New-ItemProperty -Path $runPath -Name $runName -PropertyType String -Value $saved.previousRun -Force | Out-Null }
$restoreRunning = -not $saved.PSObject.Properties['previouslyRunning'] -or $saved.previouslyRunning
if ($restoreRunning -and -not $saved.previouslyPaused -and (Test-Path -LiteralPath (Join-Path $runtime 'Start-Bridge.ps1'))) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $runtime 'Start-Bridge.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Startup files restored, but the previous bridge failed to start.' }
}
Write-Host 'Guardian startup changes rolled back. Model config, credentials, and OpenTypeless settings were not changed.'
