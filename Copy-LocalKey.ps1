. (Join-Path $PSScriptRoot 'Common.ps1')
$cfg = Read-BridgeConfig
Set-Clipboard -Value $cfg.localApiKey
Write-Host 'Local bridge key copied to the clipboard. Paste it into the two OpenTypeless provider key fields, then clear the clipboard. No Azure credential was copied.'
