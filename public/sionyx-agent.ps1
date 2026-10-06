# SIONYX agent - runs on each computer.
#  - Sends a heartbeat to the relay every 5s (so the dashboard shows active / off).
#  - When the admin presses "connect", receives a one-time token and bridges the
#    local TightVNC (127.0.0.1:5900) to the relay over HTTPS (NetFree-friendly).
#
# Normal install: download the installer from the dashboard (button) and double-click it.
# Manual install (PowerShell as Administrator):
#   .\sionyx-agent.ps1 -ComputerNumber 12 -Key "<AGENT_KEY>" -Server "https://<name>.onrender.com" -Install
# Remove:  press "Remove software from computer" in the dashboard (or manually:
#          Unregister-ScheduledTask -TaskName SionyxAgent -Confirm:$false)
param(
  [Parameter(Mandatory = $true)][string]$ComputerNumber,
  [Parameter(Mandatory = $true)][string]$Key,
  [Parameter(Mandatory = $true)][string]$Server,
  [switch]$Install
)

$ErrorActionPreference = 'Continue'
$Server = $Server.TrimEnd('/')
$Dir = Join-Path $env:ProgramData 'SionyxAgent'
$LogFile = Join-Path $Dir 'agent.log'

if ($Install) {
  $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $admin) { Write-Host 'Run this PowerShell window as Administrator.' -ForegroundColor Red; exit 1 }
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  $target = Join-Path $Dir 'agent.ps1'
  if ($PSCommandPath -ne $target) { Copy-Item -LiteralPath $PSCommandPath -Destination $target -Force }
  # Start through a .cmd launcher + -Command (not -File): Group Policy execution policy / AppLocker
  # on lab computers can block .ps1 files even with -ExecutionPolicy Bypass.
  $launcher = Join-Path $Dir 'run-agent.cmd'
  $psCmd = "& ([scriptblock]::Create([IO.File]::ReadAllText('$target'))) -ComputerNumber '$ComputerNumber' -Key '$Key' -Server '$Server'"
  $launchLine = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "' + $psCmd + '"'
  [IO.File]::WriteAllText($launcher, ("@echo off`r`n" + $launchLine + "`r`n"), [Text.Encoding]::ASCII)
  $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c "' + $launcher + '"')
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  Register-ScheduledTask -TaskName 'SionyxAgent' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
  Start-ScheduledTask -TaskName 'SionyxAgent'
  Write-Host "Installed. Computer $ComputerNumber will appear in the dashboard within ~10 seconds." -ForegroundColor Green
  exit 0
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$Headers = @{ 'x-agent-key' = $Key }

function Log($m) {
  $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Write-Host $line
  try {
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) { Remove-Item $LogFile -Force }
    Add-Content -Path $LogFile -Value $line
  } catch { }
}

