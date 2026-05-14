# Enroll-WebServerCert.ps1
# Auto-enrolls a WebServer cert on a standalone CA with logging, dry-run, and event logging
[CmdletBinding()]
param(
    [switch]$DryRun
)

# Configuration
$workDir     = "C:\CertEnroll"
$logFile     = "$workDir\cert-enroll.log"
$eventSource = "CertEnrollScript"
$infTemplate = "$workDir\request.inf"
$infFile     = "$workDir\request_expanded.inf"
$reqFile     = "$workDir\certreq.req"
$certFile    = "$workDir\certnew.cer"
$caConfig    = "DAPKIAPISCWV1.albtests.com\Albtests CA Issuer"

# Create working dir if missing
if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }

# Logging
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "$timestamp [$Level] $Message"
    try {
        Add-Content -Path $logFile -Value $entry
    } catch {
        Write-Host $entry
    }
}

# Event Log
if (-not [System.Diagnostics.EventLog]::SourceExists($eventSource)) {
    try {
        New-EventLog -LogName Application -Source $eventSource
    } catch {
        Write-Log "Failed to create event log source. Continuing without event log support." "WARNING"
    }
}

function Write-EventLogEntry {
    param([string]$Message, [string]$EntryType = "Information")
    try {
        Write-EventLog -LogName Application -Source $eventSource -EntryType $EntryType -EventId 1000 -Message $Message
    } catch {
        Write-Log "Event log write failed: $Message" "WARNING"
    }
}

# Start
$hostname = $env:COMPUTERNAME
$domain = (Get-CimInstance Win32_ComputerSystem).Domain
$fqdn = "$hostname.$domain"

Write-Log "Preparing certificate request for $fqdn"
Write-Log "Dry-run mode: $DryRun"

# Check existing cert
$existingCert = Get-ChildItem -Path Cert:\LocalMachine\My |
    Where-Object { $_.Subject -like "*CN=$fqdn*" -and $_.NotAfter -gt (Get-Date).AddDays(30) }

if ($existingCert) {
    $msg = "Valid certificate for $fqdn already exists. Skipping enrollment."
    Write-Log $msg
    Write-EventLogEntry $msg
    return
}

# Expand INF
(Get-Content $infTemplate) -replace "%FQDN%", $fqdn -replace "%HOSTNAME%", $hostname | Set-Content $infFile
Write-Log "INF file expanded and saved."

if ($DryRun) {
    $msg = "[DryRun] Skipping certificate request and submission."
    Write-Log $msg "WARNING"
    Write-EventLogEntry $msg "Warning"
    return
}

# Check certreq presence
if (-not (Get-Command certreq.exe -ErrorAction SilentlyContinue)) {
    $msg = "'certreq.exe' not found in PATH."
    Write-Log $msg "ERROR"
    Write-EventLogEntry $msg "Error"
    throw $msg
}

# Generate CSR
try {
    certreq -new $infFile $reqFile
    if ($LASTEXITCODE -ne 0) { throw "certreq -new failed." }
    Write-Log "CSR generated successfully."
} catch {
    $msg = "CSR generation failed: $_"
    Write-Log $msg "ERROR"
    Write-EventLogEntry $msg "Error"
    throw $msg
}

# Submit
try {
    certreq -submit -config $caConfig $reqFile $certFile
    if ($LASTEXITCODE -ne 0) { throw "certreq -submit failed." }
    Write-Log "Request submitted successfully."
} catch {
    $msg = "Certificate submission failed: $_"
    Write-Log $msg "ERROR"
    Write-EventLogEntry $msg "Error"
    throw $msg
}

# Accept cert
try {
    certreq -accept $certFile
    if ($LASTEXITCODE -eq 0) {
        $msg = "Certificate installed into LocalMachine\My."
        Write-Log $msg "SUCCESS"
        Write-EventLogEntry $msg
    } else {
        throw "certreq -accept failed."
    }
} catch {
    $msg = "Certificate installation failed: $_"
    Write-Log $msg "ERROR"
    Write-EventLogEntry $msg "Error"
    throw $msg
}