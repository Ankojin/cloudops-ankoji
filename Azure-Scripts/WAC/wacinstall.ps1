# =============================================
# Windows Admin Center - Custom Hostname + Your Certificate
# Hostname: wac.albtests.com
# Certificate Thumbprint: 52cf4ee74903a95ce28190b82cd16499fe829884
# =============================================

# --- Configuration ---
$WacHostname   = "wac.albtests.com"
$Username      = "WACAdmin"
$Password      = "Sw3th@1984!qaz@wsx"          # ← CHANGE THIS PASSWORD
$InstallerPath = "C:\Users\AnkojiRaoNagisetty\Documents\Downloads\WindowsAdminCenter2606.exe"
$HttpsPort     = 6600
$Thumbprint    = "52cf4ee74903a95ce28190b82cd16499fe829884"

# --- 1. Create local admin account ---
Write-Host "Creating local administrator account: $Username" -ForegroundColor Cyan

net user $Username $Password /add /fullname /passwordchg:no 2>$null
net localgroup Administrators $Username /add 2>$null

Write-Host "Account created." -ForegroundColor Green

# --- 2. Verify the certificate exists ---
Write-Host "`nChecking certificate..." -ForegroundColor Cyan

$cert = Get-ChildItem -Path Cert:\LocalMachine\My\$Thumbprint -ErrorAction SilentlyContinue

if (-not $cert) {
    Write-Error "Certificate with thumbprint $Thumbprint not found in LocalMachine\My store."
    return
}

Write-Host "Certificate found:" -ForegroundColor Green
Write-Host "  Subject      : $($cert.Subject)"
Write-Host "  FriendlyName : $($cert.FriendlyName)"
Write-Host "  Thumbprint   : $($cert.Thumbprint)"
Write-Host "  Expires      : $($cert.NotAfter)"

# --- 3. Add hosts file entry ---
$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$hostsEntry = "127.0.0.1`t$WacHostname"

if (-not (Select-String -Path $hostsPath -Pattern $WacHostname -Quiet)) {
   Add-Content -Path $hostsPath -Value $hostsEntry
   Write-Host "`nHosts file updated with $WacHostname" -ForegroundColor Green
} else {
   Write-Host "`nHosts entry already exists." -ForegroundColor Yellow
}

# --- 4. Install Windows Admin Center ---
if (-not (Test-Path $InstallerPath)) {
    Write-Error "Installer not found at $InstallerPath"
    return
}

Write-Host "`nInstalling Windows Admin Center..." -ForegroundColor Cyan

$args = "/VERYSILENT /NORESTART /HTTPSPortNumber=$HttpsPort /CertificateThumbprint=$Thumbprint"
Start-Process -FilePath $InstallerPath -ArgumentList $args -Wait

Write-Host "Installation finished." -ForegroundColor Green

# --- 5. Configure certificate + FQDN ---
Start-Sleep -Seconds 8

$modulePath = "$env:ProgramFiles\WindowsAdminCenter\PowerShellModules\Microsoft.WindowsAdminCenter.Configuration"

if (Test-Path $modulePath) {
    Import-Module $modulePath -Force -ErrorAction SilentlyContinue

    # Bind the certificate
    Set-WACCertificateSubjectName -Thumbprint $Thumbprint -ErrorAction SilentlyContinue

    # Grant Network Service permission on the private key
    Set-WACCertificateAcl -SubjectName $WacHostname -ErrorAction SilentlyContinue
    # Fallback if SubjectName doesn't match
    Set-WACCertificateAcl -Thumbprint $Thumbprint -ErrorAction SilentlyContinue

    # Set endpoint FQDN (if available)
    if (Get-Command Set-WACEndpointFqdn -ErrorAction SilentlyContinue) {
        Set-WACEndpointFqdn -EndpointFqdn $WacHostname -ErrorAction SilentlyContinue
    }
}

# Restart the service
Restart-Service -Name WindowsAdminCenter -Force -ErrorAction SilentlyContinue
Write-Host "Windows Admin Center service restarted." -ForegroundColor Green

# --- 6. Summary ---
Write-Host "`n=============================================" -ForegroundColor Yellow
Write-Host "Installation completed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Open this URL:" -ForegroundColor Cyan
Write-Host "https://$WacHostname`:$HttpsPort" -ForegroundColor White
Write-Host ""
Write-Host "Login credentials:" -ForegroundColor Cyan
Write-Host "Username : $Username" -ForegroundColor White
Write-Host "Password : $Password" -ForegroundColor White
Write-Host ""
Write-Host "Using certificate thumbprint: $Thumbprint" -ForegroundColor Gray
Write-Host "=============================================" -ForegroundColor Yellow