try {
  Add-Type -Namespace Sx -Name Native -MemberDefinition @'
[DllImport("sas.dll")] public static extern void SendSAS(bool asUser);
[DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
'@
} catch { }

# Removes the agent from this computer: tells the server, then a one-time SYSTEM task
# (independent of this process, so it is not killed with it) deletes the scheduled task and
# the C:\ProgramData\SionyxAgent folder. TightVNC itself is NOT touched.
function Start-Uninstall {
  Log 'uninstall requested - removing the agent from this computer'
  try {
    $body = @{ number = $ComputerNumber } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri "$Server/api/agent/uninstalled" -Headers $Headers -ContentType 'application/json' -Body $body -UseBasicParsing -TimeoutSec 20 | Out-Null
  } catch { Log "could not notify the server: $($_.Exception.Message)" }

  $cleanup = Join-Path $env:TEMP 'sionyx-cleanup.ps1'
  $code = @"
Start-Sleep -Seconds 4
Stop-ScheduledTask -TaskName 'SionyxAgent' -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'SionyxAgent' -Confirm:`$false -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { `$_.CommandLine -like '*SionyxAgent*agent.ps1*' -and `$_.ProcessId -ne `$PID } | ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
Remove-Item -LiteralPath '$Dir' -Recurse -Force -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'SionyxAgentCleanup' -Confirm:`$false -ErrorAction SilentlyContinue
Remove-Item -LiteralPath `$MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue
"@
  try {
    [IO.File]::WriteAllText($cleanup, $code)
    $cleanArg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$cleanup`""
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $cleanArg
    $pr = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'SionyxAgentCleanup' -Action $act -Principal $pr -Force | Out-Null
    Start-ScheduledTask -TaskName 'SionyxAgentCleanup'
  } catch {
    Log "cleanup task failed ($($_.Exception.Message)) - trying a plain process"
    try { Start-Process -FilePath 'powershell.exe' -ArgumentList $cleanArg -WindowStyle Hidden } catch { Log "cleanup failed: $($_.Exception.Message)" }
  }
  Log 'agent exiting'
  exit 0   # stop right away so it does not send another heartbeat and re-register
}

# Fixed whitelist only - the agent never runs arbitrary commands from the server.
function Run-Command([string]$cmd) {
  Log "command: $cmd"
  try {
    $none = [uint32]::MaxValue
    switch ($cmd) {
      'cad'      { [Sx.Native]::SendSAS($false) }
      'lock'     { $id = [Sx.Native]::WTSGetActiveConsoleSessionId(); if ($id -ne $none) { & tsdiscon.exe $id } }
      'logoff'   { $id = [Sx.Native]::WTSGetActiveConsoleSessionId(); if ($id -ne $none) { & logoff.exe $id } }
      'restart'  { & shutdown.exe /r /t 5 /f }
      'shutdown' { & shutdown.exe /s /t 5 /f }
      'uninstall' { Start-Uninstall }
      'sysinfo'  { $script:SysInfo = Get-SysInfo }
      'nettest'  { $script:NetInfo = Get-NetInfo }
      default    { Log "unknown command ignored: $cmd" }
    }
  } catch { Log "command failed: $($_.Exception.Message)" }
}

# Processes that must never be ended remotely (system-critical, the VNC server,
# the desktop shell, and PowerShell - which is what this agent itself runs in).
$script:ProtectedProcs = @('system','idle','registry','smss','csrss','wininit','winlogon','services','lsass','svchost','dwm','fontdrvhost',
  'explorer','sihost','taskhostw','ctfmon','conhost','memory compression','securityhealthservice','msmpeng','wmiprvse',
  'tvnserver','powershell','pwsh','wscript','cscript')
$script:KillResult = $null

function Kill-Proc($k) {
  $pidv = 0; $name = ''
  try { $pidv = [int]$k.pid; $name = [string]$k.name } catch { return }
  $base = ($name -replace '#\d+$','')
  $res = @{ pid = $pidv; name = $name; ok = $false; msg = '' }
  try {
    if ($pidv -le 4 -or $pidv -eq $PID) { $res.msg = 'protected'; throw 'protected' }
    if ($script:ProtectedProcs -contains $base.ToLower()) { $res.msg = 'protected'; throw 'protected' }
    $p = Get-Process -Id $pidv -ErrorAction SilentlyContinue
    if (-not $p) { $res.msg = 'gone'; $res.ok = $true; throw 'gone' }
    if ($p.ProcessName -ine $base) { $res.msg = 'mismatch'; throw 'mismatch' }
    Stop-Process -Id $pidv -Force -ErrorAction Stop
    Start-Sleep -Milliseconds 400
    if (Get-Process -Id $pidv -ErrorAction SilentlyContinue) { $res.msg = 'still_running' }
    else { $res.ok = $true; $res.msg = 'killed' }
    Log "killed $name ($pidv): $($res.msg)"
  } catch {
    if (-not $res.msg) { $res.msg = "error: $($_.Exception.Message)" }
    Log "kill $name ($pidv) not done: $($res.msg)"
  }
  $script:KillResult = $res
}

function Handle-Reply($r) {
  if ($r -and $r.commands) { foreach ($c in @($r.commands)) { Run-Command ([string]$c) } }
  if ($r -and $r.kills) { foreach ($k in @($r.kills)) { Kill-Proc $k } }
}

# Control channel used by the viewer's Ctrl+Alt+Del button (same JSON protocol as the kiosk app).
function Poll-Control([string]$Token) {
  try {
    $r = Invoke-RestMethod -Method Get -Uri "$Server/rt/controlAgent/$Token/recv?wait=0" -UseBasicParsing -TimeoutSec 15
    foreach ($m in $r.messages) {
      $o = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($m.data)) | ConvertFrom-Json
      if ($o.type -eq 'ctrlaltdel') { Run-Command 'cad' } else { Log "control message not supported by this agent: $($o.type)" }
    }
  } catch { }
}

function Test-Vnc {
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $iar = $c.BeginConnect('127.0.0.1', 5900, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(500) -and $c.Connected
    $c.Close()
    return [bool]$ok
  } catch { return $false }
}

function Get-Stats {
  $s = @{ agent = '4'; ver = $script:MyVer; vnc = (Test-Vnc) }
  try {
    $os = Get-CimInstance Win32_OperatingSystem
    $s.os = [string]$os.Caption
    $s.uptimeHours = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
    $s.ramTotalGb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $s.ramFreeGb = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
  } catch { }
  try {
    $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    $s.cpuPct = [int]$cpu
  } catch { }
  try {
    $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $s.diskTotalGb = [math]::Round($d.Size / 1GB)
    $s.diskFreeGb = [math]::Round($d.FreeSpace / 1GB)
  } catch { }
  try { $s.user = [string](Get-CimInstance Win32_ComputerSystem).UserName } catch { }
  try {
    $ip = [Net.Dns]::GetHostAddresses($env:COMPUTERNAME) | Where-Object { $_.AddressFamily -eq 'InterNetwork' -and -not $_.ToString().StartsWith('169.254') } | Select-Object -First 1
    if ($ip) { $s.ip = $ip.ToString() }
  } catch { }
  return $s
}

# On-demand only (triggered by the dashboard's sysinfo button, see the
# sysinfo command above) - NOT part of the regular heartbeat, since
# sampling per-process CPU has a real (if small) cost and most of the time
# nobody is looking at it. Get-Counter needs ~1s to take a real sample
# (instantaneous process CPU numbers are meaningless without one), which is
# fine here since this only runs when explicitly asked for.
function Get-SysInfo {
  $out = @{ processes = @() }
  $threads = [Math]::Max(1, [Environment]::ProcessorCount)
  $out.threads = $threads
  try {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $out.cpuModel = [string]$cpu.Name
    $out.cores = [int]$cpu.NumberOfCores
    $out.maxMhz = [int]$cpu.MaxClockSpeed
  } catch { }
  try { $out.cpuPct = [int](Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average } catch { }
  try {
    # Win32_PerfFormattedData gives a real "right now" % per process (+ PID and memory)
    # in one query. PercentProcessorTime is % of ONE core, so divide by logical CPUs
    # to get % of the whole machine (matches the overall CPU gauge).
    $all = @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop |
      Where-Object { $_.Name -notin @('_Total','Idle') })
    $out.procCount = $all.Count
    $top = $all | Where-Object { $_.PercentProcessorTime -gt 0 } | Sort-Object PercentProcessorTime -Descending | Select-Object -First 10
    $out.processes = @($top | ForEach-Object {
      $disp = ($_.Name -replace '#\d+$','')
      $low = $disp.ToLower()
      @{
        name = $_.Name; pid = [int]$_.IDProcess
        pct = [math]::Round([double]$_.PercentProcessorTime / $threads, 1)
        memMb = [math]::Round([double]$_.WorkingSet / 1MB)
        protected = [bool]($script:ProtectedProcs -contains $low -or [int]$_.IDProcess -le 4 -or [int]$_.IDProcess -eq $PID)
      }
    })
  } catch { Log "Get-SysInfo: process query failed ($($_.Exception.Message)) - processes list will be empty" }
  return $out
}

# ---- network test (on demand: dashboard "check network" button) ----
$script:MyVer = ''
try {
  $mine = [IO.File]::ReadAllText((Join-Path (Join-Path $env:ProgramData 'SionyxAgent') 'agent.ps1')).TrimStart([char]0xFEFF).Replace("`r", '')
  $sha = [Security.Cryptography.SHA1]::Create()
  $script:MyVer = (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($mine)) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 8)
} catch { }

