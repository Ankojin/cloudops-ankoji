# Parameters
$DaysBack = 30  # Change as needed
$DomainFilter = ".albtests.com"
$ExportPath = "C:\Reports\Users-NeverSignedInLastXDays.csv"

# Connect to Microsoft Graph with required scopes
Connect-MgGraph -Scopes "User.Read.All","AuditLog.Read.All"

# Calculate cutoff date
$CutoffDate = (Get-Date).AddDays(-$DaysBack)
$Now = Get-Date

# Get users with the matching domain
$Users = Get-MgUser -All -Filter "endswith(userPrincipalName,'$DomainFilter')" -Property "id,displayName,userPrincipalName,signInActivity"

# Filter users who either:
# - Never signed in (LastSignInDateTime is null)
# - Last sign-in was before the cutoff date
$FilteredUsers = $Users | Where-Object {
    $_.SignInActivity.LastSignInDateTime -eq $null -or
    ([datetime]$_.SignInActivity.LastSignInDateTime) -lt $CutoffDate
}

# Select relevant fields with DaysSinceLastSignIn and Stale flag
$Report = $FilteredUsers | Select-Object `
    DisplayName, 
    UserPrincipalName, 
    @{n="LastSignIn";e={ if ($_.SignInActivity.LastSignInDateTime) {[datetime]$_.SignInActivity.LastSignInDateTime} else {"Never"}}},
    @{n="DaysSinceLastSignIn";e={
        if ($_.SignInActivity.LastSignInDateTime) { 
            (New-TimeSpan -Start ([datetime]$_.SignInActivity.LastSignInDateTime) -End $Now).Days 
        } else { 
            "Never" 
        }
    }},
    @{n="Stale";e={
        if ($_.SignInActivity.LastSignInDateTime -eq $null) {
            "Yes"
        } elseif ((New-TimeSpan -Start ([datetime]$_.SignInActivity.LastSignInDateTime) -End $Now).Days -gt $DaysBack) {
            "Yes"
        } else {
            "No"
        }
    }}

# Export to CSV
$Report | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8

Write-Host "Report exported to $ExportPath"

