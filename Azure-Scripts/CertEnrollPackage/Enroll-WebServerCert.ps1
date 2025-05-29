# Enroll-WebServerCert.ps1

# Configuration
$workDir = "C:\CertEnroll"
$infTemplate = "$workDir\request.inf"
$infFile = "$workDir\request_expanded.inf"
$reqFile = "$workDir\certreq.req"
$certFile = "$workDir\certnew.cer"
$DryRun = $false  # Set to $true for testing only

# Create working directory if missing
if (-not (Test-Path $workDir)) {
    New-Item -ItemType Directory -Path $workDir | Out-Null
}

# Get hostname and domain info
$hostname = $env:COMPUTERNAME
$domain = (Get-WmiObject Win32_ComputerSystem).Domain
$fqdn = "$hostname.$domain"

Write-Host "Preparing certificate request for: $fqdn"
Write-Host "Dry-run mode: $DryRun`n"

# Check if a certificate with this CN already exists
$existingCert = Get-ChildItem -Path Cert:\LocalMachine\My |
    Where-Object { $_.Subject -like "*CN=$fqdn*" -and $_.NotAfter -gt (Get-Date) }

if ($existingCert) {
    Write-Host "A valid certificate for $fqdn already exists in LocalMachine\My." -ForegroundColor Yellow
    return
}

# Replace placeholders in INF file
(Get-Content $infTemplate) -replace "%FQDN%", $fqdn -replace "%HOSTNAME%", $hostname | Set-Content $infFile

Write-Host "Generated INF:"
Get-Content $infFile | ForEach-Object { Write-Host $_ }

if ($DryRun) {
    Write-Host "`n[DryRun] Skipping certificate generation and submission." -ForegroundColor Yellow
    return
}

# Generate CSR
certreq -new $infFile $reqFile
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to generate CSR."
    exit 1
}

# Detect CA configuration (non-interactive)
$caConfig = & certutil -config - | Where-Object { $_ -match "\\" } | Select-Object -First 1
if (-not $caConfig) {
    Write-Error "Failed to detect CA configuration. Ensure the CA is reachable."
    exit 1
}

Write-Host "`nSubmitting request to CA: $caConfig"

# Submit the request
certreq -submit -config $caConfig $reqFile $certFile
if ($LASTEXITCODE -ne 0) {
    Write-Error "Submission to CA failed."
    exit 1
}

# Accept and install the issued certificate
certreq -accept $certFile
if ($LASTEXITCODE -eq 0) {
    Write-Host "`nCertificate successfully installed into LocalMachine\My" -ForegroundColor Green
} else {
    Write-Error "Failed to accept and install the certificate."
    exit 1
}