function Test-TcpMs([string]$h, [int]$port, [int]$ms = 2000) {
  try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $c = New-Object Net.Sockets.TcpClient
    $iar = $c.BeginConnect($h, $port, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne($ms, $false) -and $c.Connected
    $t = $sw.ElapsedMilliseconds
    try { $c.Close() } catch { }
    if ($ok) { return [int]$t } else { return -1 }
  } catch { return -1 }
}
function Ping-Ms([string]$h) {
  try {
    $p = New-Object Net.NetworkInformation.Ping
    $r = $p.Send($h, 1500)
    if ($r.Status -eq 'Success') { return [int]$r.RoundtripTime } else { return -1 }
  } catch { return -1 }
}
# Timed transfer against our own server. Returns Mbps, or -1 on failure.
# Download: clock starts when the first byte is about to be read (excludes connect/TLS). Upload: write + response.
function Get-HttpMbps([string]$url, [byte[]]$payload) {
  try {
    $req = [Net.HttpWebRequest]::Create($url)
    $req.Timeout = 15000; $req.ReadWriteTimeout = 15000; $req.KeepAlive = $false
    $req.Headers.Add('x-agent-key', $Key)
    if ($payload) {
      $req.Method = 'POST'; $req.ContentType = 'application/octet-stream'; $req.ContentLength = $payload.Length
      $sw = [Diagnostics.Stopwatch]::StartNew()
      $st = $req.GetRequestStream(); $st.Write($payload, 0, $payload.Length); $st.Close()
      $resp = $req.GetResponse(); $resp.Close()
      $bytes = $payload.Length
    } else {
      $resp = $req.GetResponse()
      $sw = [Diagnostics.Stopwatch]::StartNew()
      $rs = $resp.GetResponseStream(); $buf = New-Object byte[] 65536; $bytes = 0
      while (($n = $rs.Read($buf, 0, $buf.Length)) -gt 0) { $bytes += $n }
      $rs.Close(); $resp.Close()
    }
    $sec = [Math]::Max(0.001, $sw.Elapsed.TotalSeconds)
    return [math]::Round(($bytes * 8) / $sec / 1e6, 1)
  } catch { return -1 }
}

