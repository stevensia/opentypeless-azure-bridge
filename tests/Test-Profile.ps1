$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$directory=Join-Path ([IO.Path]::GetTempPath()) ('ot-profile-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory|Out-Null
$output=Join-Path $directory 'profile.json'
& (Join-Path $repo 'Initialize-Profile.ps1') -TenantId '11111111-1111-1111-1111-111111111111' -ResourceSubdomain 'example-resource' -SpeechDeployment 'speech-example' -PolishDeployment 'polish-example' -OutputPath $output
& node.exe (Join-Path $repo 'runtime\validate-profile.mjs') $output
if($LASTEXITCODE -ne 0){throw 'Initialized profile failed runtime validation.'}
$hash=(Get-FileHash -LiteralPath $output).Hash
$rejected=$false
try{& (Join-Path $repo 'Initialize-Profile.ps1') -TenantId '11111111-1111-1111-1111-111111111111' -ResourceSubdomain 'example-resource' -OutputPath $output}catch{$rejected=$true}
if(-not $rejected -or (Get-FileHash -LiteralPath $output).Hash -ne $hash){throw 'Existing profile was not preserved.'}
& (Join-Path $repo 'Initialize-Profile.ps1') -TenantId '11111111-1111-1111-1111-111111111111' -ResourceSubdomain 'example-resource' -PolishPreset Standard -OutputPath $output -Force
$profile=Get-Content -LiteralPath $output -Raw|ConvertFrom-Json
if($profile.polishDeployments.'polish-main'.PSObject.Properties['reasoningEffort']){throw 'Standard preset unexpectedly includes reasoning effort.'}
Write-Host 'Profile initialization, validation, overwrite protection and Standard preset passed.'
Write-Host ('Synthetic profile evidence retained: '+$directory)
