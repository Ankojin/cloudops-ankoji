# ===============================
# Variables
# ===============================
$ldapServer = "albldaps.albtests.com"
$domain     = "ALBTESTS"
$username   = "AnkNag-B"
$password   = Read-Host "Enter password" -AsSecureString
# ===============================

# Convert SecureString to plain text for NetworkCredential (required in .NET Core)
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
$plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

# Create NetworkCredential
$cred = New-Object System.Net.NetworkCredential($username, $plainPassword, $domain)

# Create LDAP connection
$ldap = [System.DirectoryServices.Protocols.LdapConnection]::new($ldapServer)
$ldap.SessionOptions.SecureSocketLayer = $true      # Enable LDAPS
$ldap.AuthType = [System.DirectoryServices.Protocols.AuthType]::Negotiate
$ldap.Credential = $cred

# Optional: skip certificate validation for testing (remove in production)
$ldap.SessionOptions.VerifyServerCertificate = { param($cert) $true }

# Try to bind
try {
    $ldap.Bind()
    Write-Host "✅ LDAPS bind successful for $domain\$username"
}
catch {
    Write-Host "❌ LDAPS bind failed: $($_.Exception.Message)"
}

# Optional: perform a simple search
try {
    $search = [System.DirectoryServices.Protocols.SearchRequest]::new(
        "DC=albtests,DC=com",
        "(objectClass=user)",
        [System.DirectoryServices.Protocols.SearchScope]::Subtree
    )
    $results = $ldap.SendRequest($search)
    Write-Host "✅ LDAP search returned $($results.Entries.Count) entries"
}
catch {
    Write-Host "❌ LDAP search failed: $($_.Exception.Message)"
}
