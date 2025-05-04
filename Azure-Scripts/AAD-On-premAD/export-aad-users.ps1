# Connect to Azure AD
# Connect-AzureAD
# Filter users whose UPN ends with -E@albtests.com
$users = Get-AzureADUser -All $true | Where-Object {
    $_.UserPrincipalName -match ".*-E@albtests\.com$"
}

# Export selected fields to CSV
$exportPath = "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\Azure-Scripts\FilteredUsers.csv"
$exportDir = Split-Path $exportPath -Parent
if (-not (Test-Path $exportDir)) {
    New-Item -ItemType Directory -Path $exportDir -Force
}

$users | Select-Object DisplayName, UserPrincipalName, GivenName, Surname, Mail |
    Export-Csv -Path $exportPath -NoTypeInformation

