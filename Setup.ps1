[CmdletBinding()]
param(
    [ValidateSet('Check','Apply')][string]$Mode = 'Check',
    [string]$ProfilePath,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'OpenTypeless\foundry-bridge'),
    [string]$SettingsPath = (Join-Path $env:APPDATA 'com.opentypeless.app\settings.json'),
    [string]$AppPath = (Join-Path $env:LOCALAPPDATA 'OpenTypeless\opentypeless.exe'),
    [switch]$InstallDependencies,
    [switch]$DeviceCode,
    [switch]$NoLaunch,
    [switch]$NoAutoStart,
    [switch]$BridgeOnly,
    [switch]$AllowUntestedAppVersion,
    [string]$ClientId,
    [string]$CertificatePath
)
Set-StrictMode -Version 2
if (-not $ProfilePath) { $ProfilePath = Join-Path $PSScriptRoot '.local\azure-profile.local.json' }
. (Join-Path $PSScriptRoot 'runtime\Common.ps1')

function Refresh-ProcessPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
}

function Resolve-Dependency {
    param([string]$Command, [string]$WingetId)
    $cmd = Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd -and $Mode -eq 'Apply' -and $InstallDependencies) {
        if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { throw 'WinGet is missing. Install Node.js LTS and Azure CLI manually, then rerun.' }
        & winget.exe install --id $WingetId --exact --source winget --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { throw "Dependency installation failed: $WingetId" }
        Refresh-ProcessPath
        $cmd = Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($cmd) { return $cmd.Source }
    return $null
}

