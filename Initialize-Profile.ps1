[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$ResourceSubdomain,
    [string]$SpeechDeployment = 'speech-main',
    [string]$PolishDeployment = 'polish-main',
    [ValidateSet('ReasoningNone','Standard')][string]$PolishPreset = 'ReasoningNone',
    [ValidateRange(1024,65535)][int]$Port = 17863,
    [string]$OutputPath,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
if (-not $TenantId) { $TenantId = Read-Host 'Microsoft Entra tenant ID (GUID)' }
if (-not $ResourceSubdomain) { $ResourceSubdomain = Read-Host 'Resource custom subdomain (without .openai.azure.com)' }
$guid=[guid]::Empty
if (-not [guid]::TryParse($TenantId,[ref]$guid) -or $guid -eq [guid]::Empty) { throw 'A valid, nonempty tenant ID is required.' }
if ($ResourceSubdomain -notmatch '^[a-z0-9][a-z0-9-]{1,62}$') { throw 'Enter only the Azure resource custom subdomain.' }
foreach ($name in @($SpeechDeployment,$PolishDeployment)) { if ($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$') { throw 'Invalid deployment ID.' } }
if (-not $OutputPath) { $OutputPath = Join-Path $PSScriptRoot '.local\azure-profile.local.json' }
$output=[IO.Path]::GetFullPath($OutputPath)
if ((Test-Path -LiteralPath $output) -and -not $Force) { throw 'Profile exists. Review it first; -Force explicitly replaces it.' }
$profile=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config\azure-profile.example.json') -Raw -Encoding UTF8|ConvertFrom-Json
$profile.tenantId=$guid.ToString()
$profile.azureEndpoint='https://'+$ResourceSubdomain+'.cognitiveservices.azure.com'
$profile.polishEndpoint='https://'+$ResourceSubdomain+'.openai.azure.com'
$profile.port=$Port
$profile.defaultModel=$SpeechDeployment
$profile.transcriptionDeployments=@($SpeechDeployment)
$profile.polishModel=$PolishDeployment
$rules=@{}
$rules[$PolishDeployment]=if($PolishPreset -eq 'ReasoningNone'){@{reasoningEffort='none';minimumOutputTokens=32}}else{@{minimumOutputTokens=1}}
$profile.polishDeployments=$rules
[void][IO.Directory]::CreateDirectory((Split-Path $output -Parent))
[IO.File]::WriteAllText($output,($profile|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
Write-Host ('Local profile saved: '+$output)
Write-Host 'This creates no Azure resources and does not verify deployments. Run Setup.ps1 -Mode Check next; keep the local profile out of Git.'
