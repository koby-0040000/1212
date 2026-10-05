# SIONYX agent - runs on each computer.
#  - Sends a heartbeat to the relay every 5s (so the dashboard shows active / off).
#  - When the admin presses "connect", receives a one-time token and bridges the
#    local TightVNC (127.0.0.1:5900) to the relay over HTTPS (NetFree-friendly).
#
# Install (PowerShell as Administrator, number is the computer number you choose):
#   .\sionyx-agent.ps1 -ComputerNumber 12 -Key "<AGENT_KEY>" -Server "https://<name>.onrender.com" -Install
# Remove:  Unregister-ScheduledTask -TaskName SionyxAgent -Confirm:$false
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
  Copy-Item -LiteralPath $PSCommandPath -Destination $target -Force
  $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target`" -ComputerNumber `"$ComputerNumber`" -Key `"$Key`" -Server `"$Server`""
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
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

function Beat([bool]$busy) {
  try {
    $body = @{ number = $ComputerNumber; hostname = $env:COMPUTERNAME; busy = $busy } | ConvertTo-Json -Compress
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
    $started = Get-Date; $lastBeat = Get-Date; $lastPoll = [Diagnostics.Stopwatch]::StartNew()
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
      if (((Get-Date) - $lastBeat).TotalSeconds -ge 10) { [void](Beat $true); $lastBeat = Get-Date }
      if ($rx -eq 0 -and ((Get-Date) - $started).TotalSeconds -gt 120) { Log 'viewer never joined, giving up'; break }
      if (((Get-Date) - $started).TotalHours -gt 6) { Log 'max session length reached'; break }
      Start-Sleep -Milliseconds 10
    }
  } catch {
    Log "session error: $($_.Exception.Message)"
  } finally {
    if ($tcp) { $tcp.Close() }
    try { Invoke-RestMethod -Method Post -Uri "$Base/close" -UseBasicParsing -TimeoutSec 10 | Out-Null } catch { }
    Log 'session end'
  }
}

Log "agent started: computer $ComputerNumber -> $Server"
while ($true) {
  $r = Beat $false
  if ($r -and $r.session) { Run-Session ([string]$r.session) }
  Start-Sleep -Seconds 5
}
