@echo off
setlocal
if /i "%~1"=="run" goto :main
start "" /min cmd /c ""%~f0" run"
exit /b
:main
set "SX_SELF=%~dp0"
net session >nul 2>&1
if errorlevel 1 goto :elevate
powershell -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$t=[IO.File]::ReadAllText('%~f0'); $i=$t.LastIndexOf('::PS-'+'BEGIN::'); Invoke-Expression $t.Substring($i+12)"
exit /b
:elevate
powershell -NoProfile -WindowStyle Hidden -Command "Start-Process -FilePath '%~f0' -ArgumentList 'run' -Verb RunAs -WindowStyle Hidden"
exit /b
::PS-BEGIN::
$ErrorActionPreference = 'Stop'
$Server = '__SERVER__'
$Key = '__KEY__'
$AgentB64 = '__AGENT_B64__'
$VncPass = '__VNCPASS__'
$SelfDir = $env:SX_SELF

# hide any console window that is left
try {
  Add-Type -Namespace Sx -Name Win -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);'
  [void][Sx.Win]::ShowWindow([Sx.Win]::GetConsoleWindow(), 0)
} catch { }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http
[Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Blue = [Drawing.Color]::FromArgb(37, 99, 235)
$Violet = [Drawing.Color]::FromArgb(124, 58, 237)
$Green = [Drawing.Color]::FromArgb(22, 163, 74)
$Amber = [Drawing.Color]::FromArgb(217, 119, 6)
$Red = [Drawing.Color]::FromArgb(220, 38, 38)
$Gray = [Drawing.Color]::FromArgb(107, 114, 128)
$Ink = [Drawing.Color]::FromArgb(27, 35, 51)
$Check = [string][char]0x2714
$Warn = [string][char]0x26A0
$Dot = [string][char]0x25CB
$Cur = [string][char]0x25B6
$Cross = [string][char]0x2716

$form = New-Object Windows.Forms.Form
$form.Text = 'SIONYX - התקנה'
$form.ClientSize = New-Object Drawing.Size(480, 500)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.TopMost = $true
$form.RightToLeft = 'Yes'
$form.RightToLeftLayout = $true
$form.BackColor = [Drawing.Color]::White
$form.Font = New-Object Drawing.Font('Segoe UI', 10)

# gradient header
$hdr = New-Object Windows.Forms.Panel
$hdr.Dock = 'Top'; $hdr.Height = 118
$hdr.Add_Paint({
  param($s, $e)
  $br = New-Object Drawing.Drawing2D.LinearGradientBrush($s.ClientRectangle, $Blue, $Violet, 0.0)
  $e.Graphics.FillRectangle($br, $s.ClientRectangle); $br.Dispose()
})
$logo = New-Object Windows.Forms.Label
$logo.Text = [char]::ConvertFromUtf32(0x1F5A5)
$logo.Font = New-Object Drawing.Font('Segoe UI Emoji', 26)
$logo.ForeColor = [Drawing.Color]::White; $logo.BackColor = [Drawing.Color]::Transparent
$logo.AutoSize = $false; $logo.Size = New-Object Drawing.Size(70, 70); $logo.Location = New-Object Drawing.Point(390, 22)
$logo.TextAlign = 'MiddleCenter'
$t1 = New-Object Windows.Forms.Label
$t1.Text = 'SIONYX'; $t1.Font = New-Object Drawing.Font('Segoe UI', 22, [Drawing.FontStyle]::Bold)
$t1.ForeColor = [Drawing.Color]::White; $t1.BackColor = [Drawing.Color]::Transparent
$t1.AutoSize = $false; $t1.Size = New-Object Drawing.Size(340, 44); $t1.Location = New-Object Drawing.Point(40, 22); $t1.TextAlign = 'MiddleRight'
$t2 = New-Object Windows.Forms.Label
$t2.Text = 'התקנת שליטה מרחוק'; $t2.Font = New-Object Drawing.Font('Segoe UI', 11)
$t2.ForeColor = [Drawing.Color]::FromArgb(230, 235, 255); $t2.BackColor = [Drawing.Color]::Transparent
$t2.AutoSize = $false; $t2.Size = New-Object Drawing.Size(340, 26); $t2.Location = New-Object Drawing.Point(40, 66); $t2.TextAlign = 'MiddleRight'
$hdr.Controls.AddRange(@($logo, $t1, $t2))

$lbl = New-Object Windows.Forms.Label
$lbl.Text = 'מספר המחשב'; $lbl.ForeColor = $Gray
$lbl.AutoSize = $false; $lbl.Size = New-Object Drawing.Size(420, 22); $lbl.Location = New-Object Drawing.Point(30, 136); $lbl.TextAlign = 'MiddleRight'
$box = New-Object Windows.Forms.TextBox
$box.Font = New-Object Drawing.Font('Segoe UI', 16, [Drawing.FontStyle]::Bold)
$box.Size = New-Object Drawing.Size(420, 36); $box.Location = New-Object Drawing.Point(30, 160)
$box.MaxLength = 32; $box.TextAlign = 'Center'; $box.RightToLeft = 'No'
$hint = New-Object Windows.Forms.Label
$hint.Text = 'אותיות באנגלית, ספרות, מקף או קו תחתון (למשל 12)'; $hint.ForeColor = $Gray
$hint.Font = New-Object Drawing.Font('Segoe UI', 8.5)
$hint.AutoSize = $false; $hint.Size = New-Object Drawing.Size(420, 20); $hint.Location = New-Object Drawing.Point(30, 200); $hint.TextAlign = 'MiddleRight'

# step list
$stepNames = @('הכנת קבצי התוכנה', 'התקנת הסוכן במחשב', 'הגדרות מערכת', 'התקנה ובדיקת TightVNC', 'חיבור לשרת')
$steps = @()
$y = 232
foreach ($n in $stepNames) {
  $l = New-Object Windows.Forms.Label
  $l.AutoSize = $false; $l.Size = New-Object Drawing.Size(420, 24); $l.Location = New-Object Drawing.Point(30, $y)
  $l.TextAlign = 'MiddleRight'; $l.ForeColor = [Drawing.Color]::FromArgb(160, 168, 182)
  $l.Text = "$Dot  $n"; $l.Tag = $n
  $steps += $l; $y += 26
}
$bar = New-Object Windows.Forms.ProgressBar
$bar.Size = New-Object Drawing.Size(420, 10); $bar.Location = New-Object Drawing.Point(30, 372)
$bar.Minimum = 0; $bar.Maximum = 100; $bar.Style = 'Continuous'

$msg = New-Object Windows.Forms.Label
$msg.AutoSize = $false; $msg.Size = New-Object Drawing.Size(420, 40); $msg.Location = New-Object Drawing.Point(30, 390)
$msg.TextAlign = 'MiddleCenter'; $msg.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)

