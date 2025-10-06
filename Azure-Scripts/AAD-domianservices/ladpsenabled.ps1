$ResourceGroup = "BAB-Shared-Resources-RG01"
$DomainName    = "albtests.com"
$PfxPath       = "C:\Certs\aadds-ldaps.pfx"
$PfxPassword   = "YourPfxPassword"
$Location      = "uaenorth"

# Convert PFX to Base64
$Base64Pfx = [Convert]::ToBase64String([IO.File]::ReadAllBytes($PfxPath))

# Retry update
Update-AzADDomainService `
    -Name $DomainName `
    -ResourceGroupName $ResourceGroup `
    -Location $Location `
    -Ldaps $true `
    -LdapsCertificate $Base64Pfx `
    -LdapsCertificatePassword $PfxPassword `
    -ErrorAction Stop
