$LogPath = "C:\Temp"
$LogFile = Join-Path $LogPath "DefenderValidation-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

if (!(Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

Start-Transcript -Path $LogFile -Append

Write-Host "=== Microsoft Defender Signature Update Validation ==="
Write-Host "Started:" (Get-Date)

# OS Info
Write-Host "`n[OS INFORMATION]"
Get-CimInstance Win32_OperatingSystem |
Select-Object Caption, Version, BuildNumber

# Time
Write-Host "`n[DATE & TIME]"
Get-Date
Get-TimeZone
w32tm /query /status 2>&1

# TLS
Write-Host "`n[TLS SETTINGS]"
$Tls = [Net.ServicePointManager]::SecurityProtocol
Write-Host "Enabled TLS:" $Tls
if ($Tls -notmatch "Tls12") {
    Write-Warning "TLS 1.2 NOT enabled"
}

# Root certs
Write-Host "`n[ROOT CERT STORE]"
$RootCount = (Get-ChildItem Cert:\LocalMachine\Root | Measure-Object).Count
Write-Host "Root certificates:" $RootCount
if ($RootCount -lt 200) {
    Write-Warning "Low root certificate count"
}

# Proxy
Write-Host "`n[WINHTTP PROXY]"
netsh winhttp show proxy

# Connectivity
Write-Host "`n[CONNECTIVITY TEST]"
Test-NetConnection definitions.microsoft.com -Port 443

# Defender Service
Write-Host "`n[DEFENDER SERVICE]"
Get-Service WinDefend | Select Name, Status, StartType

# Defender Status
Write-Host "`n[DEFENDER SIGNATURE STATUS]"
try {
    Get-MpComputerStatus |
    Select AMServiceEnabled, AntivirusEnabled,
    AntivirusSignatureVersion,
    AntivirusSignatureLastUpdated
} catch {
    Write-Error "Failed to read Defender status"
}

Write-Host "`nValidation completed:" (Get-Date)

Stop-Transcript
Write-Host "Log written to $LogFile"