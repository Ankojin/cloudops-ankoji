# Run as Administrator

# === Settings ===
$RootCAName = "ABICtests CA"
$RootCAValidityYears = 10
$ExportPath = "C:\PKI\Export"
$RequestPath = "C:\PKI\SubCA.req"
$SignedCert = "$ExportPath\SubCA.crt"
$RootCertOut = "$ExportPath\RootCA.crt"
$CRLOutput = "$ExportPath\RootCA.crl"
$CACommonName = "CN=$RootCAName, O=abictests, C=com"

# Create output folder
New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null

Write-Host "`n=== Installing Standalone Root CA ===" -ForegroundColor Cyan
Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools

Install-AdcsCertificationAuthority `
    -CAType StandaloneRootCA `
    -CACommonName $RootCAName `
    -KeyLength 4096 `
    -HashAlgorithmName SHA256 `
    -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" `
    -ValidityPeriod Years `
    -ValidityPeriodUnits $RootCAValidityYears `
    -Force

# ========== Set CRL and AIA ==========
Write-Host "`n=== Configuring CRL and AIA URLs ===" -ForegroundColor Cyan

$CRLPath = "file://%SystemRoot%\system32\CertSrv\CertEnroll\%c%8%9.crl"
$HTTPCRL = "http://abictestspki.abictests.com/CertEnroll/%c%8%9.crl"
$HTTPCRT = "http://abictestspki.abictests.com/CertEnroll/%c%8%9.crt"

certutil -setreg CA\CRLPublicationURLs "$CRLPath\n$HTTPCRL"
certutil -setreg CA\CACertPublicationURLs "$CRLPath\n$HTTPCRT"

Restart-Service CertSvc

# ========== Sign SubCA Request ==========
Write-Host "`n=== Signing Subordinate CA Request ===" -ForegroundColor Cyan

if (Test-Path $RequestPath) {
    certreq -submit -attrib "CertificateTemplate:SubCA" $RequestPath $SignedCert
    Write-Host "✔️ Subordinate CA certificate signed and saved to $SignedCert" -ForegroundColor Green
} else {
    Write-Warning "SubCA.req not found. Please copy request to $RequestPath before running this section."
}

# ========== Export Root CA Certificate ==========
Write-Host "`n=== Exporting Root CA Certificate ===" -ForegroundColor Cyan
certutil -ca.cert $RootCertOut
Write-Host "✔️ Root certificate exported to $RootCertOut" -ForegroundColor Green

# ========== Publish CRL and Export ==========
Write-Host "`n=== Publishing CRL ===" -ForegroundColor Cyan
certutil -crl
Copy-Item "C:\Windows\System32\CertSrv\CertEnroll\*.crl" -Destination $ExportPath -Force
Write-Host "✔️ CRL copied to $ExportPath" -ForegroundColor Green

# ========== Summary ==========
Write-Host "`n✅ Root CA setup complete." -ForegroundColor Green
Write-Host "➡️ Copy the following files to the Issuing CA or PKI web server:" -ForegroundColor Yellow
Write-Host "   - $RootCertOut"
Write-Host "   - $SignedCert"
Write-Host "   - $CRLOutput"