function Get-NetInfo {
  $t0 = Get-Date
  $n = @{}
  try {
    $a = Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if ($a) { $n.adapter = [string]$a.InterfaceDescription; $n.linkMbps = [math]::Round([double]$a.Speed / 1e6); $n.wifi = [bool]($a.PhysicalMediaType -like '*802.11*') }
  } catch { }
  try {
    $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1).NextHop
    if ($gw -and $gw -ne '0.0.0.0') { $n.gateway = [string]$gw; $n.gatewayMs = Ping-Ms $gw }
  } catch { }
  # General internet (outside our server): a filtered/blocked network can reach the server but not these.
  $n.inet1Ms = Test-TcpMs '1.1.1.1' 443
  $n.inet2Ms = Test-TcpMs '8.8.8.8' 443
  try { $sw = [Diagnostics.Stopwatch]::StartNew(); [void][Net.Dns]::GetHostAddresses('www.google.com'); $n.dnsMs = [int]$sw.ElapsedMilliseconds } catch { $n.dnsMs = -1 }
  # Our server: latency (4 samples) + speed.
  $ms = @()
  for ($i = 0; $i -lt 4; $i++) {
    try {
      $sw = [Diagnostics.Stopwatch]::StartNew()
      Invoke-RestMethod -Method Get -Uri "$Server/api/agent/ping" -Headers $Headers -UseBasicParsing -TimeoutSec 8 | Out-Null
      $ms += [int]$sw.ElapsedMilliseconds
    } catch { }
  }
  $n.srvOk = ($ms.Count -gt 0)
  if ($ms.Count -gt 0) { $m = $ms | Measure-Object -Minimum -Maximum -Average; $n.srvMin = $m.Minimum; $n.srvMax = $m.Maximum; $n.srvAvg = [math]::Round($m.Average) }
  if ($n.srvOk) {
    $d = Get-HttpMbps "$Server/api/agent/speedtest?kb=256" $null
    if ($d -gt 8) { $d2 = Get-HttpMbps "$Server/api/agent/speedtest?kb=2048" $null; if ($d2 -gt 0) { $d = $d2 } }   # fast link: re-measure with a bigger file
    $n.downMbps = $d
    $n.upMbps = Get-HttpMbps "$Server/api/agent/speedtest-up" (New-Object byte[] 262144)
  }
  $n.took = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
  return $n
}

