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
    $privateChild = Join-Path $testDir 'private-auth'
    Set-PrivateDirectory $privateChild
    $ownerBefore = (Get-Acl -LiteralPath $privateChild).Owner
    foreach ($directory in @($testDir, $privateChild, $privateChild)) {
        Set-PrivateDirectory $directory
        $acl = Get-Acl -LiteralPath $directory
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $expected = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
        if (-not $acl.AreAccessRulesProtected -or $rules.Count -ne $expected.Count) { throw 'Repeated private ACL application changed the rule count or inheritance.' }
        foreach ($rule in $rules) {
            if ($rule.IdentityReference.Value -notin $expected -or $rule.IsInherited -or
                $rule.AccessControlType -ne 'Allow' -or $rule.FileSystemRights -ne 'FullControl' -or
                $rule.InheritanceFlags -ne 'ContainerInherit, ObjectInherit' -or $rule.PropagationFlags -ne 'None') {
                throw 'Private directory has unexpected access permissions.'
            }
        }
    }
    if ((Get-Acl -LiteralPath $privateChild).Owner -ne $ownerBefore) { throw 'Private ACL application changed the directory owner.' }
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
    [IO.File]::WriteAllText($fakeAz,"@echo off`r`necho {""azure-cli"":""2.53.1""}`r`nexit /b 0`r`n")
    $threw = $false
    try { Assert-AzureCliVersion $fakeAz } catch {
        if ($_.Exception.Message -notlike '*2.54.0*') { throw }
        $threw = $true
    }
    if (-not $threw) { throw 'Unsupported Azure CLI version was accepted.' }
    [IO.File]::WriteAllText($fakeAz,"@echo off`r`necho {""azure-cli"":""2.54.0""}`r`nexit /b 0`r`n")
    Assert-AzureCliVersion $fakeAz
    [IO.File]::WriteAllText($fakeAz,"@echo off`r`nexit /b 7`r`n")
    $threw = $false
    try { Assert-AzureCliVersion $fakeAz } catch { $threw = $true }
    if (-not $threw) { throw 'Failed Azure CLI version lookup was accepted.' }
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
