# Deploy-CertEnrollworking.ps1
[CmdletBinding()]
param(
    [string]$SourceFolder    = "C:\DeployCertEnroll\CertEnroll",
    [string]$RemoteFolder    = "C:\CertEnroll",
    [string]$ScriptName      = "Enroll-WebServerCert.ps1",
    [string]$ServerListPath  = "C:\DeployCertEnroll\servers.txt",
    [string]$LogFile         = "C:\DeployCertEnroll\deployment.log",
    # Daily time the renewal check task will run on each remote server (24-hour HH:mm)
    [string]$DailyRunTime    = "02:00"
)

$sourceFolder = $SourceFolder
$remoteFolder = $RemoteFolder
$scriptName   = $ScriptName
$serverList   = Get-Content $ServerListPath
$logFile      = $LogFile

function Write-Log {
    param ([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "$timestamp [$Level] $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry
}

foreach ($server in $serverList) {
    Write-Log "`n[+] Processing $server..."

    try {
        # Ping test (ICMP), warn if fails but continue
        if (-not (Test-Connection -ComputerName $server -Count 1 -Quiet)) {
            Write-Log "⚠ $server is not reachable via ICMP (ping). Continuing with SMB/WinRM..." "WARN"
        }

        # WinRM test (required for Invoke-Command)
        if (-not (Test-WSMan -ComputerName $server -ErrorAction SilentlyContinue)) {
            Write-Log "❌ WinRM is not available on $server. Skipping this server." "ERROR"
            continue
        }

        # Remove any existing task (old one-time or outdated version) before re-deploying
        Invoke-Command -ComputerName $server -ScriptBlock {
            $null = schtasks.exe /Query /TN "EnrollWebServerCert" 2>&1
            if ($LASTEXITCODE -eq 0) {
                schtasks.exe /Delete /TN "EnrollWebServerCert" /F | Out-Null
            }
        } -ErrorAction SilentlyContinue
        Write-Log "♻ Removed existing EnrollWebServerCert task on $server (if present)" "INFO"

        # Copy CertEnroll folder (always refresh scripts to latest version)
        $dest = "\\$server\C$\CertEnroll"
        if (Test-Path $dest) {
            Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
        }
        Copy-Item -Path $sourceFolder -Destination $dest -Recurse -Force -ErrorAction Stop
        Write-Log "✔ Copied CertEnroll folder to $server"

        # Generate task XML — daily CalendarTrigger starting tomorrow at $DailyRunTime
        # The enrollment script skips if cert has >30 days remaining, renews if <=30 days
        $startTime = (Get-Date).Date.AddDays(1).ToString("yyyy-MM-dd") + "T$($DailyRunTime):00"
        $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Daily certificate renewal check - auto-renews if expiring within 30 days</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$startTime</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-ExecutionPolicy Bypass -File "$remoteFolder\$scriptName"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

        $localTaskXml  = "$env:TEMP\CertEnrollTask_$server.xml"
        $remoteTaskXml = "C:\CertEnroll\CertEnrollTask_$server.xml"
        $taskXml | Out-File $localTaskXml -Encoding Unicode
        Copy-Item -Path $localTaskXml -Destination "\\$server\C$\CertEnroll\" -Force -ErrorAction Stop
        Remove-Item $localTaskXml -Force -ErrorAction SilentlyContinue

        # Register the persistent daily task and trigger an immediate first run
        # Note: Enroll-WebServerCert.ps1 handles the cert logic:
        #   - cert valid > 30 days  → skip (no action)
        #   - cert missing or expiring within 30 days → enroll/renew from CA
        Invoke-Command -ComputerName $server -ScriptBlock {
            schtasks.exe /Create /TN "EnrollWebServerCert" /XML $using:remoteTaskXml /F
            schtasks.exe /Run /TN "EnrollWebServerCert"
        } -ErrorAction Stop

        Write-Log "✔ Persistent daily renewal task registered and initial run triggered on $server"

        # Retry cert check loop — wait up to 3 minutes (12 x 15 sec)
        $maxRetries    = 12
        $retryInterval = 15
        $certEnrolled  = $false

        for ($i = 1; $i -le $maxRetries; $i++) {
            Write-Log "Checking certificate on $server (Attempt $i of $maxRetries)..."
            $certCheck = Invoke-Command -ComputerName $server -ScriptBlock {
                $hostname = $env:COMPUTERNAME
                $domain   = (Get-CimInstance Win32_ComputerSystem).Domain
                $fqdn     = "$hostname.$domain"
                $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
                    $_.Subject -like "*CN=$fqdn*" -and $_.NotAfter -gt (Get-Date).AddDays(30)
                }
                if ($cert) { return $true } else { return $false }
            } -ErrorAction SilentlyContinue

            if ($certCheck) {
                Write-Log "✔ Certificate successfully enrolled on $server."
                $certEnrolled = $true
                break
            }

            Start-Sleep -Seconds $retryInterval
        }

        if (-not $certEnrolled) {
            Write-Log "❌ Certificate not found or not valid on $server after $($maxRetries * $retryInterval) seconds." "ERROR"
        }

    } catch {
        Write-Log "❌ Error on $($server): $($_.Exception.Message)" "ERROR"
        continue
    }
}