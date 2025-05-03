Connect-AzureAD

# Filter users whose UPN ends with -E.domaina.local
$users = Get-AzureADUser -All $true | Where-Object {
    $_.UserPrincipalName -like "*-E.domaina.local"
}

# Export selected fields to CSV
$users | Select-Object DisplayName, UserPrincipalName, GivenName, Surname, Mail |
    Export-Csv "FilteredUsers.csv" -NoTypeInformation