try {
    if ($env:OS -ne 'Windows_NT') { throw 'This setup package supports Windows only.' }
    if (-not (Test-Path -LiteralPath $ProfilePath)) { throw 'Local profile not found. Run Initialize-Profile.ps1; see README.md or docs/azure-from-zero.md.' }
    $profile = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $nodePath = Resolve-Dependency 'node.exe' 'OpenJS.NodeJS.LTS'
    $azPath = Resolve-Dependency 'az.cmd' 'Microsoft.AzureCLI'
    $report = [ordered]@{
        mode=$Mode; nodeAvailable=[bool]$nodePath; azureCliAvailable=[bool]$azPath;
        appInstalled=(Test-Path -LiteralPath $AppPath); settingsExist=(Test-Path -LiteralPath $SettingsPath);
        appRunning=[bool](Get-Process -Name opentypeless -ErrorAction SilentlyContinue);
        guardianCompilerAvailable=[bool]((Test-Path -LiteralPath (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe')) -or (Test-Path -LiteralPath (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')));
        taskSchedulerAvailable=[bool](Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue);
        bridgeListening=[bool](Get-NetTCPConnection -LocalPort $profile.port -State Listen -ErrorAction SilentlyContinue);
        speechDeployment=$profile.defaultModel; polishDeployment=$profile.polishModel
    }
    $report | ConvertTo-Json
    if (-not $report.guardianCompilerAvailable -or -not $report.taskSchedulerAvailable) { throw 'Windows .NET Framework compiler and ScheduledTasks module are required for the guardian.' }
    if ($nodePath) {
        $major = & $nodePath -p 'parseInt(process.versions.node)'
        if ($LASTEXITCODE -ne 0 -or [int]$major -lt 22) { throw 'Node.js 22 or newer is required. Install a supported Node.js LTS release.' }
        & $nodePath (Join-Path $PSScriptRoot 'runtime\validate-profile.mjs') $ProfilePath
        if ($LASTEXITCODE -ne 0) { throw 'Azure profile validation failed.' }
        if ($report.settingsExist -and -not $BridgeOnly) {
            & $nodePath (Join-Path $PSScriptRoot 'runtime\app-settings.mjs') validate $SettingsPath
            if ($LASTEXITCODE -ne 0) { throw 'OpenTypeless settings schema is not supported.' }
        }
    }
    if ($report.appInstalled -and -not $BridgeOnly) {
        $appVersion = (Get-Item -LiteralPath $AppPath).VersionInfo.ProductVersion
        if ($appVersion -notin @('1.1.59') -and -not $AllowUntestedAppVersion) {
            throw 'The automatic settings adapter targets the OpenTypeless 1.1.59 configuration schema. Use -BridgeOnly with manual UI configuration, or explicitly opt in with -AllowUntestedAppVersion after reviewing compatibility.'
        }
    }
    if ($Mode -eq 'Check') {
        if (-not $nodePath -or -not $azPath -or (-not $BridgeOnly -and (-not $report.appInstalled -or -not $report.settingsExist))) {
            Write-Host 'Preparation incomplete. Install/open OpenTypeless once, finish onboarding, then exit it. Apply can install Node/Azure CLI with -InstallDependencies.'
            exit 2
        }
        if ($report.appRunning -and -not $BridgeOnly) { Write-Host 'Preflight inspected successfully, but Apply requires OpenTypeless to be exited from its tray menu.'; exit 2 }
        Write-Host 'Read-only preflight completed. No Azure login, inference, config writes, or startup changes were performed.'
        exit 0
    }
    if (-not $nodePath -or -not $azPath) { throw 'Missing dependency. Rerun Apply with -InstallDependencies or install Node.js LTS / Azure CLI manually.' }
    if (-not $BridgeOnly -and (-not $report.appInstalled -or -not $report.settingsExist)) { throw 'Install OpenTypeless, run it once and finish onboarding, then exit from the tray before applying.' }
    if (-not $BridgeOnly) { Assert-AppClosed }
    if (($ClientId -and -not $CertificatePath) -or ($CertificatePath -and -not $ClientId)) { throw 'Provide both ClientId and CertificatePath.' }
    if ($CertificatePath -and -not (Test-Path -LiteralPath $CertificatePath)) { throw 'Certificate file not found.' }
    $InstallDir = [IO.Path]::GetFullPath($InstallDir)
    $allowedRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'OpenTypeless')).TrimEnd('\') + '\'
    if (-not $InstallDir.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $InstallDir -Leaf) -ne 'foundry-bridge') {
        throw 'InstallDir must be a dedicated foundry-bridge directory below LOCALAPPDATA\OpenTypeless.'
    }
    $configPath = Join-Path $InstallDir 'bridge-config.json'
    $old = $null
    if (Test-Path -LiteralPath $configPath) {
        $old = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'foundry-bridge.mjs'))) { throw 'Existing directory is not a recognized bridge installation.' }
    } elseif ((Test-Path -LiteralPath $InstallDir) -and @(Get-ChildItem -LiteralPath $InstallDir -Force).Count -gt 0) {
        throw 'InstallDir is nonempty but has no bridge config. Choose a new dedicated directory.'
    }
    $oldPortListening = $false
    if ($old -and $old.PSObject.Properties['port']) { $oldPortListening = [bool](Get-NetTCPConnection -LocalPort $old.port -State Listen -ErrorAction SilentlyContinue) }
    if (Test-Path -LiteralPath (Join-Path $InstallDir 'guardian-config.json')) {
        & (Join-Path $InstallDir 'Stop-Bridge.ps1')
    } elseif ($report.bridgeListening -or $oldPortListening) {
        if ((Test-Path -LiteralPath (Join-Path $InstallDir 'process.json')) -and (Test-Path -LiteralPath (Join-Path $InstallDir 'Stop-Bridge.ps1'))) {
            & (Join-Path $InstallDir 'Stop-Bridge.ps1')
        } else { throw 'Port is already occupied. Exit the previous bridge first, or choose a different port in azure-profile.json.' }
    }
    if (Get-NetTCPConnection -LocalPort $profile.port -State Listen -ErrorAction SilentlyContinue) { throw 'The selected port is still occupied; no files were replaced.' }
    Set-PrivateDirectory $InstallDir
    $backupRoot = Join-Path $InstallDir 'backups'
    [void][IO.Directory]::CreateDirectory($backupRoot)
    if ($old) {
        $previous = Join-Path $backupRoot ('runtime-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
        [void][IO.Directory]::CreateDirectory($previous)
        foreach ($file in Get-ChildItem -LiteralPath $InstallDir -File) {
            if ($file.Extension -in @('.ps1','.mjs','.cs','.exe') -or $file.Name -in @('bridge-config.json','guardian-config.json')) {
                Copy-Item -LiteralPath $file.FullName -Destination $previous
            }
        }
    }
    $config = $profile
    $key = $null
    if ($old -and $old.PSObject.Properties['localApiKey'] -and $old.localApiKey.Length -ge 32) { $key = $old.localApiKey }
    if (-not $key) {
        $bytes = New-Object byte[] 32
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $key = [Convert]::ToBase64String($bytes)
    }
    $authDirectory = Join-Path $InstallDir 'azure-auth'
    if ($old -and $old.PSObject.Properties['azureConfigDir'] -and (Test-Path -LiteralPath $old.azureConfigDir)) {
        $priorAuth = [IO.Path]::GetFullPath($old.azureConfigDir)
        if ($priorAuth.StartsWith($allowedRoot,[StringComparison]::OrdinalIgnoreCase)) { $authDirectory = $priorAuth }
    }
    $machine = @{
        localApiKey=$key; nodePath=$nodePath; azureCliPath=$azPath; installDir=$InstallDir;
        settingsPath=[IO.Path]::GetFullPath($SettingsPath); appPath=[IO.Path]::GetFullPath($AppPath);
        azureConfigDir=$authDirectory;
        powershellPath=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    }
    foreach ($entry in $machine.GetEnumerator()) { $config | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force }
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'runtime') -File) {
        Copy-Item -LiteralPath $file.FullName -Destination $InstallDir -Force
    }
    Write-JsonFile $configPath $config
    Set-PrivateDirectory $config.azureConfigDir
    $hasToken = $false
    if (-not $ClientId -and -not $DeviceCode) {
        try { $result = & (Join-Path $InstallDir 'Get-Token.ps1') 2>$null; $hasToken = [bool](($result -join "`n" | ConvertFrom-Json).accessToken) } catch { $hasToken = $false }
        $result = $null
    }
    if (-not $hasToken) { & (Join-Path $InstallDir 'Sign-In.ps1') -DeviceCode:$DeviceCode -ClientId $ClientId -CertificatePath $CertificatePath }
    & (Join-Path $PSScriptRoot 'Upgrade-Guardian.ps1') -InstallDir $InstallDir -NoAutoStart:$NoAutoStart
    Write-Host 'Checking Azure audio and polish endpoints with a short synthetic probe (normal Azure usage charges apply).'
    & $nodePath (Join-Path $InstallDir 'test-bridge.mjs') $configPath --live
    if ($LASTEXITCODE -ne 0) { throw 'Azure validation failed. Application settings have not been changed. Fix authentication/deployment errors and rerun.' }
    if (-not $BridgeOnly) {
        Assert-AppClosed
        & $nodePath (Join-Path $InstallDir 'app-settings.mjs') apply $SettingsPath $configPath $backupRoot
        if ($LASTEXITCODE -ne 0) { throw 'Application settings update failed; check the error above.' }
        if (-not $NoLaunch) { Start-Process -FilePath $AppPath -WindowStyle Hidden }
    } else { Write-Host 'Bridge-only installation completed. Configure OpenTypeless manually using docs/manual-setup.md.' }
    Write-Host 'Setup applied. In OpenTypeless, run BOTH provider connection tests, then dictate a Chinese sentence.'
    Write-Host 'The app migrates the local connection key to its own credential vault on startup. This setup does not inspect vault credentials.'
    Write-Host ('Runtime directory: ' + $InstallDir)
    exit 0
} catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}
