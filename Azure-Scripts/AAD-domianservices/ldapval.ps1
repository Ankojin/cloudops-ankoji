# ===============================
# PowerShell 7 LDAPS Validation
# ===============================

# 1️⃣ Ensure Novell LDAP library is installed
$packageName = "Novell.Directory.Ldap.NETStandard"
$pkg = Get-Package -Name $packageName -ErrorAction SilentlyContinue
if (-not $pkg) {
    Install-Package -Name $packageName -Source nuget.org -Force
    $pkg = Get-Package -Name $packageName
}

# 2️⃣ Load Novell LDAP assembly
$dllPath = Join-Path $pkg.InstallLocation "lib/netstandard2.0/Novell.Directory.Ldap.dll"
if (-not (Test-Path $dllPath)) {
    Write-Host "❌ DLL not found at $dllPath"
    exit 1
}
Add-Type -Path $dllPath

# 3️⃣ Prompt for credentials
$cred = Get-Credential -Message "Enter domain credentials (ALBTESTS\Username)"

# 4️⃣ LDAP server and port
$ldapServer = "albldaps.albtests.com"
$ldapPort   = 636  # LDAPS

# 5️⃣ Create LDAPS connection
$ldap = [Novell.Directory.Ldap.LdapConnection]::new()
$ldap.SecureSocketLayer = $true

# Optional: bypass certificate validation for testing
$ldap.UserDefinedServerCertValidationDelegate = { param($sender,$cert,$chain,$sslPolicyErrors) return $true }

try {
    # 6️⃣ Connect to LDAP server
    $ldap.Connect($ldapServer, $ldapPort)
    Write-Host "✅ LDAPS connection established to {$ldapServer}:$ldapPort"

    # 7️⃣ Bind with credentials
    $username = $cred.UserName
    $password = $cred.GetNetworkCredential().Password
    $ldap.Bind($username, $password)
    Write-Host "✅ Successfully authenticated as $username"

    # 8️⃣ Perform a test search
    $baseDn = "DC=albtests,DC=com"
    $filter = "(objectClass=user)"
    $attributes = @("cn", "mail")
    $search = $ldap.Search($baseDn, [Novell.Directory.Ldap.LdapSearchScope]::Sub, $filter, $attributes, $false)

    $count = 0
    foreach ($entry in $search) {
        $count++
        Write-Host "User: $($entry.getAttribute('cn')?.StringValue)"
    }
    Write-Host "✅ Total entries retrieved: $count"
}
catch {
    Write-Host "❌ Error: $($_.Exception.Message)"
}
finally {
    # 9️⃣ Disconnect
    if ($ldap) { $ldap.Disconnect() }
    Write-Host "🔌 LDAPS connection closed"
}
