# Enroll-WebServerCert.ps1 with Renewal, Logging, and Event Log Reporting

# Configuration
$workDir = "C:\CertEnroll"
$logFile = "$workDir\cert-enroll.log"
$eventSource = "CertEnrollScript"
$infTemplate = "$workDir\request.inf"
$infFile = "$workDir\request_expanded.inf"
$reqFile = "$workDir\certreq.req"
$certFile = "$workDir\certnew.cer"
$DryRun = $false  # Set to $true to test without submitting

# Setup logging
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "$timestamp [$Level] $Message"
}

# Setup event logging
if (-not [System.Diagnostics.EventLog]::SourceExists($eventSource)) {
    New-EventLog -LogName Application -Source $eventSource
}

function Write-EventLogEntry {
    param([string]$Message, [string]$EntryType = "Information")
    Write-EventLog -LogName Application -Source $eventSource -EntryType $EntryType -EventId 1000 -Message $Message
}

# Create working dir if missing
if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }

$hostname = $env:COMPUTERNAME
$domain = (Get-WmiObject Win32_ComputerSystem).Domain
$fqdn = "$hostname.$domain"

Write-Log "Preparing certificate request for $fqdn"
Write-Log "Dry-run mode: $DryRun"

# Check for existing certificate
$existingCert = Get-ChildItem -Path Cert:\LocalMachine\My |
    Where-Object { $_.Subject -like "*CN=$fqdn*" -and $_.NotAfter -gt (Get-Date).AddDays(30) }

if ($existingCert) {
    Write-Log "A valid certificate already exists. Skipping renewal."
    Write-EventLogEntry "Certificate for $fqdn already exists and is valid." "Information"
    return
}

# Expand INF file
(Get-Content $infTemplate) -replace "%FQDN%", $fqdn -replace "%HOSTNAME%", $hostname | Set-Content $infFile
Write-Log "INF file expanded and saved."

if ($DryRun) {
    Write-Log "[DryRun] Skipping CSR generation and submission." "Warning"
    Write-EventLogEntry "Dry run mode enabled. No certificate request submitted." "Warning"
    return
}

# Generate CSR
certreq -new $infFile $reqFile
if ($LASTEXITCODE -ne 0) {
    $msg = "Failed to generate CSR."
    Write-Log $msg "ERROR"
    Write-EventLogEntry $msg "Error"
    exit 1
}

# Detect CA config
# $caConfig = & certutil -config - | Where-Object { $_ -match "\\" } | Select-Object -First 1
$caConfig = "DAPKIAPISCWV1.albtests.com\Albtests CA Issuer"

if (-not $caConfig) {
    $msg = "Failed to detect CA configuration."
    Write-Log $msg "ERROR"
    Write-EventLogEntry $msg "Error"
    exit 1
}

Write-Log "Submitting request to CA: $caConfig"

# Submit request
certreq -submit -config $caConfig $reqFile $certFile
if ($LASTEXITCODE -ne 0) {
    $msg = "Submission to CA failed."
    Write-Log $msg "ERROR"
    Write-EventLogEntry $msg "Error"
    exit 1
}

# Accept certificate
certreq -accept $certFile
if ($LASTEXITCODE -eq 0) {
    $msg = "Certificate successfully installed into LocalMachine\My"
    Write-Log $msg "SUCCESS"
    Write-EventLogEntry $msg "Information"
} else {
    $msg = "Failed to accept and install the certificate."
    Write-Log $msg "ERROR"
    Write-EventLogEntry $msg "Error"
    exit 1
}
