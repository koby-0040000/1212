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
  $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target`" -ComputerNumber `"$ComputerNumber`" -Key `"$Key`" -Server `"$Server`""
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
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
    $body = @{ number = $ComputerNumber; hostname = $env:COMPUTERNAME; busy = $busy; stats = $script:Stats } | ConvertTo-Json -Compress -Depth 3
    return Invoke-RestMethod -Method Post -Uri "$Server/api/agent/heartbeat" -Headers $Headers -ContentType 'application/json' -Body $body -UseBasicParsing -TimeoutSec 30
  } catch { return $null }
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
    while ($true) {
      if (-not $tcp.Connected) { Log 'TightVNC closed the connection'; break }
      while ($stream.DataAvailable) {
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $chunk = New-Object byte[] $n; [Array]::Copy($buf, $chunk, $n)
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
        $tx += $n
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
      if (((Get-Date) - $lastBeat).TotalSeconds -ge 4) { Handle-Reply (Beat $true); $lastBeat = Get-Date }
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
    Log 'session end'
  }
}

Log "agent started: computer $ComputerNumber -> $Server"
while ($true) {
  Refresh-Stats
  $r = Beat $false
  Handle-Reply $r
  if ($r -and $r.session) { Run-Session ([string]$r.session) }
  Start-Sleep -Seconds 5
}