$btn = New-Object Windows.Forms.Button
$btn.Text = 'התקן'; $btn.Font = New-Object Drawing.Font('Segoe UI', 12, [Drawing.FontStyle]::Bold)
$btn.Size = New-Object Drawing.Size(420, 46); $btn.Location = New-Object Drawing.Point(30, 438)
$btn.FlatStyle = 'Flat'; $btn.FlatAppearance.BorderSize = 0; $btn.BackColor = $Blue; $btn.ForeColor = [Drawing.Color]::White
$btn.Cursor = 'Hand'
$form.AcceptButton = $btn
$form.Controls.AddRange(@($hdr, $lbl, $box, $hint) + $steps + @($bar, $msg, $btn))

# prefill with the number of an existing install (re-install / update)
try {
  $old = Get-ScheduledTask -TaskName 'SionyxAgent' -ErrorAction Stop
  if ($old.Actions[0].Arguments -match '-ComputerNumber "([^"]+)"') { $box.Text = $Matches[1]; $btn.Text = 'עדכן התקנה' }
} catch { }

$S = @{ done = $false }

function Pump { [Windows.Forms.Application]::DoEvents() }
function Set-Step($i, $state) {
  $l = $steps[$i]; $n = $l.Tag
  switch ($state) {
    'run'  { $l.Text = "$Cur  $n"; $l.ForeColor = $Blue; $l.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold) }
    'ok'   { $l.Text = "$Check  $n"; $l.ForeColor = $Green; $l.Font = New-Object Drawing.Font('Segoe UI', 10) }
    'warn' { $l.Text = "$Warn  $n"; $l.ForeColor = $Amber; $l.Font = New-Object Drawing.Font('Segoe UI', 10) }
    'fail' { $l.Text = "$Cross  $n"; $l.ForeColor = $Red; $l.Font = New-Object Drawing.Font('Segoe UI', 10) }
  }
  $bar.Value = [Math]::Min(100, [int](($i + 1) / $steps.Count * 100)); Pump
}
function Wait-Ms($ms) { $end = (Get-Date).AddMilliseconds($ms); while ((Get-Date) -lt $end) { Pump; Start-Sleep -Milliseconds 30 } }

