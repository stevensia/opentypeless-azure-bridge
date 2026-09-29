$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$root=Join-Path ([IO.Path]::GetTempPath()) ('ot-provision-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
$beforePath=$env:Path;$beforeTest=$env:OT_AZ_TEST_ROOT;$beforeAuth=$env:AZURE_CONFIG_DIR
try{
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\resources.json') -Destination $root
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\fake-az.mjs') -Destination $root
    $node=(Get-Command node.exe).Source
    [IO.File]::WriteAllText((Join-Path $root 'az.cmd'),('@echo off'+"`r`n"+'"'+$node+'" "'+(Join-Path $root 'fake-az.mjs')+'" %*'+"`r`n"),[Text.Encoding]::ASCII)
    $env:Path=$root+';'+$env:Path;$env:OT_AZ_TEST_ROOT=$root;$env:AZURE_CONFIG_DIR='original-auth-context'
    $config=Join-Path $root 'resources.json';$profile=Join-Path $root 'profile.json';$auth=Join-Path $root 'auth'
    & (Join-Path $repo 'Azure-Resources.ps1') -Mode Plan -ConfigPath $config -OutputProfile $profile -AzureConfigDir $auth
    if(Test-Path -LiteralPath (Join-Path $root 'fake-state.json')){throw 'Plan unexpectedly invoked Azure CLI.'}
    & (Join-Path $repo 'Azure-Resources.ps1') -Mode Check -ConfigPath $config -OutputProfile $profile -AzureConfigDir $auth
    $state=Get-Content -LiteralPath (Join-Path $root 'fake-state.json') -Raw|ConvertFrom-Json
    if($state.mutations -ne 0 -or (Test-Path -LiteralPath $profile)){throw 'Check performed a mutation.'}
    & (Join-Path $repo 'Azure-Resources.ps1') -Mode Apply -ConfigPath $config -OutputProfile $profile -AzureConfigDir $auth
    $state=Get-Content -LiteralPath (Join-Path $root 'fake-state.json') -Raw|ConvertFrom-Json
    if($state.mutations -ne 5){throw 'Expected group/account/two deployments/role creation.'}
    & $node (Join-Path $repo 'runtime\validate-profile.mjs') $profile
    if($LASTEXITCODE -ne 0){throw 'Generated runtime profile is invalid.'}
    & (Join-Path $repo 'Azure-Resources.ps1') -Mode Apply -ConfigPath $config -OutputProfile (Join-Path $root 'profile-second.json') -AzureConfigDir $auth
    $state=Get-Content -LiteralPath (Join-Path $root 'fake-state.json') -Raw|ConvertFrom-Json
    if($state.mutations -ne 5){throw 'Repeated Apply changed existing matching resources.'}
    if($env:AZURE_CONFIG_DIR -ne 'original-auth-context'){throw 'Azure CLI environment leaked.'}
    Write-Host 'Provisioning wrapper verified against a fake CLI: Plan/Check/Apply, repeated Apply, output profile and environment restoration.'
}finally{
    $env:Path=$beforePath;$env:OT_AZ_TEST_ROOT=$beforeTest;$env:AZURE_CONFIG_DIR=$beforeAuth
    Write-Host ('Synthetic test evidence retained: '+$root)
}
