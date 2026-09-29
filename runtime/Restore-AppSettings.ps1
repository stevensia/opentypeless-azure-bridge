param([Parameter(Mandatory=$true)][string]$BackupDirectory)
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-AppClosed
$cfg = Read-BridgeConfig
& $cfg.nodePath (Join-Path $PSScriptRoot 'app-settings.mjs') restore $cfg.settingsPath (Join-Path $PSScriptRoot 'bridge-config.json') $BackupDirectory
if ($LASTEXITCODE -ne 0) { throw 'Settings restore failed. No further changes were made.' }
Write-Host 'Only setup-managed fields were restored. Re-enter old provider API keys if needed; OS vault secrets were not exported.'
