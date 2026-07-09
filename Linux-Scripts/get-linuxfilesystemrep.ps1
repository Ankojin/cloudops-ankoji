# ── SSH Authentication ─────────────────────────────────────────────────────────
# Option A (recommended): SSH private-key — no password stored in the script.
$SshUser    = 'admin'
$SshKeyPath = 'C:\ankoji\id_rsa'   # set $null to use the system default key

# Option B: PSCredential (requires plink.exe on PATH or full path below).
# Uncomment ONE of these lines, leave the other commented out.
$SshCredential = $null
# $SshCredential = Get-Credential

$PlinkPath = 'plink.exe'           # full path if plink is not on PATH

# ── Email toggle ───────────────────────────────────────────────────────────────
$SendEmail        = $true    # $false → build the HTML report only, skip email

# ── SendGrid configuration ─────────────────────────────────────────────────────
$SendGridApiKey   = 'SG.xxxxxxxxxxxxxxxxxxxx'          # your SendGrid API key
$EmailFrom        = 'monitoring@yourdomain.com'        # verified sender in SendGrid
$EmailFromName    = 'Linux Disk Monitor'
$EmailTo          = @('ops-team@yourdomain.com')       # one or more recipients
$EmailOnlyOnIssue = $true   # $false → send even when everything is OK

# ── Paths ──────────────────────────────────────────────────────────────────────
$ServersFile = 'C:\ankoji\linux-servers.txt'           # one IP or hostname per line
$ReportDir   = 'C:\ankoji'

# ── Thresholds ─────────────────────────────────────────────────────────────────
$WarningThreshold  = 80    # Yellow
$CriticalThreshold = 90    # Red

# ──────────────────────────────────────────────────────────────────────────────

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " Linux Filesystem Report  (Warn: $WarningThreshold%  Crit: $CriticalThreshold%)" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# Skip blank lines and comment lines in the server list
$Servers = Get-Content $ServersFile |
    Where-Object { $_.Trim() -ne '' -and $_ -notmatch '^\s*#' }

$RunTime    = Get-Date
$TimeStamp  = $RunTime.ToString('yyyyMMdd-HHmmss')
$ReportDate = $RunTime.ToString('dddd, dd MMMM yyyy')
$ReportTime = $RunTime.ToString('HH:mm:ss')
$ReportFile = Join-Path $ReportDir "LinuxDiskReport-$TimeStamp.html"
$SuccessLog = Join-Path $ReportDir 'LinuxSuccess.log'
$FailedLog  = Join-Path $ReportDir 'LinuxFailed.log'

Remove-Item $SuccessLog -ErrorAction SilentlyContinue
Remove-Item $FailedLog  -ErrorAction SilentlyContinue

function ConvertTo-HtmlEncoded ([string]$Text) {
    $Text -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;'
}

