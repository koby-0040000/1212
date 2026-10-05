@echo off
setlocal
net session >nul 2>&1
if errorlevel 1 goto :elevate
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText('%~f0'); $i=$t.LastIndexOf('::PS-'+'BEGIN::'); Invoke-Expression $t.Substring($i+12)"
exit /b
:elevate
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b
::PS-BEGIN::
$ErrorActionPreference = 'Stop'
try {
  $Server = '__SERVER__'
  $Key = '__KEY__'
  Write-Host ''
  Write-Host '=== SIONYX remote agent installer ===' -ForegroundColor Cyan
  Write-Host ('Server: ' + $Server)
  Write-Host ''
  $num = (Read-Host 'Enter computer number (digits/letters, e.g. 12)').Trim()
  if ($num -notmatch '^[A-Za-z0-9_-]{1,32}$') { throw 'Invalid computer number (use letters, digits, - or _ , up to 32 chars)' }

  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $Dir = Join-Path $env:ProgramData 'SionyxAgent'
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  Stop-ScheduledTask -TaskName 'SionyxAgent' -ErrorAction SilentlyContinue
  $target = Join-Path $Dir 'agent.ps1'
  [IO.File]::WriteAllBytes($target, [Convert]::FromBase64String('__AGENT_B64__'))
  Write-Host 'Agent files written.'

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $target -ComputerNumber $num -Key $Key -Server $Server -Install

  # Allow Ctrl+Alt+Del (SendSAS) from services / SYSTEM tasks
  try {
    $pol = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    New-ItemProperty -Path $pol -Name 'SoftwareSASGeneration' -PropertyType DWord -Value 1 -Force | Out-Null
  } catch { Write-Host ('Could not enable Ctrl+Alt+Del policy: ' + $_.Exception.Message) -ForegroundColor Yellow }

  # TightVNC must be a Windows service so it keeps running after logout
  $svc = Get-Service -Name 'tvnserver' -ErrorAction SilentlyContinue
  if ($svc) {
    Set-Service -Name 'tvnserver' -StartupType Automatic
    if ($svc.Status -ne 'Running') { Start-Service -Name 'tvnserver' }
    Start-Sleep -Seconds 2
  }
  $vnc = $false
  try { $c = New-Object Net.Sockets.TcpClient; $iar = $c.BeginConnect('127.0.0.1', 5900, $null, $null); $vnc = ($iar.AsyncWaitHandle.WaitOne(1000) -and $c.Connected); $c.Close() } catch { }
  if ($svc -and $vnc) { Write-Host 'TightVNC service: running, starts automatically (works after logout).' -ForegroundColor Green }
  elseif ($vnc) { Write-Host 'WARNING: VNC is listening on 5900 but not as the TightVNC Windows service - it may stop when the user logs out.' -ForegroundColor Yellow }
  else { Write-Host 'WARNING: TightVNC is not running on 127.0.0.1:5900 - the computer will report status, but remote control will not work until TightVNC is installed as a service.' -ForegroundColor Yellow }

  Write-Host 'Checking connection to the server (may take up to a minute if it is waking up)...'
  try {
    $body = @{ number = $num; hostname = $env:COMPUTERNAME } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri "$Server/api/agent/heartbeat" -Headers @{ 'x-agent-key' = $Key } -ContentType 'application/json' -Body $body -UseBasicParsing -TimeoutSec 90 | Out-Null
    Write-Host ''
    Write-Host "DONE. Computer $num is registered and will appear in the dashboard." -ForegroundColor Green
  } catch {
    Write-Host ('Installed, but could not reach the server: ' + $_.Exception.Message) -ForegroundColor Yellow
  }
} catch {
  Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
}
Write-Host ''
Read-Host 'Press Enter to close' | Out-Null
