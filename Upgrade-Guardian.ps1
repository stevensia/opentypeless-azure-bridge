[CmdletBinding()]
param([string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'OpenTypeless\foundry-bridge'), [switch]$NoAutoStart)
$ErrorActionPreference = 'Stop'
$InstallDir = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
$allowed = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'OpenTypeless')).TrimEnd('\') + '\'
if (-not $InstallDir.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $InstallDir -Leaf) -ne 'foundry-bridge') { throw 'Expected a dedicated foundry-bridge directory under LOCALAPPDATA\OpenTypeless.' }
$bridgeConfig = Join-Path $InstallDir 'bridge-config.json'
if (-not (Test-Path -LiteralPath $bridgeConfig) -or -not (Test-Path -LiteralPath (Join-Path $InstallDir 'foundry-bridge.mjs'))) { throw 'Existing bridge required. Use Setup.ps1 for a fresh machine.' }
$cfg = Get-Content -LiteralPath $bridgeConfig -Raw -Encoding UTF8 | ConvertFrom-Json
$node = if($cfg.PSObject.Properties['nodePath']){$cfg.nodePath}else{(Get-Command node.exe -ErrorAction Stop).Source}
$hash = [Security.Cryptography.SHA256]::Create()
try { $suffix = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($InstallDir.ToLowerInvariant())))).Replace('-','').Substring(0,12).ToLowerInvariant() } finally { $hash.Dispose() }
$taskName = 'OpenTypeless-BridgeGuardian-' + $suffix
$runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName = 'OpenTypelessFoundryBridge'
$oldRun = Get-ItemProperty -LiteralPath $runPath -Name $runName -ErrorAction SilentlyContinue
$oldTask = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
$priorWorkers = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object {
    $_.ExecutablePath -eq $node -and $_.CommandLine -match ([regex]::Escape('"'+(Join-Path $InstallDir 'foundry-bridge.mjs')+'"')+'\s*$')
})
if ($oldTask -and (@($oldTask.Actions).Count -ne 1 -or $oldTask.Actions[0].Execute -ne (Join-Path $InstallDir 'BridgeGuardian.exe') -or $oldTask.Actions[0].Arguments -ne '--run')) { throw 'Conflicting scheduled task; no changes made.' }
$managed = @('BridgeGuardian.cs','BridgeGuardian.exe','Build-Guardian.ps1','Guardian.Common.ps1','Register-Guardian.ps1','Start-Bridge.ps1','Stop-Bridge.ps1','Get-BridgeStatus.ps1','guardian-config.json')
$backup = Join-Path $InstallDir ('backups\guardian-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
Copy-Item -LiteralPath $bridgeConfig -Destination (Join-Path $backup 'bridge-config.unchanged.json')
Copy-Item -LiteralPath (Join-Path $InstallDir 'foundry-bridge.mjs') -Destination (Join-Path $backup 'foundry-bridge.unchanged.mjs')
$before = @()
foreach ($name in $managed) { if (Test-Path -LiteralPath (Join-Path $InstallDir $name)) { Copy-Item -LiteralPath (Join-Path $InstallDir $name) -Destination $backup; $before += $name } }
$record = [ordered]@{
    installDir=$InstallDir; taskName=$taskName; managed=$managed; existed=$before;
    previousRun=if($oldRun -and $oldRun.$runName.IndexOf($InstallDir,[StringComparison]::OrdinalIgnoreCase) -ge 0){$oldRun.$runName}else{$null};
    previousTaskXml=if($oldTask){Export-ScheduledTask -TaskName $taskName -TaskPath '\'}else{$null};
    previouslyPaused=(Test-Path -LiteralPath (Join-Path $InstallDir 'guardian.paused'));
    previouslyRunning=($priorWorkers.Count -gt 0);
    bridgeConfigSha256=(Get-FileHash -LiteralPath $bridgeConfig).Hash;
    bridgeCodeSha256=(Get-FileHash -LiteralPath (Join-Path $InstallDir 'foundry-bridge.mjs')).Hash
}
[IO.File]::WriteAllText((Join-Path $backup 'restore.json'),($record|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
Write-Host ('Guardian rollback backup: ' + $backup)
try {
    if (Test-Path -LiteralPath (Join-Path $InstallDir 'guardian-config.json')) { & (Join-Path $InstallDir 'Stop-Bridge.ps1') }
    [IO.File]::WriteAllText((Join-Path $InstallDir 'guardian.paused'), 'installing')
    foreach ($name in $managed) { if ($name -notin @('BridgeGuardian.exe','guardian-config.json')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('runtime\'+$name)) -Destination (Join-Path $InstallDir $name) -Force } }
    & (Join-Path $InstallDir 'Build-Guardian.ps1')
    . (Join-Path $InstallDir 'Guardian.Common.ps1')
    Write-GuardianJson (Join-Path $InstallDir 'guardian-config.json') ([ordered]@{
        schemaVersion=1; nodePath=$node; bridgePath=(Join-Path $InstallDir 'foundry-bridge.mjs'); port=[int]$cfg.port;
        taskName=$taskName; autoStart=(-not $NoAutoStart); pollSeconds=10; healthTimeoutSeconds=2;
        failureThreshold=3; healthyResetSeconds=60; restartDelaySeconds=@(5,15,60)
    })
    & (Join-Path $InstallDir 'Register-Guardian.ps1')
    if ($oldRun -and $oldRun.$runName.IndexOf($InstallDir,[StringComparison]::OrdinalIgnoreCase) -ge 0) { Remove-ItemProperty -LiteralPath $runPath -Name $runName }
    & (Join-Path $InstallDir 'Start-Bridge.ps1')
    if ((Get-FileHash -LiteralPath $bridgeConfig).Hash -ne $record.bridgeConfigSha256 -or (Get-FileHash -LiteralPath (Join-Path $InstallDir 'foundry-bridge.mjs')).Hash -ne $record.bridgeCodeSha256) { throw 'Unexpected bridge config or code change.' }
    & (Join-Path $InstallDir 'Get-BridgeStatus.ps1')
} catch {
    Write-Warning ('Guardian installation failed; restoring its startup changes. Reason: '+$_.Exception.Message)
    & (Join-Path $PSScriptRoot 'Rollback-Guardian.ps1') -BackupDirectory $backup
    throw 'Guardian install failed and rollback was attempted. Inspect the rollback result above.'
}
