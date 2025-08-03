# Run as Administrator

# === Settings ===
$SubCAName = "ABICtests Issuing CA"
$WebRoot = "C:\inetpub\wwwroot"
$CertEnrollPath = "C:\Windows\System32\CertSrv\CertEnroll"
$PKIFQDN = "abictestspki.abictests.com"

Write-Host "`n=== Installing Certificate Services Role ===" -ForegroundColor Cyan
Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools
Install-AdcsCertificationAuthority `
    -CAType EnterpriseSubordinateCA `
    -CACommonName $SubCAName `
    -KeyLength 2048 `
    -HashAlgorithmName SHA256 `
    -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" `
    -ValidityPeriod Years `
    -ValidityPeriodUnits 2 `
    -Force

# ========== CRL and AIA Configuration ==========
Write-Host "`n=== Configuring CRL and AIA URLs ===" -ForegroundColor Cyan

$crlUrl = "http://$PKIFQDN/CertEnroll/%c%8%9.crl"
$crtUrl = "http://$PKIFQDN/CertEnroll/%c%8%9.crt"

certutil -setreg CA\CRLPublicationURLs "$crlUrl"
certutil -setreg CA\CACertPublicationURLs "$crtUrl"
Restart-Service CertSvc

# ========== Web Enrollment ==========
Write-Host "`n=== Installing Web Enrollment and IIS ===" -ForegroundColor Cyan
Install-WindowsFeature ADCS-Web-Enrollment, Web-WebServer, Web-Asp-Net45 -IncludeManagementTools
Install-AdcsWebEnrollment -Force

# ========== OCSP Configuration ==========
Write-Host "`n=== Installing OCSP Responder ===" -ForegroundColor Cyan
Install-WindowsFeature ADCS-Online-Cert -IncludeManagementTools
Install-AdcsOnlineResponder -Force

# NOTE: OCSP revocation configuration still requires manual steps via MMC

# ========== CertEnroll Virtual Directory ==========
Write-Host "`n=== Configuring CertEnroll Virtual Directory ===" -ForegroundColor Cyan
Import-Module WebAdministration

New-WebVirtualDirectory -Site "Default Web Site" -Name "CertEnroll" -PhysicalPath $CertEnrollPath -Force

# ========== Deploy Landing Page ==========
Write-Host "`n=== Deploying PKI Landing Page ===" -ForegroundColor Cyan
$LandingPage = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Contoso PKI Portal</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            background-color: #f2f6fc;
            color: #333;
            margin: 2em auto;
            max-width: 800px;
            padding: 20px;
            border-radius: 10px;
            background: white;
            box-shadow: 0 0 15px rgba(0,0,0,0.1);
        }

        h1 {
            color: #1a4f7c;
            text-align: center;
        }

        ul {
            list-style: none;
            padding: 0;
        }

        li {
            margin: 10px 0;
        }

        a {
            color: #0066cc;
            text-decoration: none;
        }

        a:hover {
            text-decoration: underline;
        }

        .footer {
            margin-top: 40px;
            font-size: 0.9em;
            text-align: center;
            color: #777;
        }
    </style>
</head>
<body>

    <h1>Contoso PKI Services</h1>

    <p>Welcome to the Contoso internal Public Key Infrastructure (PKI) portal. Use the links below to access certificate services:</p>

    <ul>
        <li><a href="http://$PKIFQDN/certsrv/">📜 Web Enrollment Portal</a></li>
        <li><a href="http://$PKIFQDN/CertEnroll/Contoso%20Root%20CA.crt">🔐 Download Root CA Certificate</a></li>
        <li><a href="http://$PKIFQDN/CertEnroll/Contoso%20Issuing%20CA.crt">🔐 Download Issuing CA Certificate</a></li>
        <li><a href="http://$PKIFQDN/CertEnroll/Contoso%20Root%20CA.crl">❌ Download Root CA CRL</a></li>
        <li><a href="http://$PKIFQDN/CertEnroll/Contoso%20Issuing%20CA.crl">❌ Download Issuing CA CRL</a></li>
        <li><a href="http://$PKIFQDN/ocsp">🔍 OCSP Responder Status</a></li>
    </ul>

    <div class="footer">
        &copy; 2025 Contoso PKI Team – Internal Use Only
    </div>

</body>
</html>
"@

$LandingPage | Set-Content -Path "$WebRoot\index.html" -Encoding UTF8

# ========== Enable Certificate Templates ==========
Write-Host "`n=== Enabling Certificate Templates ===" -ForegroundColor Cyan
$Templates = @("User", "Computer", "WebServer")

foreach ($template in $Templates) {
    certutil -setcatemplates +$template
}

# ========== Enable Auto-Enrollment via GPO ==========
Write-Host "`n=== Configuring Auto-Enrollment GPO Settings ===" -ForegroundColor Cyan

$RegPath = "HKLM:\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment"
New-Item -Path $RegPath -Force | Out-Null
Set-ItemProperty -Path $RegPath -Name AEPolicy -Type DWord -Value 7

gpupdate /force

Write-Host "`n✅ Issuing CA setup complete. Visit http://$PKIFQDN to test Web UI." -ForegroundColor Green
