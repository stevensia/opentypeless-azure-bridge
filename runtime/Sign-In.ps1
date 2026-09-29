param([switch]$DeviceCode, [string]$ClientId, [string]$CertificatePath)
. (Join-Path $PSScriptRoot 'Common.ps1')
$cfg = Read-BridgeConfig
Set-PrivateDirectory $cfg.azureConfigDir
# Only this package's private CLI directory is changed; the normal Azure CLI cloud is preserved.
Invoke-BridgeAz $cfg @('cloud','set','--name',$cfg.cloud,'--only-show-errors')
Invoke-BridgeAz $cfg @('config','set','core.enable_broker_on_windows=false','--only-show-errors')
if ($ClientId -or $CertificatePath) {
    if (-not $ClientId -or -not $CertificatePath -or -not (Test-Path -LiteralPath $CertificatePath)) {
        throw 'Certificate sign-in requires both ClientId and an existing PEM containing the certificate and private key.'
    }
    $cert = (Resolve-Path -LiteralPath $CertificatePath).Path
    Invoke-BridgeAz $cfg @('login','--service-principal','--username',$ClientId,'--certificate',$cert,'--tenant',$cfg.tenantId,'--allow-no-subscriptions','--output','none','--only-show-errors')
} else {
    $arguments = @('login','--tenant',$cfg.tenantId,'--scope',($cfg.tokenResource.TrimEnd('/')+'/.default'),'--allow-no-subscriptions','--output','none','--only-show-errors')
    if ($DeviceCode) { $arguments += '--use-device-code' }
    Invoke-BridgeAz $cfg $arguments
}
Write-Host 'Azure sign-in completed in the isolated bridge profile.'
