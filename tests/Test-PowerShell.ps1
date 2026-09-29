$ErrorActionPreference = 'Stop'
$package = Split-Path $PSScriptRoot -Parent
$count = 0
Get-ChildItem -LiteralPath $package -Recurse -Filter *.ps1 | ForEach-Object {
    $tokens=$null; $errors=$null
    [Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors.Count -gt 0) { throw ('PowerShell parse failed: '+$_.Name+' / '+($errors.Message -join ', ')) }
    $count++
}
Write-Host "PowerShell parser checks passed: $count files."
. (Join-Path $package 'runtime\Common.ps1')
$testDir = Join-Path ([IO.Path]::GetTempPath()) ('ot-ps-test-'+[guid]::NewGuid().ToString('N'))
$environmentBefore = $env:AZURE_CONFIG_DIR
try {
    Set-PrivateDirectory $testDir
    $acl = Get-Acl -LiteralPath $testDir
    if (-not $acl.AreAccessRulesProtected) { throw 'Runtime directory ACL is not protected.' }
    $fakeAz = Join-Path $testDir 'fake-az.cmd'
    [IO.File]::WriteAllText($fakeAz,"@echo off`r`necho %AZURE_CONFIG_DIR%`r`nexit /b 0`r`n")
    $isolatedDir = Join-Path $testDir 'isolated-auth'
    $cfg = [pscustomobject]@{azureCliPath=$fakeAz;azureConfigDir=$isolatedDir}
    $env:AZURE_CONFIG_DIR = 'original-profile-must-survive'
    $output = Invoke-BridgeAz $cfg @('account','show')
    if (($output -join '').Trim() -ne $isolatedDir) { throw 'CLI did not receive the isolated config path.' }
    if ($env:AZURE_CONFIG_DIR -ne 'original-profile-must-survive') { throw 'Original CLI environment was not restored.' }
    [IO.File]::WriteAllText($fakeAz,"@echo off`r`nexit /b 7`r`n")
    $threw = $false
    try { Invoke-BridgeAz $cfg @('account','show') } catch { $threw = $true }
    if (-not $threw -or $env:AZURE_CONFIG_DIR -ne 'original-profile-must-survive') { throw 'Failure-path environment restoration failed.' }
    Write-Host 'ACL and Azure CLI profile isolation checks passed, including the failure path.'
} finally {
    $env:AZURE_CONFIG_DIR = $environmentBefore
    # Delete only this freshly generated test directory, after confirming its exact parent/name.
    $full = [IO.Path]::GetFullPath($testDir)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ((Split-Path $full -Parent) -eq $expectedParent -and (Split-Path $full -Leaf) -match '^ot-ps-test-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
