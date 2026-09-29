param([switch]$Live)
. (Join-Path $PSScriptRoot 'Common.ps1')
$cfg = Read-BridgeConfig
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'guardian-config.json')) {
    & (Join-Path $PSScriptRoot 'Get-BridgeStatus.ps1')
}
$extra = @()
if ($Live) { $extra += '--live' }
& $cfg.nodePath (Join-Path $PSScriptRoot 'test-bridge.mjs') (Join-Path $PSScriptRoot 'bridge-config.json') @extra
$bridgeResult = $LASTEXITCODE
& $cfg.nodePath (Join-Path $PSScriptRoot 'app-settings.mjs') check $cfg.settingsPath (Join-Path $PSScriptRoot 'bridge-config.json')
$appResult = $LASTEXITCODE
if ($bridgeResult -ne 0 -or $appResult -ne 0) { exit 1 }
Write-Host 'Local checks passed. App credential-vault use and real microphone quality still require tests inside OpenTypeless.'
