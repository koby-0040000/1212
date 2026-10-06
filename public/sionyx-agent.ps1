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
      default    { Log "unknown command ignored: $cmd" }
    }
  } catch { Log "command failed: $($_.Exception.Message)" }
}

function Handle-Reply($r) {
  if ($r -and $r.commands) { foreach ($c in @($r.commands)) { Run-Command ([string]$c) } }
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
  $s = @{ agent = '3'; vnc = (Test-Vnc) }
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

# On-demand only (triggered by the dashboard's "פרטי מעבד" button, see the
# 'sysinfo' command above) - NOT part of the regular heartbeat, since
# sampling per-process CPU has a real (if small) cost and most of the time
# nobody is looking at it. Get-Counter needs ~1s to take a real sample
# (instantaneous process CPU numbers are meaningless without one), which is
# fine here since this only runs when explicitly asked for.
function Get-SysInfo {
  $out = @{ processes = @() }
  try { $out.cpuModel = [string](Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name) } catch { }
  try { $out.cores = [Environment]::ProcessorCount } catch { }
  try { $out.cpuPct = [int](Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average } catch { }
  try {
    $cores = [Math]::Max(1, [Environment]::ProcessorCount)
    # One Get-Counter sample (not Get-Process's cumulative CPU-seconds-since-
    # start, which is useless for "what's loading it RIGHT NOW") gives
    # %-of-one-core per process; dividing by core count normalizes to
    # %-of-whole-machine, matching the cpuPct shown elsewhere in the dashboard.
    $samples = (Get-Counter '\Process(*)\% Processor Time' -ErrorAction Stop).CounterSamples |
      Where-Object { $_.InstanceName -notin @('_total', 'idle') -and $_.CookedValue -gt 0.5 } |
      Sort-Object CookedValue -Descending | Select-Object -First 8
    $out.processes = @($samples | ForEach-Object {
      $name = $_.InstanceName
      $mem = $null
      try {
        # InstanceName is the process NAME, not PID (several processes can
        # share one name, e.g. multiple chrome.exe) - sum their memory.
        $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($procs) { $mem = [math]::Round(($procs | Measure-Object WorkingSet64 -Sum).Sum / 1MB) }
      } catch { }
      @{ name = $name; pct = [math]::Round($_.CookedValue / $cores, 1); memMb = $mem }
    })
  } catch { Log "Get-SysInfo: Get-Counter failed ($($_.Exception.Message)) - processes list will be empty" }
  return $out
}

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
    $body = $b | ConvertTo-Json -Compress -Depth 4
    return Invoke-RestMethod -Method Post -Uri "$Server/api/agent/heartbeat" -Headers $Headers -ContentType 'application/json' -Body $body -UseBasicParsing -TimeoutSec 30
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