$script:LastRtt = $null
$script:Stats = $null
$script:StatsAt = [datetime]::MinValue
function Refresh-Stats {
  if (((Get-Date) - $script:StatsAt).TotalSeconds -ge 30) {
    $script:Stats = Get-Stats
    $script:StatsAt = Get-Date
  }
}

function Beat([bool]$busy) {
  try {
    $b = @{ number = $ComputerNumber; hostname = $env:COMPUTERNAME; busy = $busy; stats = $script:Stats }
    # Sent once, right after a 'sysinfo' command was answered - then cleared,
    # so we don't keep re-POSTing the same (increasingly stale) snapshot on
    # every heartbeat forever.
    if ($script:SysInfo) { $b.sysinfo = $script:SysInfo; $script:SysInfo = $null }
    if ($script:KillResult) { $b.killResult = $script:KillResult; $script:KillResult = $null }
    if ($script:NetInfo) { $b.netinfo = $script:NetInfo; $script:NetInfo = $null }
    if ($script:LastRtt -ne $null) { $b.rttMs = $script:LastRtt }   # round-trip of the PREVIOUS heartbeat
    $body = $b | ConvertTo-Json -Compress -Depth 4
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $resp = Invoke-RestMethod -Method Post -Uri "$Server/api/agent/heartbeat" -Headers $Headers -ContentType 'application/json' -Body $body -UseBasicParsing -TimeoutSec 30
    $script:LastRtt = [int]$sw.ElapsedMilliseconds
    return $resp
  } catch { return $null }
}

# Fire-and-forget heartbeat for use INSIDE an active VNC session: the normal
# Beat() above blocks until the HTTP call completes, which used to freeze the
# entire VNC pump loop (mouse/screen bytes included) for however long that
# request took - every 4 seconds, for the whole session. This version hands
# the POST to a background runspace and returns immediately, so a slow/
# NetFree-inspected heartbeat request no longer stalls VNC responsiveness.
# Trade-off: command replies (restart/shutdown/etc.) are not read from this
# call's response, so a command sent while a VNC session is active may wait
# up to one heartbeat cycle - acceptable, since the admin is already watching
# the screen live via VNC at that point.
$script:BeatRunspacePool = [runspacefactory]::CreateRunspacePool(1, 2)
$script:BeatRunspacePool.Open()
$script:BeatPending = New-Object System.Collections.ArrayList

function Reap-BeatPending {
  for ($i = $script:BeatPending.Count - 1; $i -ge 0; $i--) {
    $entry = $script:BeatPending[$i]
    if ($entry.Handle.IsCompleted) {
      try { $entry.Ps.EndInvoke($entry.Handle) | Out-Null } catch { }
      $entry.Ps.Dispose()
      $script:BeatPending.RemoveAt($i)
    }
  }
}

