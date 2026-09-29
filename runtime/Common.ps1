$ErrorActionPreference = 'Stop'
$script:BridgeRuntimeDirectory = $PSScriptRoot

function Read-BridgeConfig {
    param([string]$Directory)
    if (-not $Directory) { $Directory = $script:BridgeRuntimeDirectory }
    Get-Content -LiteralPath (Join-Path $Directory 'bridge-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-JsonFile {
    param([string]$Path, $Value)
    $text = $Value | ConvertTo-Json -Depth 80
    [IO.File]::WriteAllText($Path, $text + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}

function Set-PrivateDirectory {
    param([string]$Path)
    [void][IO.Directory]::CreateDirectory($Path)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $identities = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
    foreach ($sid in $identities) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Invoke-BridgeAz {
    param($Config, [string[]]$Arguments)
    $before = $env:AZURE_CONFIG_DIR
    try {
        $env:AZURE_CONFIG_DIR = $Config.azureConfigDir
        & $Config.azureCliPath @Arguments
        if ($LASTEXITCODE -ne 0) { throw 'Azure CLI failed. Complete sign-in/MFA or check Azure permissions.' }
    } finally { $env:AZURE_CONFIG_DIR = $before }
}

function Get-BridgeHealth {
    param([int]$Port)
    try { Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2 } catch { $null }
}

function Assert-AppClosed {
    if (Get-Process -Name opentypeless -ErrorAction SilentlyContinue) {
        throw 'Exit OpenTypeless from its tray menu, then run setup again. Closing its window may only minimize it.'
    }
}
