# Variables
$DomainName = "abictests.com"
$PrimaryDC = "dc01.abictests.com"   # FQDN or IP of Primary DC
$SafeModePwd = ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force
$DomainAdminCred = Get-Credential -Message "Enter domain admin credentials"  # Domain\Administrator

# Set DNS to point to primary DC
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses ("10.0.0.4") # Change as needed

# Join domain (optional before promotion)
Add-Computer -DomainName $DomainName -Credential $DomainAdminCred -Restart

# Wait until rebooted and logged back in

# Install AD DS Role
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

# Promote as Additional Domain Controller
Install-ADDSDomainController `
    -DomainName $DomainName `
    -Credential $DomainAdminCred `
    -SiteName "Default-First-Site-Name" `
    -InstallDNS `
    -SafeModeAdministratorPassword $SafeModePwd `
    -Force

# Server will reboot after promotion
