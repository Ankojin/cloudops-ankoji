# ------------------------------------------------------------------------------------
# Deploy-CertEnroll.ps1
# 
# Summary:
#   This script automates deployment of the CertEnroll folder and a certificate
#   enrollment PowerShell script to a list of remote Windows servers. It:
#     - Reads server names from a text file.
#     - Copies the CertEnroll folder to each server.
#     - Creates a scheduled task on each server to run the enrollment script.
#     - Logs all actions and errors to a log file.
# ------------------------------------------------------------------------------------
$sourceFolder = "C:\DeployCertEnroll\CertEnroll"
$remoteFolder = "C:\CertEnroll"
$scriptName = "Enroll-WebServerCert.ps1"
$serverList = Get-Content "C:\DeployCertEnroll\servers.txt"
$logFile = "C:\DeployCertEnroll\deployment.log"

function Write-Log {
    param ([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "$timestamp [$Level] $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry
}

$successList = @()
$failList = @()

foreach ($server in $serverList) {
    Write-Log "`n[+] Processing $server..."

    try {
        # Ping test (ICMP), warn if fails but continue
        if (-not (Test-Connection -ComputerName $server -Count 1 -Quiet)) {
            Write-Log "⚠ $server is not reachable via ICMP (ping). Continuing with SMB/WinRM..." "WARN"
        }

        # Copy CertEnroll folder
        $dest = "\\$server\C$\CertEnroll"
        if (Test-Path $dest) {
            Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
        }
        Copy-Item -Path $sourceFolder -Destination $dest -Recurse -Force -ErrorAction Stop
        Write-Log "✔ Copied CertEnroll folder to $server"

        # Generate task XML content with current timestamp
        $startTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Run WebServer Certificate Enrollment</Description>
  </RegistrationInfo>
  <Triggers>
    <TimeTrigger>
      <StartBoundary>$startTime</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
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

        $localTaskXml = "$env:TEMP\CertEnrollTask_$server.xml"
        $remoteTaskXml = "C:\CertEnroll\CertEnrollTask_$server.xml"
        $taskXml | Out-File $localTaskXml -Encoding Unicode
        Copy-Item -Path $localTaskXml -Destination "\\$server\C$\CertEnroll\" -Force -ErrorAction Stop

        # Create & run scheduled task remotely
        Invoke-Command -ComputerName $server -ScriptBlock {
            schtasks.exe /Create /TN "EnrollWebServerCert" /XML $using:remoteTaskXml /F
            schtasks.exe /Run /TN "EnrollWebServerCert"
        } -ErrorAction Stop

        Write-Log "✔ Scheduled task created and triggered on $server"
        $successList += $server

    } catch {
        Write-Log "❌ Error on {$server}: $($_.Exception.Message)" "ERROR"
        $failList += $server
        continue
    }
}

Write-Host "`nDeployment Summary:"
Write-Host "-------------------"
Write-Host "Successful: $($successList.Count)"
if ($successList.Count -gt 0) {
    Write-Host "  - $($successList -join "`n  - ")"
}
Write-Host "Failed: $($failList.Count)"
if ($failList.Count -gt 0) {
    Write-Host "  - $($failList -join "`n  - ")"
}