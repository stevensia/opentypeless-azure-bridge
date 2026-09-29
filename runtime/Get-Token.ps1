param([string]$ConfigPath)
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'bridge-config.json' }
. (Join-Path $PSScriptRoot 'Common.ps1')
$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
# stdout is captured only by the Node bridge. Never invoke this script with a transcript logger.
$result = Invoke-BridgeAz $cfg @('account','get-access-token','--tenant',$cfg.tenantId,'--resource',$cfg.tokenResource,'--output','json','--only-show-errors')
$token = ($result -join "`n") | ConvertFrom-Json
if (-not $token.accessToken -or -not $token.expires_on) { throw 'Azure token unavailable.' }
$token | Select-Object accessToken,expires_on | ConvertTo-Json -Compress