function Beat-Async([bool]$busy) {
  Apply-LiveStats
  Reap-BeatPending  # cheap (just .IsCompleted checks) - keeps the list from growing all session
  try {
    $body = @{ number = $ComputerNumber; hostname = $env:COMPUTERNAME; busy = $busy; stats = $script:Stats } | ConvertTo-Json -Compress -Depth 3
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:BeatRunspacePool
    [void]$ps.AddScript({
      param($Uri, $Hdrs, $Body)
      try { Invoke-RestMethod -Method Post -Uri $Uri -Headers $Hdrs -ContentType 'application/json' -Body $Body -UseBasicParsing -TimeoutSec 30 | Out-Null } catch { }
    }).AddArgument("$Server/api/agent/heartbeat").AddArgument($Headers).AddArgument($body)
    $handle = $ps.BeginInvoke()
    [void]$script:BeatPending.Add(@{ Ps = $ps; Handle = $handle })
  } catch { }
}

# Live stats during a VNC session. Refresh-Stats only runs in the main loop,
# which is NOT executed while Run-Session is active - so the CPU/RAM numbers
# used to freeze at whatever they were when the session began (e.g. 91%) and
# were re-sent unchanged for the whole session. This samples them in a
# background runspace (so the VNC pump is never blocked by slow CIM queries)
# and Beat-Async merges the fresh values into $script:Stats before sending.
$script:LiveStats = [hashtable]::Synchronized(@{})
$script:LiveStatsJob = $null
function Start-LiveStatsRefresh {
  if ($script:LiveStatsJob) {
    if (-not $script:LiveStatsJob.Handle.IsCompleted) { return }
    try { $script:LiveStatsJob.Ps.EndInvoke($script:LiveStatsJob.Handle) | Out-Null } catch { }
    $script:LiveStatsJob.Ps.Dispose()
    $script:LiveStatsJob = $null
  }
  try {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:BeatRunspacePool
    [void]$ps.AddScript({
      param($Shared)
      try { $Shared.cpuPct = [int](Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average } catch { }
      try {
        $os = Get-CimInstance Win32_OperatingSystem
        $Shared.ramFreeGb = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        $Shared.uptimeHours = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
      } catch { }
    }).AddArgument($script:LiveStats)
    $script:LiveStatsJob = @{ Ps = $ps; Handle = $ps.BeginInvoke() }
  } catch { }
}

function Apply-LiveStats {
  if (-not $script:Stats) { return }
  foreach ($k in @($script:LiveStats.Keys)) { $script:Stats[$k] = $script:LiveStats[$k] }
}

function Run-Session([string]$Token) {
  Log "session start (token $($Token.Substring(0,6))...)"
  $Base = "$Server/rt/agent/$Token"
  $tcp = $null
  try {
    $tcp = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 5900)
    $stream = $tcp.GetStream()
    $buf = New-Object byte[] 16384
    $tx = 0; $rx = 0
    $started = Get-Date; $lastBeat = Get-Date; $lastPoll = [Diagnostics.Stopwatch]::StartNew(); $lastCtl = Get-Date
    $MaxBatchBytes = 1MB  # same cap as the browser/C# transports, see relay-transport.js
    while ($true) {
      if (-not $tcp.Connected) { Log 'TightVNC closed the connection'; break }
      if ($stream.DataAvailable) {
        # Drain everything TightVNC has ready right now into ONE buffer
        # instead of POSTing each individual Read() as its own HTTP request.
        # A single screen update from TightVNC often arrives as several back-
        # to-back TCP reads; sending each as its own blocking HTTP round trip
        # (as this used to do) serialized their network latency - on a slow
        # or NetFree-inspected connection that alone could add up to seconds
        # for one update. One POST per burst fixes that.
        $ms = New-Object System.IO.MemoryStream
        while ($stream.DataAvailable -and $ms.Length -lt $MaxBatchBytes) {
          $n = $stream.Read($buf, 0, $buf.Length)
          if ($n -le 0) { break }
          $ms.Write($buf, 0, $n)
        }
        $chunk = $ms.ToArray()
        if ($chunk.Length -gt 0) {
          $sent = $false
          for ($try = 1; $try -le 6 -and -not $sent; $try++) {
            try {
              Invoke-WebRequest -Method Post -Uri "$Base/send?off=$tx" -Body $chunk -ContentType 'application/octet-stream' -UseBasicParsing -TimeoutSec 30 | Out-Null
              $sent = $true
            } catch {
              if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 409) { break }
              Start-Sleep -Milliseconds (150 * $try)
            }
          }
          if (-not $sent) { throw 'send failed, stream desynced' }
          $tx += $chunk.Length
        }
      }
      if ($lastPoll.ElapsedMilliseconds -ge 100) {
        $lastPoll.Restart()
        try {
          $r = Invoke-RestMethod -Method Get -Uri "$Base/recv?wait=200&ack=$rx" -UseBasicParsing -TimeoutSec 30
          foreach ($m in $r.messages) {
            $b = [Convert]::FromBase64String($m.data)
            if ($b.Length -ne $m.len -or $m.off -ne $rx) { continue }   # damaged/out-of-order: ask again with same ack
            $stream.Write($b, 0, $b.Length); $rx += $b.Length
          }
          if ($r.closed) { Log 'viewer disconnected'; break }
        } catch { }
      }
      if (((Get-Date) - $lastCtl).TotalMilliseconds -ge 500) { Poll-Control $Token; $lastCtl = Get-Date }
      if (((Get-Date) - $lastBeat).TotalSeconds -ge 4) { Start-LiveStatsRefresh; Beat-Async $true; $lastBeat = Get-Date }
      if ($rx -eq 0 -and ((Get-Date) - $started).TotalSeconds -gt 120) { Log 'viewer never joined, giving up'; break }
      if (((Get-Date) - $started).TotalHours -gt 6) { Log 'max session length reached'; break }
      Start-Sleep -Milliseconds 10
    }
  } catch {
    Log "session error: $($_.Exception.Message)"
  } finally {
    if ($tcp) { $tcp.Close() }
    try { Invoke-RestMethod -Method Post -Uri "$Base/close" -UseBasicParsing -TimeoutSec 10 | Out-Null } catch { }
    try { Invoke-RestMethod -Method Post -Uri "$Server/rt/controlAgent/$Token/close" -UseBasicParsing -TimeoutSec 10 | Out-Null } catch { }
    Reap-BeatPending
    Log 'session end'
  }
}