function Invoke-SshCommand {
    param([string]$Server, [string]$Command)

    if ($SshCredential) {
        # Extract password from SecureString only at the moment of use
        $BSTR      = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SshCredential.Password)
        $PlainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

        $Output   = & $PlinkPath -ssh -pw $PlainPass -no-antispoof -batch `
                        "$($SshCredential.UserName)@$Server" $Command 2>$null
        $ExitCode = $LASTEXITCODE

        # Zero and collect the plain-text copy immediately
        $PlainPass = $null
        [System.GC]::Collect()
    }
    elseif ($SshKeyPath) {
        $Output   = ssh -i $SshKeyPath `
                        -o ConnectTimeout=5 `
                        -o StrictHostKeyChecking=no `
                        -o BatchMode=yes `
                        "$SshUser@$Server" $Command 2>$null
        $ExitCode = $LASTEXITCODE
    }
    else {
        # No key path specified — fall back to system default key
        $Output   = ssh `
                        -o ConnectTimeout=5 `
                        -o StrictHostKeyChecking=no `
                        -o BatchMode=yes `
                        "$SshUser@$Server" $Command 2>$null
        $ExitCode = $LASTEXITCODE
    }

    return @{ Output = $Output; ExitCode = $ExitCode }
}

function Send-SendGridEmail {
    param(
        [string]   $ApiKey,
        [string]   $FromAddress,
        [string]   $FromName,
        [string[]] $ToAddresses,
        [string]   $Subject,
        [string]   $HtmlBody,
        [string[]] $Attachments = @()
    )

    $SmtpCredential = New-Object System.Management.Automation.PSCredential(
        'apikey',
        (ConvertTo-SecureString $ApiKey -AsPlainText -Force)
    )

    try {
        $MailArgs = @{
            SmtpServer  = 'smtp.sendgrid.net'
            Port        = 587
            UseSsl      = $true
            Credential  = $SmtpCredential
            From        = "$FromName <$FromAddress>"
            To          = $ToAddresses
            Subject     = $Subject
            Body        = $HtmlBody
            BodyAsHtml  = $true
            Encoding    = 'UTF8'
            ErrorAction = 'Stop'
        }
        if ($Attachments) { $MailArgs.Attachments = $Attachments }
        Send-MailMessage @MailArgs
        Write-Host "Email sent to: $($ToAddresses -join ', ')" -ForegroundColor Green
    }
    catch {
        Write-Warning "SendGrid email failed: $($_.Exception.Message)"
    }
}

# ── Collect disk data from every server ────────────────────────────────────────
# -Pk  = POSIX output, kilobyte blocks (gives raw numbers for math)
# grep filters out header, virtual/overlay filesystems, and loop devices
$DfCommand = "df -Pk | grep -vE '^Filesystem|tmpfs|devtmpfs|udev|none|overlay|shm|/dev/loop'"

$AllResults = foreach ($Server in $Servers) {
    $Server = $Server.Trim()
    Write-Host "`nChecking $Server..." -ForegroundColor Yellow

    $Ssh = Invoke-SshCommand -Server $Server -Command $DfCommand

    if ($Ssh.ExitCode -ne 0 -or -not $Ssh.Output) {
        Write-Host "  [ERROR] Could not connect or fetch data from $Server." -ForegroundColor Red
        Add-Content $FailedLog "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - FAILED - $Server"

        [PSCustomObject]@{
            Server      = $Server
            Filesystem  = 'N/A'
            Mount       = 'N/A'
            SizeGB      = 'N/A'
            FreeGB      = 'N/A'
            FreePercent = 'N/A'
            UsedPercent = 'N/A'
            Status      = 'Connection Failed'
        }
        continue
    }

    Add-Content $SuccessLog "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - SUCCESS - $Server"

    foreach ($Line in $Ssh.Output) {
        $Parts = $Line -split '\s+'
        if ($Parts.Count -lt 6) { continue }

        $SizeKB = [long]0; $FreeKB = [long]0
        [long]::TryParse($Parts[1], [ref]$SizeKB) | Out-Null
        [long]::TryParse($Parts[3], [ref]$FreeKB) | Out-Null
        if ($SizeKB -eq 0) { continue }

        $UsedPct = [int]0
        [int]::TryParse(($Parts[4] -replace '%',''), [ref]$UsedPct) | Out-Null

        $SizeGB  = [math]::Round($SizeKB / 1048576, 2)
        $FreeGB  = [math]::Round($FreeKB / 1048576, 2)
        $FreePct = [math]::Round(($FreeKB / $SizeKB) * 100, 2)

        $Status = if     ($UsedPct -ge $CriticalThreshold) { 'Critical' }
                  elseif ($UsedPct -ge $WarningThreshold)  { 'Warning'  }
                  else                                      { 'OK'       }

        $StatusLabel = if ($Status -eq 'OK') { '[OK]' } else { "[$Status]" }
        $Color       = switch ($Status) { 'Critical' { 'Red' } 'Warning' { 'Yellow' } default { 'Green' } }
        Write-Host "  $StatusLabel $($Parts[5]) — Used: $UsedPct%  Free: $FreeGB GB" -ForegroundColor $Color

        [PSCustomObject]@{
            Server      = $Server
            Filesystem  = $Parts[0]
            Mount       = $Parts[5]
            SizeGB      = $SizeGB
            FreeGB      = $FreeGB
            FreePercent = $FreePct
            UsedPercent = $UsedPct
            Status      = $Status
        }
    }
}

# ── Summary counts ─────────────────────────────────────────────────────────────
$TotalServers  = @($Servers).Count
$SuccessCount  = ($AllResults | Where-Object { $_.Status -ne 'Connection Failed' } |
                  Select-Object -ExpandProperty Server -Unique).Count
