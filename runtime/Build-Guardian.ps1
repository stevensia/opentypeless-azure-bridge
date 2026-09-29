param([string]$Directory)
$ErrorActionPreference = 'Stop'
if (-not $Directory) { $Directory = $PSScriptRoot }
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The Windows .NET Framework C# compiler was not found.' }
$source = Join-Path $Directory 'BridgeGuardian.cs'
$temporary = Join-Path $Directory 'BridgeGuardian.building.exe'
$target = Join-Path $Directory 'BridgeGuardian.exe'
& $compiler /nologo /target:winexe /optimize+ /reference:System.Web.Extensions.dll /reference:System.Management.dll ("/out:" + $temporary) $source
if ($LASTEXITCODE -ne 0) { throw 'Guardian compilation failed.' }
Move-Item -LiteralPath $temporary -Destination $target -Force
Write-Host 'Guardian compiled as a Windows GUI executable (no console window).'