# Self-update: every ~10 minutes (only between sessions, never mid-VNC-call),
# re-download this same script from the server and compare it byte-for-byte
# against the copy installed at $target. If it changed, overwrite the
# installed copy and exit - the scheduled task's own restart policy
# (RestartCount 999 / RestartInterval 1 min, set up in -Install above)
# relaunches it within a minute, and the launcher re-reads agent.ps1 from
# disk on every launch, so the new code just takes over. This means a future
# fix only needs a push to GitHub + a Render deploy, the same one-shot
# process already used for server.js - no more visiting every kiosk by hand.
$script:AgentFile = Join-Path $Dir 'agent.ps1'
$script:LastUpdateCheck = Get-Date
function Check-ForUpdate {
  try {
    $latest = Invoke-RestMethod -Method Get -Uri "$Server/sionyx-agent.ps1" -UseBasicParsing -TimeoutSec 20
    $current = ''
    if (Test-Path $script:AgentFile) { $current = [IO.File]::ReadAllText($script:AgentFile) }
    if ($latest -and $latest -ne $current) {
      Log 'new agent version found on the server - updating and restarting'
      [IO.File]::WriteAllText($script:AgentFile, $latest)
      exit 0   # scheduled task restarts us automatically with the new file
    }
  } catch { Log "update check failed: $($_.Exception.Message)" }
}

Log "agent started: computer $ComputerNumber -> $Server"
while ($true) {
  Refresh-Stats
  $r = Beat $false
  Handle-Reply $r
  if ($r -and $r.session) { Run-Session ([string]$r.session) }
  if (((Get-Date) - $script:LastUpdateCheck).TotalMinutes -ge 10) {
    Check-ForUpdate
    $script:LastUpdateCheck = Get-Date
  }
  Start-Sleep -Seconds 5
}