$OkCount       = ($AllResults | Where-Object { $_.Status -eq 'OK' }).Count
$WarningCount  = ($AllResults | Where-Object { $_.Status -eq 'Warning' }).Count
$CriticalCount = ($AllResults | Where-Object { $_.Status -eq 'Critical' }).Count
$FailedCount   = ($AllResults | Where-Object { $_.Status -eq 'Connection Failed' }).Count

# Report shows Warning / Critical / Failed only (OK rows suppressed)
$Results = $AllResults |
    Where-Object { $_.Status -ne 'OK' } |
    Sort-Object Status, Server, Mount

# ── HTML report ────────────────────────────────────────────────────────────────
$Html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Linux Disk Report — $ReportDate</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: 'Segoe UI', Arial, sans-serif; background: #f0f2f5; color: #333; font-size: 13px; }
.container { max-width: 1300px; margin: 30px auto; padding: 0 20px 40px; }

.header {
    background: linear-gradient(135deg, #1e3a5f 0%, #2d6a9f 100%);
    color: #fff; padding: 24px 32px; border-radius: 10px 10px 0 0;
}
.header h1  { font-size: 22px; font-weight: 600; letter-spacing: 0.3px; }
.header .meta { margin-top: 8px; font-size: 12px; opacity: 0.8; }

.summary {
    display: flex; flex-wrap: wrap; gap: 12px;
    background: #fff; padding: 20px 32px; border-bottom: 1px solid #e8e8e8;
}
.card { flex: 1; min-width: 110px; text-align: center; padding: 16px 12px; border-radius: 8px; border: 1px solid #e0e0e0; background: #fafafa; }
.card .num { font-size: 30px; font-weight: 700; line-height: 1; }
.card .lbl { font-size: 10px; text-transform: uppercase; letter-spacing: 0.6px; color: #888; margin-top: 6px; }
.c-total { border-color: #4472C4; }  .c-total .num { color: #4472C4; }
.c-ok    { border-color: #2e7d32; }  .c-ok    .num { color: #2e7d32; }
.c-warn  { border-color: #e6a817; background: #fffdf0; } .c-warn .num { color: #b87e00; }
.c-crit  { border-color: #c62828; background: #fff5f5; } .c-crit .num { color: #c62828; }
.c-fail  { border-color: #e65100; background: #fff8f4; } .c-fail .num { color: #bf360c; }

.table-wrap { background: #fff; border-radius: 0 0 10px 10px; overflow: hidden; box-shadow: 0 4px 16px rgba(0,0,0,0.08); }
table { border-collapse: collapse; width: 100%; }
thead th {
    background: #1e3a5f; color: #fff; padding: 13px 16px; text-align: left;
    font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px;
}
tbody td { padding: 11px 16px; border-bottom: 1px solid #f0f0f0; vertical-align: middle; }
tbody tr:last-child td { border-bottom: none; }
tbody tr:nth-child(even) { background: #f8f9fa; }
tbody tr:hover { filter: brightness(0.97); cursor: default; }

tbody tr.row-critical          { background: #fff0f0 !important; }
tbody tr.row-critical td       { color: #7b0000; }
tbody tr.row-warning           { background: #fffcf0 !important; }
tbody tr.row-warning  td       { color: #6b4c00; }
tbody tr.row-failed            { background: #fff5ee !important; }
tbody tr.row-failed   td       { color: #7a3000; }

.badge { display: inline-block; padding: 3px 12px; border-radius: 20px; font-size: 11px; font-weight: 700; letter-spacing: 0.4px; text-transform: uppercase; }
.badge-critical { background: #c62828; color: #fff; }
.badge-warning  { background: #f9a825; color: #3e2700; }
.badge-failed   { background: #e65100; color: #fff; }

.bar-wrap { background: #e0e0e0; border-radius: 4px; height: 7px; width: 90px; display: inline-block; vertical-align: middle; margin-left: 8px; overflow: hidden; }
.bar-fill { height: 7px; border-radius: 4px; }
.bar-crit { background: #c62828; }
.bar-warn { background: #f9a825; }

.all-clear { text-align: center; padding: 36px; color: #2e7d32; font-size: 15px; font-weight: 600; }
.footer    { text-align: center; color: #aaa; font-size: 11px; margin-top: 16px; }
</style>
</head>
<body>
<div class="container">

  <div class="header">
    <h1>Linux Filesystem Report</h1>
    <div class="meta">$ReportDate &nbsp;&nbsp;|&nbsp;&nbsp; $ReportTime</div>
  </div>

  <div class="summary">
    <div class="card c-total"><div class="num">$TotalServers</div><div class="lbl">Total Servers</div></div>
    <div class="card c-ok">   <div class="num">$SuccessCount</div><div class="lbl">Reachable</div></div>
    <div class="card c-ok">   <div class="num">$OkCount</div>     <div class="lbl">OK Mounts</div></div>
    <div class="card c-warn"> <div class="num">$WarningCount</div><div class="lbl">Warning</div></div>
    <div class="card c-crit"> <div class="num">$CriticalCount</div><div class="lbl">Critical</div></div>
    <div class="card c-fail"> <div class="num">$FailedCount</div> <div class="lbl">Unreachable</div></div>
  </div>

  <div class="table-wrap">
    <table>
      <thead>
        <tr>
          <th>Server</th>
          <th>Filesystem</th>
          <th>Mount</th>
          <th>Size (GB)</th>
          <th>Free (GB)</th>
          <th>Free %</th>
          <th>Used %</th>
          <th>Status</th>
        </tr>
      </thead>
      <tbody>
"@

foreach ($Item in $Results) {
    $RowClass   = switch ($Item.Status) {
        'Critical'          { 'row-critical' }
        'Warning'           { 'row-warning'  }
        'Connection Failed' { 'row-failed'   }
        default             { ''             }
    }
    $BadgeClass = switch ($Item.Status) {
        'Critical'          { 'badge-critical' }
        'Warning'           { 'badge-warning'  }
        'Connection Failed' { 'badge-failed'   }
        default             { ''               }
    }
    $BarClass = if ($Item.Status -eq 'Critical') { 'bar-crit' } else { 'bar-warn' }

    if ($Item.UsedPercent -ne 'N/A') {
        $FreeCell = "$($Item.FreePercent)%"
        $UsedCell = "$($Item.UsedPercent)% <span class='bar-wrap'><span class='bar-fill $BarClass' style='width:$($Item.UsedPercent)%'></span></span>"
    } else {
        $FreeCell = 'N/A'
        $UsedCell = 'N/A'
    }

    $Html += @"
        <tr class="$RowClass">
          <td>$(ConvertTo-HtmlEncoded $Item.Server)</td>
          <td>$(ConvertTo-HtmlEncoded $Item.Filesystem)</td>
          <td>$(ConvertTo-HtmlEncoded $Item.Mount)</td>
          <td>$($Item.SizeGB)</td>
          <td>$($Item.FreeGB)</td>
          <td>$FreeCell</td>
          <td>$UsedCell</td>
          <td><span class="badge $BadgeClass">$(ConvertTo-HtmlEncoded $Item.Status)</span></td>
        </tr>
"@
}

if (-not $Results) {
    $Html += "        <tr><td colspan='8' class='all-clear'>All servers and filesystems are healthy — no issues found.</td></tr>`n"
}

$Html += @"
      </tbody>
    </table>
  </div>

  <div class="footer">Linux Disk Monitor &nbsp;|&nbsp; $ReportDate &nbsp;|&nbsp; $ReportTime</div>
</div>
</body>
</html>
"@

$Html | Out-File -FilePath $ReportFile -Encoding UTF8

Write-Host ""
Write-Host "HTML Report : $ReportFile" -ForegroundColor Green
Write-Host "Success Log : $SuccessLog" -ForegroundColor Green
Write-Host "Failed Log  : $FailedLog"  -ForegroundColor Yellow

# ── Email-safe HTML body (inline styles, table layout for Outlook/Gmail) ───────
$EmailRows = ''
foreach ($Item in $Results) {
    $RowBg = switch ($Item.Status) {
        'Critical'          { '#fff0f0' }
        'Warning'           { '#fffcf0' }
        'Connection Failed' { '#fff5ee' }
        default             { '#ffffff' }
    }
    $TextColor = switch ($Item.Status) {
        'Critical'          { '#7b0000' }
        'Warning'           { '#6b4c00' }
        'Connection Failed' { '#7a3000' }
        default             { '#333333' }
    }
    $BadgeBg    = switch ($Item.Status) {
        'Critical'          { '#c62828' }
        'Warning'           { '#f9a825' }
        'Connection Failed' { '#e65100' }
        default             { '#eeeeee' }
    }
    $BadgeColor = if ($Item.Status -eq 'Warning') { '#3e2700' } else { '#ffffff' }
    $FreeDisp   = if ($Item.FreePercent -ne 'N/A') { "$($Item.FreePercent)%" } else { 'N/A' }
    $UsedDisp   = if ($Item.UsedPercent -ne 'N/A') { "$($Item.UsedPercent)%" } else { 'N/A' }

    $EmailRows += @"
          <tr style="background:$RowBg;">
            <td style="padding:8px 10px;border-bottom:1px solid #eee;font-size:12px;color:$TextColor;">$(ConvertTo-HtmlEncoded $Item.Server)</td>
            <td style="padding:8px 10px;border-bottom:1px solid #eee;font-size:12px;color:$TextColor;">$(ConvertTo-HtmlEncoded $Item.Filesystem)</td>
            <td style="padding:8px 10px;border-bottom:1px solid #eee;font-size:12px;color:$TextColor;">$(ConvertTo-HtmlEncoded $Item.Mount)</td>
            <td style="padding:8px 10px;border-bottom:1px solid #eee;font-size:12px;text-align:right;">$($Item.SizeGB)</td>
            <td style="padding:8px 10px;border-bottom:1px solid #eee;font-size:12px;text-align:right;">$($Item.FreeGB)</td>
            <td style="padding:8px 10px;border-bottom:1px solid #eee;font-size:12px;text-align:right;">$FreeDisp</td>
            <td style="padding:8px 10px;border-bottom:1px solid #eee;font-size:12px;text-align:right;font-weight:bold;color:$TextColor;">$UsedDisp</td>
            <td style="padding:8px 10px;border-bottom:1px solid #eee;text-align:center;">
              <span style="display:inline-block;background:$BadgeBg;color:$BadgeColor;padding:2px 10px;border-radius:20px;font-size:10px;font-weight:bold;text-transform:uppercase;">$(ConvertTo-HtmlEncoded $Item.Status)</span>
            </td>
          </tr>
"@
}

$AllClearEmailRow = if (-not $Results) {
    '<tr><td colspan="8" style="padding:28px;text-align:center;color:#2e7d32;font-size:14px;font-weight:bold;">All servers and filesystems are healthy.</td></tr>'
} else { '' }

$EmailHtml = @"
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"></head>
<body style="margin:0;padding:0;background:#f0f2f5;font-family:Arial,Helvetica,sans-serif;">
<table width="100%" cellpadding="0" cellspacing="0" bgcolor="#f0f2f5">
  <tr><td align="center" style="padding:24px 10px;">
    <table width="760" cellpadding="0" cellspacing="0" bgcolor="#ffffff">

      <tr><td bgcolor="#1e3a5f" style="padding:24px 28px;">
        <div style="color:#ffffff;font-size:20px;font-weight:bold;font-family:Arial,sans-serif;">Linux Filesystem Report</div>
        <div style="color:#a0c0e0;font-size:12px;margin-top:6px;font-family:Arial,sans-serif;">$ReportDate &nbsp;&nbsp;|&nbsp;&nbsp; $ReportTime</div>
      </td></tr>

      <tr><td bgcolor="#ffffff" style="padding:16px 20px;">
        <table width="100%" cellpadding="12" cellspacing="5">
          <tr>
            <td align="center" bgcolor="#f0f4ff" style="border:1px solid #c5d3f0;">
              <div style="font-size:26px;font-weight:bold;color:#4472C4;font-family:Arial,sans-serif;">$TotalServers</div>
              <div style="font-size:10px;color:#888;text-transform:uppercase;font-family:Arial,sans-serif;">Total</div>
            </td>
            <td align="center" bgcolor="#f0fff4" style="border:1px solid #a8d5b5;">
              <div style="font-size:26px;font-weight:bold;color:#2e7d32;font-family:Arial,sans-serif;">$SuccessCount</div>
              <div style="font-size:10px;color:#888;text-transform:uppercase;font-family:Arial,sans-serif;">Reachable</div>
            </td>
            <td align="center" bgcolor="#f0fff4" style="border:1px solid #a8d5b5;">
              <div style="font-size:26px;font-weight:bold;color:#2e7d32;font-family:Arial,sans-serif;">$OkCount</div>
              <div style="font-size:10px;color:#888;text-transform:uppercase;font-family:Arial,sans-serif;">OK Mounts</div>
            </td>
            <td align="center" bgcolor="#fffdf0" style="border:1px solid #e6cc80;">
              <div style="font-size:26px;font-weight:bold;color:#b87e00;font-family:Arial,sans-serif;">$WarningCount</div>
              <div style="font-size:10px;color:#888;text-transform:uppercase;font-family:Arial,sans-serif;">Warning</div>
            </td>
            <td align="center" bgcolor="#fff5f5" style="border:1px solid #f5a0a0;">
              <div style="font-size:26px;font-weight:bold;color:#c62828;font-family:Arial,sans-serif;">$CriticalCount</div>
              <div style="font-size:10px;color:#888;text-transform:uppercase;font-family:Arial,sans-serif;">Critical</div>
            </td>
            <td align="center" bgcolor="#fff8f4" style="border:1px solid #f5b880;">
              <div style="font-size:26px;font-weight:bold;color:#bf360c;font-family:Arial,sans-serif;">$FailedCount</div>
              <div style="font-size:10px;color:#888;text-transform:uppercase;font-family:Arial,sans-serif;">Unreachable</div>
            </td>
          </tr>
        </table>
      </td></tr>

      <tr><td style="padding:0 20px 20px;">
        <table width="100%" cellpadding="0" cellspacing="0">
          <tr bgcolor="#1e3a5f">
            <th style="padding:10px;text-align:left;color:#fff;font-size:11px;text-transform:uppercase;font-family:Arial,sans-serif;">Server</th>
            <th style="padding:10px;text-align:left;color:#fff;font-size:11px;text-transform:uppercase;font-family:Arial,sans-serif;">Filesystem</th>
            <th style="padding:10px;text-align:left;color:#fff;font-size:11px;text-transform:uppercase;font-family:Arial,sans-serif;">Mount</th>
            <th style="padding:10px;text-align:right;color:#fff;font-size:11px;text-transform:uppercase;font-family:Arial,sans-serif;">Size GB</th>
            <th style="padding:10px;text-align:right;color:#fff;font-size:11px;text-transform:uppercase;font-family:Arial,sans-serif;">Free GB</th>
            <th style="padding:10px;text-align:right;color:#fff;font-size:11px;text-transform:uppercase;font-family:Arial,sans-serif;">Free %</th>
            <th style="padding:10px;text-align:right;color:#fff;font-size:11px;text-transform:uppercase;font-family:Arial,sans-serif;">Used %</th>
            <th style="padding:10px;text-align:center;color:#fff;font-size:11px;text-transform:uppercase;font-family:Arial,sans-serif;">Status</th>
          </tr>
          $EmailRows
          $AllClearEmailRow
        </table>
      </td></tr>

      <tr><td bgcolor="#f8f9fa" style="padding:14px 28px;text-align:center;font-size:11px;color:#888;font-family:Arial,sans-serif;border-top:1px solid #eee;">
        Full interactive report attached &mdash; open <b>LinuxDiskReport-$TimeStamp.html</b> in a browser for complete details.
      </td></tr>

    </table>
  </td></tr>
</table>
</body>
</html>
"@

# ── Send email (only when $SendEmail is $true) ─────────────────────────────────
if ($SendEmail) {
    $HasIssues = ($CriticalCount + $WarningCount + $FailedCount) -gt 0

    if (-not $EmailOnlyOnIssue -or $HasIssues) {

        $SubjectPrefix = if     ($CriticalCount -gt 0) { '[CRITICAL]' }
                         elseif ($WarningCount  -gt 0) { '[WARNING]'  }
                         elseif ($FailedCount   -gt 0) { '[FAILED]'   }
                         else                           { '[OK]'       }

        $EmailSubject = "$SubjectPrefix Linux Filesystem Report — $ReportDate | " +
                        "Critical: $CriticalCount  Warning: $WarningCount  Failed: $FailedCount"

        Send-SendGridEmail `
            -ApiKey      $SendGridApiKey `
            -FromAddress $EmailFrom `
            -FromName    $EmailFromName `
            -ToAddresses $EmailTo `
            -Subject     $EmailSubject `
            -HtmlBody    $EmailHtml `
            -Attachments @($ReportFile)
    }
} else {
    Write-Host "`nEmail skipped (`$SendEmail = `$false)." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "Report complete." -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

Invoke-Item $ReportFile
