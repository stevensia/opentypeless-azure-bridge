param([switch]$TaskScheduler)
$ErrorActionPreference = 'Stop'
$package = Split-Path $PSScriptRoot -Parent
$root = Join-Path ([IO.Path]::GetTempPath()) ('ot-guardian-test-' + [guid]::NewGuid().ToString('N'))
$taskName = 'OpenTypeless-GuardianTest-' + [guid]::NewGuid().ToString('N')
$foreign = $null
$checks = New-Object Collections.Generic.List[object]
function Assert-Test([bool]$Condition,[string]$Message) { if(-not $Condition){throw $Message} }
function Read-State { try {Get-Content -LiteralPath (Join-Path $root 'guardian-state.json') -Raw | ConvertFrom-Json}catch{$null} }
function Await-State([scriptblock]$Condition,[int]$Seconds=25) {
    $until=(Get-Date).AddSeconds($Seconds)
    do { $state=Read-State; if(&$Condition $state){return $state}; Start-Sleep -Milliseconds 300 } while((Get-Date) -lt $until)
    throw ('State condition timed out. Last phase: '+$state.phase)
}
function Launch-Guardian { Start-Process -FilePath (Join-Path $root 'BridgeGuardian.exe') -ArgumentList '--run' -WorkingDirectory $root -WindowStyle Hidden -PassThru }
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    foreach($name in @('BridgeGuardian.cs','Build-Guardian.ps1','Guardian.Common.ps1','Register-Guardian.ps1','Start-Bridge.ps1','Stop-Bridge.ps1','Get-BridgeStatus.ps1')) {
        Copy-Item -LiteralPath (Join-Path $package ('runtime\'+$name)) -Destination $root
    }
    & (Join-Path $root 'Build-Guardian.ps1')
    . (Join-Path $root 'Guardian.Common.ps1')
    $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
    $cfg=@{schemaVersion=1;nodePath=(Get-Command node.exe).Source;bridgePath=(Join-Path $root 'foundry-bridge.mjs');port=$port;taskName=$taskName;autoStart=$true;pollSeconds=1;healthTimeoutSeconds=1;failureThreshold=2;healthyResetSeconds=5;restartDelaySeconds=@(1,2,3)}
    Write-GuardianJson (Join-Path $root 'guardian-config.json') $cfg
    $mock=@'
import http from 'node:http';
import fs from 'node:fs';
const root=new URL('.',import.meta.url);
const cfg=JSON.parse(fs.readFileSync(new URL('guardian-config.json',root),'utf8'));
http.createServer((req,res)=>{
 if(req.url==='/health') {
   const mode=fs.existsSync(new URL('mode',root))?fs.readFileSync(new URL('mode',root),'utf8').trim():'';
   if(mode==='hang')return;
   res.writeHead(200,{'Content-Type':'application/json'});res.end(JSON.stringify({service:'OpenTypeless Foundry Bridge',version:'mock'}));
 }else{res.writeHead(403,{'Content-Type':'application/json'});res.end('{"error":{"code":"PermissionDenied"}}');}
}).listen(cfg.port,'127.0.0.1');
'@
    [IO.File]::WriteAllText($cfg.bridgePath,$mock,(New-Object Text.UTF8Encoding($false)))
    $otherScript=Join-Path $root 'foreign.mjs';[IO.File]::WriteAllText($otherScript,'setInterval(()=>{},1000);')
    $foreign=Start-Process -FilePath $cfg.nodePath -ArgumentList ('"'+$otherScript+'"') -WindowStyle Hidden -PassThru
    $bytes=[IO.File]::ReadAllBytes((Join-Path $root 'BridgeGuardian.exe'));$pe=[BitConverter]::ToInt32($bytes,0x3c);$subsystem=[BitConverter]::ToUInt16($bytes,$pe+24+68)
    Assert-Test ($subsystem -eq 2) 'Executable is not Windows GUI subsystem.'
    $guardian=Launch-Guardian
    $state=Await-State {param($s)$s -and $s.phase -eq 'healthy'}
    Assert-Test ((Get-Process -Id $state.guardianPid).MainWindowHandle -eq 0) 'Guardian has a window.'
    $checks.Add(@{name='hidden-start';ok=$true})
    $duplicate=Launch-Guardian;$duplicate.WaitForExit(5000)|Out-Null
    Assert-Test ($duplicate.HasExited -and $duplicate.ExitCode -eq 0) 'Duplicate guardian did not exit cleanly.'
    $checks.Add(@{name='single-instance';ok=$true})
    $before=$state.workerPid;$timer=[Diagnostics.Stopwatch]::StartNew();Stop-Process -Id $before
    $state=Await-State {param($s)$s -and $s.phase -eq 'healthy' -and $s.workerPid -ne $before}
    $checks.Add(@{name='worker-exit-recovery';ok=$true;milliseconds=$timer.ElapsedMilliseconds})
    $before=$state.workerPid
    try{Invoke-RestMethod -Uri "http://127.0.0.1:$port/upstream-test" -TimeoutSec 2|Out-Null}catch{}
    Start-Sleep -Seconds 4
    Assert-Test ((Read-State).workerPid -eq $before) 'A simulated upstream 403 restarted the worker.'
    $checks.Add(@{name='upstream-error-does-not-restart';ok=$true})
    [IO.File]::WriteAllText((Join-Path $root 'mode'),'hang')
    $state=Await-State {param($s)$s -and $s.workerPid -and $s.workerPid -ne $before}
    [IO.File]::WriteAllText((Join-Path $root 'mode'),'healthy')
    $state=Await-State {param($s)$s -and $s.phase -eq 'healthy'}
    $checks.Add(@{name='unresponsive-health-recovery';ok=$true})
    $before=$state.workerPid;Stop-Process -Id $state.guardianPid;Start-Sleep -Milliseconds 700;$guardian=Launch-Guardian
    $state=Await-State {param($s)$s -and $s.phase -eq 'healthy' -and $s.guardianPid -eq $guardian.Id}
    Assert-Test ($state.workerPid -eq $before) 'Guardian did not adopt its surviving worker.'
    $checks.Add(@{name='orphan-worker-adoption';ok=$true})
    if($TaskScheduler){
        $stop=Start-Process -FilePath (Join-Path $root 'BridgeGuardian.exe') -ArgumentList '--stop' -WindowStyle Hidden -Wait -PassThru
        [void](Await-State {param($s)$s -and $s.phase -eq 'paused'})
        & (Join-Path $root 'Register-Guardian.ps1')
        & (Join-Path $root 'Start-Bridge.ps1')
        $state=Await-State {param($s)$s -and $s.phase -eq 'healthy' -and $s.guardianPid -ne $guardian.Id}
        $oldGuardian=$state.guardianPid;$timer=[Diagnostics.Stopwatch]::StartNew();Stop-Process -Id $oldGuardian
        $state=Await-State {param($s)$s -and $s.phase -eq 'healthy' -and $s.guardianPid -ne $oldGuardian} 100
        $checks.Add(@{name='scheduler-recovers-guardian';ok=$true;milliseconds=$timer.ElapsedMilliseconds})
        & (Join-Path $root 'Stop-Bridge.ps1')
        Start-Sleep -Seconds 4
        Assert-Test (Test-Path -LiteralPath (Join-Path $root 'guardian.paused')) 'Pause intent was lost.'
        Assert-Test (-not (Get-ScheduledTask -TaskName $taskName).Settings.Enabled) 'Paused task is still enabled.'
        $probe=Launch-Guardian;$probe.WaitForExit(5000)|Out-Null
        Assert-Test ($probe.HasExited -and @(Get-LiveGuardian).Count -eq 0) 'Paused guardian restarted.'
        $checks.Add(@{name='persistent-pause';ok=$true})
        & (Join-Path $root 'Start-Bridge.ps1')
        [void](Await-State {param($s)$s -and $s.phase -eq 'healthy'})
        $checks.Add(@{name='explicit-resume';ok=$true})
    }
    $foreign.Refresh();Assert-Test (-not $foreign.HasExited) 'Unrelated Node process was terminated.'
    $checks.Add(@{name='unrelated-process-preserved';ok=$true})
    $checks | ConvertTo-Json -Depth 6
} finally {
    if(Test-Path -LiteralPath (Join-Path $root 'guardian-config.json')){
        [IO.File]::WriteAllText((Join-Path $root 'guardian.paused'),'test-cleanup')
        Start-Process -FilePath (Join-Path $root 'BridgeGuardian.exe') -ArgumentList '--stop' -WindowStyle Hidden -Wait | Out-Null
    }
    $ownedTask=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if($ownedTask -and $ownedTask.Actions[0].Execute -eq (Join-Path $root 'BridgeGuardian.exe')){
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    Start-Sleep -Seconds 1
    if($foreign){$foreign.Refresh();if(-not $foreign.HasExited){$foreign.Kill();$foreign.WaitForExit(5000)|Out-Null}}
    foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='BridgeGuardian.exe'" -ErrorAction SilentlyContinue | Where-Object {$_.ExecutablePath -eq (Join-Path $root 'BridgeGuardian.exe')})){Stop-Process -Id $p.ProcessId -ErrorAction SilentlyContinue}
    foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object {$_.ExecutablePath -eq $cfg.nodePath -and $_.CommandLine -match ([regex]::Escape('"'+$cfg.bridgePath+'"')+'\s*$')})){
        Stop-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
    }
    Write-Host ('Test diagnostic files retained: '+$root)
}
