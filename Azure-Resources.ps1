[CmdletBinding()]
param(
    [ValidateSet('Plan','Check','Apply')][string]$Mode='Plan',
    [string]$ConfigPath,
    [string]$AzureConfigDir=(Join-Path $env:LOCALAPPDATA 'OpenTypeless\provisioning-auth'),
    [string]$OutputProfile,
    [switch]$SignIn,
    [switch]$DeviceCode
)
$ErrorActionPreference='Stop'
if(-not $ConfigPath){$ConfigPath=Join-Path $PSScriptRoot '.local\azure-resources.local.json'}
if(-not $OutputProfile){$OutputProfile=Join-Path $PSScriptRoot '.local\azure-profile.local.json'}
if(-not (Test-Path -LiteralPath $ConfigPath)){throw 'Copy config/azure-resources.example.json to .local/azure-resources.local.json and fill its placeholders first.'}
$node=(Get-Command node.exe -ErrorAction Stop).Source
$config=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8|ConvertFrom-Json
$planText=& $node (Join-Path $PSScriptRoot 'scripts\azure-plan.mjs') $ConfigPath
if($LASTEXITCODE -ne 0){throw 'Resource configuration is invalid.'}
$plan=($planText -join "`n")|ConvertFrom-Json
if($Mode -eq 'Plan'){
    [ordered]@{mode='Plan';cloud=$config.cloud;location=$config.location;resourceGroup=$config.resourceGroup;resourceName=$config.resourceName;
        models=@($config.speech,$config.polish);inferenceRole=if($plan.roleArgs){'Cognitive Services OpenAI User'}else{'manual'};
        note='Offline plan only. Apply creates missing resources/deployments and may incur Azure charges; it never deletes resources.'}|ConvertTo-Json -Depth 8
    return
}
$az=(Get-Command az.cmd -ErrorAction Stop).Source
. (Join-Path $PSScriptRoot 'runtime\Common.ps1')
$oldDirectory=$env:AZURE_CONFIG_DIR
$scratch=$null
function Invoke-ResourceAz([string[]]$Arguments,[switch]$NoResult){
    $output=if($NoResult){'none'}else{'json'}
    $result=& $az @Arguments --only-show-errors --output $output
    if($LASTEXITCODE -ne 0){throw 'Azure CLI failed. Inspect its error; no missing resource is inferred from a failed query.'}
    if(-not $NoResult){return (($result -join "`n")|ConvertFrom-Json)}
}
try{
    $env:AZURE_CONFIG_DIR=[IO.Path]::GetFullPath($AzureConfigDir)
    if($SignIn){
        Set-PrivateDirectory $env:AZURE_CONFIG_DIR
        Invoke-ResourceAz @('cloud','set','--name','AzureCloud') -NoResult
        Invoke-ResourceAz @('config','set','core.enable_broker_on_windows=false') -NoResult
        $login=@('login','--tenant',$config.tenantId)
        if($DeviceCode){$login+='--use-device-code'}
        Invoke-ResourceAz $login -NoResult
    }
    $subscription=Invoke-ResourceAz @('account','show','--subscription',$config.subscriptionId)
    $cloud=Invoke-ResourceAz @('cloud','show')
    $provider=Invoke-ResourceAz @('provider','show','--namespace','Microsoft.CognitiveServices','--subscription',$config.subscriptionId)
    $catalog=Invoke-ResourceAz @('cognitiveservices','model','list','--location',$config.location,'--subscription',$config.subscriptionId)
    $groupExists=Invoke-ResourceAz @('group','exists','--name',$config.resourceGroup,'--subscription',$config.subscriptionId)
    $account=$null;$deployments=@()
    if($groupExists){
        $accounts=Invoke-ResourceAz @('cognitiveservices','account','list','--resource-group',$config.resourceGroup,'--subscription',$config.subscriptionId)
        $account=@($accounts|Where-Object {$_.name -eq $config.resourceName})|Select-Object -First 1
        if($account){$deployments=@(Invoke-ResourceAz @('cognitiveservices','account','deployment','list','--resource-group',$config.resourceGroup,'--name',$config.resourceName,'--subscription',$config.subscriptionId))}
    }
    $roleAlreadyAssigned=$false
    if($account -and $config.principalObjectId){
        $assignments=Invoke-ResourceAz @('role','assignment','list','--scope',$plan.scope,'--include-inherited','--fill-principal-name','false','--subscription',$config.subscriptionId)
        $roleAlreadyAssigned=@($assignments|Where-Object {$_.principalId -eq $config.principalObjectId -and $_.roleDefinitionName -eq 'Cognitive Services OpenAI User'}).Count -gt 0
    }
    # A process-private scratch file contains metadata only, never credentials.
    $scratch=[IO.Path]::GetTempFileName()
    Write-JsonFile $scratch @{subscription=@{id=$subscription.id;tenantId=$subscription.tenantId};cloud=$cloud.name;providerState=$provider.registrationState;catalog=@($catalog);groupExists=[bool]$groupExists;account=$account;deployments=@($deployments);roleAlreadyAssigned=$roleAlreadyAssigned}
    $checkText=& $node (Join-Path $PSScriptRoot 'scripts\azure-plan.mjs') $ConfigPath $scratch
    if($LASTEXITCODE -ne 0){throw 'Azure preflight rejected the plan. No cloud resources were changed.'}
    $check=($checkText -join "`n")|ConvertFrom-Json
    $check|ConvertTo-Json -Depth 6
    if($Mode -eq 'Check'){return}
    if(Test-Path -LiteralPath $OutputProfile){throw 'OutputProfile already exists. Choose a new path; Apply does not overwrite personal profiles.'}
    if($check.createResourceGroup){Invoke-ResourceAz @('group','create','--name',$config.resourceGroup,'--location',$config.location,'--subscription',$config.subscriptionId) -NoResult}
    if($check.createAccount){
        Write-JsonFile $scratch $plan.accountBody
        Invoke-ResourceAz @('resource','create','--resource-group',$config.resourceGroup,'--name',$config.resourceName,'--resource-type','Microsoft.CognitiveServices/accounts','--api-version',$plan.accountApiVersion,'--is-full-object','--properties',('@'+$scratch),'--subscription',$config.subscriptionId) -NoResult
    }
    foreach($deployment in $plan.deployments){
        if($deployment.id -in $check.missingDeployments){Invoke-ResourceAz ([string[]]$deployment.args) -NoResult}
    }
    if($plan.roleArgs -and -not $check.roleAlreadyAssigned){Invoke-ResourceAz ([string[]]$plan.roleArgs) -NoResult}
    foreach($model in @($config.speech,$config.polish)){
        $deployed=Invoke-ResourceAz @('cognitiveservices','account','deployment','show','--subscription',$config.subscriptionId,'--resource-group',$config.resourceGroup,'--name',$config.resourceName,'--deployment-name',$model.deployment)
        if($deployed.properties.provisioningState -ne 'Succeeded'){throw 'Deployment has not reached Succeeded. Check Azure before continuing.'}
    }
    [void][IO.Directory]::CreateDirectory((Split-Path ([IO.Path]::GetFullPath($OutputProfile)) -Parent))
    Write-JsonFile ([IO.Path]::GetFullPath($OutputProfile)) $plan.profile
    Write-Host ('Azure deployments verified; local profile written to '+[IO.Path]::GetFullPath($OutputProfile))
    Write-Host 'RBAC propagation and inference still need verification. Run Setup.ps1 -Mode Check, then Apply; sign in to the bridge profile separately.'
}catch{
    if($Mode -eq 'Apply'){Write-Warning 'Apply is not transactional. Some resources may exist; rerun Check before retrying. Nothing is automatically deleted.'}
    throw
}finally{
    $env:AZURE_CONFIG_DIR=$oldDirectory
    if($scratch -and (Test-Path -LiteralPath $scratch)){Remove-Item -LiteralPath $scratch}
}