# ---- TightVNC auto-install (only when the tvnserver service is missing) ----
function Get-RemoteFile($url, $dest) {
  try {
    $hc = New-Object Net.Http.HttpClient
    $hc.Timeout = [TimeSpan]::FromSeconds(180)
    $task = $hc.GetByteArrayAsync($url)
    while (-not $task.IsCompleted) { Pump; Start-Sleep -Milliseconds 40 }
    if ($task.IsFaulted -or $task.IsCanceled) { return $false }
    $bytes = $task.Result
    if ($bytes.Length -lt 500000 -or $bytes[0] -ne 0xD0 -or $bytes[1] -ne 0xCF) { return $false }   # not a real MSI (error page etc.)
    [IO.File]::WriteAllBytes($dest, $bytes)
    return $true
  } catch { return $false }
}

function Install-TightVnc {
  $arch = if ([Environment]::Is64BitOperatingSystem) { '64bit' } else { '32bit' }
  $name = "tightvnc-setup-$arch.msi"
  $msi = Join-Path $env:TEMP $name
  Remove-Item $msi -ErrorAction SilentlyContinue
  $got = $false
  # 1. an MSI placed next to this installer (offline / USB stick)
  if ($SelfDir) {
    $local = Get-ChildItem -Path $SelfDir -Filter "*tightvnc*$arch*.msi" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($local) { Copy-Item $local.FullName $msi -Force; $got = $true }
  }
  # 2. GitHub mirror of the official MSI (the sionyx-releases download host is open in NetFree; 64-bit only)
  if (-not $got -and $arch -eq '64bit') { $got = Get-RemoteFile "https://github.com/maxmax264/sionyx-releases/releases/download/tightvnc-2.8.88/tightvnc-2.8.88-gpl-setup-64bit.msi" $msi }
  # 3. from our own server (public/<name>)
  if (-not $got) { $got = Get-RemoteFile "$Server/$name" $msi }
  # 4. from tightvnc.com
  if (-not $got) { $got = Get-RemoteFile "https://www.tightvnc.com/download/2.8.87/tightvnc-2.8.87-gpl-setup-$arch.msi" $msi }
  if (-not $got) { return 'לא נמצא קובץ התקנה של TightVNC' }

  $pw = $VncPass; if ($pw.Length -gt 8) { $pw = $pw.Substring(0, 8) }   # VNC auth only uses 8 chars
  $a = @('/i', "`"$msi`"", '/quiet', '/norestart', 'ADDLOCAL=Server', 'SERVER_REGISTER_AS_SERVICE=1',
         'SERVER_ADD_FIREWALL_EXCEPTION=0',
         'SET_ALLOWLOOPBACK=1', 'VALUE_OF_ALLOWLOOPBACK=1',
         'SET_LOOPBACKONLY=1', 'VALUE_OF_LOOPBACKONLY=1')
  if ($pw) {
    $a += @('SET_USEVNCAUTHENTICATION=1', 'VALUE_OF_USEVNCAUTHENTICATION=1', 'SET_PASSWORD=1', ('VALUE_OF_PASSWORD="' + ($pw -replace '"', '""') + '"'))
  } else {
    $a += @('SET_USEVNCAUTHENTICATION=1', 'VALUE_OF_USEVNCAUTHENTICATION=0')
  }
  $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $a -PassThru -WindowStyle Hidden
  while (-not $p.HasExited) { Pump; Start-Sleep -Milliseconds 40 }
  Remove-Item $msi -ErrorAction SilentlyContinue
  if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { return ('התקנת TightVNC נכשלה (קוד ' + $p.ExitCode + ')') }
  return $null
}


# ---- install log (so a failure always leaves a readable reason) ----
$LogDir = Join-Path $env:ProgramData 'SionyxAgent'
$InstLog = Join-Path $LogDir 'install.log'
function ILog($m) {
  try {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    Add-Content -Path $InstLog -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
  } catch { }
}

# Installs the agent WITHOUT spawning "powershell -File": on lab computers a Group Policy
# execution policy / AppLocker rule often blocks .ps1 files (exit code 1) even with -ExecutionPolicy Bypass.
# The agent is started through a tiny .cmd launcher that feeds the script text to PowerShell
# via -Command (execution policy only applies to files, not to commands).
function Install-Agent($num) {
  $ErrorActionPreference = 'Continue'   # native stderr must not become a terminating error here
  $Dir = Join-Path $env:ProgramData 'SionyxAgent'
  $launcher = Join-Path $Dir 'run-agent.cmd'
  $agentPath = Join-Path $Dir 'agent.ps1'
  $psCmd = "& ([scriptblock]::Create([IO.File]::ReadAllText('$agentPath'))) -ComputerNumber '$num' -Key '$Key' -Server '$Server'"
  $line = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "' + $psCmd + '"'
  [IO.File]::WriteAllText($launcher, "@echo off`r`n$line`r`n", [Text.Encoding]::ASCII)
  ILog "launcher written: $launcher"

  $ok = $false; $why = ''
  try {
    $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c "' + $launcher + '"')
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName 'SionyxAgent' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    $ok = $true; ILog 'task registered (Register-ScheduledTask)'
  } catch { $why = $_.Exception.Message; ILog "Register-ScheduledTask failed: $why" }

  if (-not $ok) {
    # fallback: schtasks.exe (works even when the ScheduledTasks PowerShell module is unavailable)
    $out = & schtasks.exe /Create /TN SionyxAgent /TR ('cmd.exe /c "' + $launcher + '"') /SC ONSTART /RU SYSTEM /RL HIGHEST /F 2>&1 | Out-String
    ILog ("schtasks exit=$LASTEXITCODE out=" + $out.Trim())
    if ($LASTEXITCODE -eq 0) { $ok = $true } else { throw ('יצירת משימה מתוזמנת נכשלה: ' + $why + ' | ' + $out.Trim()) }
  }

  # start it now
  $started = $false
  try { Start-ScheduledTask -TaskName 'SionyxAgent' -ErrorAction Stop; $started = $true } catch { ILog "Start-ScheduledTask failed: $($_.Exception.Message)" }
  if (-not $started) {
    $o2 = & schtasks.exe /Run /TN SionyxAgent 2>&1 | Out-String
    ILog ("schtasks /Run exit=$LASTEXITCODE out=" + $o2.Trim())
    if ($LASTEXITCODE -ne 0) {
      # last resort: run the launcher directly (agent runs now; task will start it on next boot)
      Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "' + $launcher + '"') -WindowStyle Hidden
      ILog 'started launcher directly'
    }
  }
}

function Do-Install {
  $num = $box.Text.Trim()
  if ($num -notmatch '^[A-Za-z0-9_-]{1,32}$') {
    $msg.ForeColor = $Red; $msg.Text = 'מספר מחשב לא תקין (אותיות באנגלית, ספרות, - או _ עד 32 תווים)'; $box.Focus(); return
  }
  $btn.Enabled = $false; $box.Enabled = $false; $msg.Text = ''; $bar.Value = 0
  foreach ($l in $steps) { $l.Text = "$Dot  $($l.Tag)"; $l.ForeColor = [Drawing.Color]::FromArgb(160, 168, 182); $l.Font = New-Object Drawing.Font('Segoe UI', 10) }
  $problems = New-Object Collections.ArrayList
  try {
    # 1. files
    Set-Step 0 'run'
    $Dir = Join-Path $env:ProgramData 'SionyxAgent'
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    ILog "=== install start: computer $num, PS $($PSVersionTable.PSVersion), OS $([Environment]::OSVersion.Version), lang mode $($ExecutionContext.SessionState.LanguageMode)"
    Stop-ScheduledTask -TaskName 'SionyxAgent' -ErrorAction SilentlyContinue
    $target = Join-Path $Dir 'agent.ps1'
    [IO.File]::WriteAllBytes($target, [Convert]::FromBase64String($AgentB64))
    Wait-Ms 400; Set-Step 0 'ok'

    # 2. agent + scheduled task
    Set-Step 1 'run'
    Install-Agent $num
    Set-Step 1 'ok'

    # 3. system settings (Ctrl+Alt+Del from the agent)
    Set-Step 2 'run'
    try {
      $pol = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
      New-ItemProperty -Path $pol -Name 'SoftwareSASGeneration' -PropertyType DWord -Value 1 -Force | Out-Null
      Set-Step 2 'ok'
    } catch { [void]$problems.Add('לא ניתן להפעיל Ctrl+Alt+Del מרחוק'); Set-Step 2 'warn' }

    # 4. TightVNC
    Set-Step 3 'run'
    $svc = Get-Service -Name 'tvnserver' -ErrorAction SilentlyContinue
    if (-not $svc) {
      $ierr = Install-TightVnc
      if ($ierr) { [void]$problems.Add($ierr) }
      Wait-Ms 2000
      $svc = Get-Service -Name 'tvnserver' -ErrorAction SilentlyContinue
    }
    if ($svc) {
      try { Set-Service -Name 'tvnserver' -StartupType Automatic; if ($svc.Status -ne 'Running') { Start-Service -Name 'tvnserver' } } catch { }
    }
    $vnc = $false
    for ($k = 0; $k -lt 10 -and -not $vnc; $k++) {
      Wait-Ms 1000
      try { $c = New-Object Net.Sockets.TcpClient; $iar = $c.BeginConnect('127.0.0.1', 5900, $null, $null); $vnc = ($iar.AsyncWaitHandle.WaitOne(1000) -and $c.Connected); $c.Close() } catch { }
    }
    if ($svc -and $vnc) { Set-Step 3 'ok' }
    elseif ($vnc) { [void]$problems.Add('TightVNC פועל אך לא כשירות - עלול להיעצר בהתנתקות משתמש'); Set-Step 3 'warn' }
    else { [void]$problems.Add('TightVNC לא פועל - המחשב ידווח סטטוס, אך שליטה מרחוק לא תעבוד'); Set-Step 3 'warn' }

    # 5. server
    Set-Step 4 'run'
    $reached = $false; $err = ''
    try {
      $hc = New-Object Net.Http.HttpClient
      $hc.Timeout = [TimeSpan]::FromSeconds(90)
      [void]$hc.DefaultRequestHeaders.TryAddWithoutValidation('x-agent-key', $Key)
      $json = (@{ number = $num; hostname = $env:COMPUTERNAME } | ConvertTo-Json -Compress)
      $content = New-Object Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')
      $task = $hc.PostAsync("$Server/api/agent/heartbeat", $content)
      while (-not $task.IsCompleted) { Pump; Start-Sleep -Milliseconds 40 }
      if ($task.IsFaulted -or $task.IsCanceled) { $err = 'אין תגובה מהשרת' } elseif ($task.Result.IsSuccessStatusCode) { $reached = $true } else { $err = 'השרת החזיר שגיאה ' + [int]$task.Result.StatusCode }
    } catch { $err = $_.Exception.Message }
    if ($reached) { Set-Step 4 'ok' } else { [void]$problems.Add('ההתקנה הושלמה אך לא ניתן להגיע לשרת: ' + $err); Set-Step 4 'warn' }

    $bar.Value = 100
    if ($problems.Count -eq 0) {
      $msg.ForeColor = $Green; $msg.Text = "$Check  מחשב $num הותקן ויופיע בדשבורד תוך כמה שניות"
    } else {
      $msg.ForeColor = $Amber; $msg.Height = 44; $msg.Text = "הותקן, עם הערות:`n" + ($problems -join '; ')
    }
    $btn.Text = 'סגור'; $btn.BackColor = $Green; $S.done = $true; $btn.Enabled = $true
  } catch {
    ILog ('FAILED: ' + $_.Exception.Message + ' | ' + $_.ScriptStackTrace)
    $msg.ForeColor = $Red; $msg.Height = 44; $msg.Text = 'שגיאה: ' + $_.Exception.Message + "`nלוג: $InstLog"
    foreach ($l in $steps) { if ($l.Text.StartsWith($Cur)) { $l.Text = "$Cross  $($l.Tag)"; $l.ForeColor = $Red } }
    $btn.Text = 'נסה שוב'; $btn.Enabled = $true; $box.Enabled = $true
  }
}

$btn.Add_Click({ if ($S.done) { $form.Close() } else { Do-Install } })
$form.Add_Shown({ $form.Activate(); $box.Focus(); $box.SelectAll() })
[void]$form.ShowDialog()
