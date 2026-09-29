. (Join-Path $PSScriptRoot 'Guardian.Common.ps1')
$cfg = Read-GuardianConfig
$task = Get-VerifiedGuardianTask $cfg
$state = $null
$file = Join-Path $PSScriptRoot 'guardian-state.json'
if (Test-Path -LiteralPath $file) { try { $state = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json } catch {} }
$health = Get-LocalBridgeHealth $cfg.port
$guardians = @(Get-LiveGuardian)
[ordered]@{
    paused=(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'guardian.paused'));
    autoStartConfigured=[bool]$cfg.autoStart;
    taskName=$cfg.taskName; taskState=if($task){[string]$task.State}else{'Missing'};
    taskEnabled=if($task){[bool]$task.Settings.Enabled}else{$false};
    guardianCount=$guardians.Count; guardianPids=@($guardians | ForEach-Object {$_.ProcessId});
    bridgeHealthy=[bool]($health -and $health.service -eq 'OpenTypeless Foundry Bridge');
    bridgeVersion=if($health){$health.version}else{$null};
    lastObservedState=$state;
    note='Local liveness only. Azure login and inference errors require separate checks; no paid inference was performed.'
} | ConvertTo-Json -Depth 10
