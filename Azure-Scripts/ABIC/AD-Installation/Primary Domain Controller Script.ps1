# Variables
$DomainName = "abictests.com"
$NetbiosName = "abictests"
$SafeModePwd = ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force

# Install AD DS Role
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

# Promote to Domain Controller (new forest)
Install-ADDSForest `
    -DomainName $DomainName `
    -DomainNetbiosName $NetbiosName `
    -SafeModeAdministratorPassword $SafeModePwd `
    -InstallDNS `
    -Force

# The server will automatically reboot after promotion