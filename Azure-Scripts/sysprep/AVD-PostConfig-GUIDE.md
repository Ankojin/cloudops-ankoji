# AVD Session Host Post-Configuration Guide

## Overview

After deploying VMs from your generalized golden image, use this script to:
1. **Join VM to Active Directory domain**
2. **Install Azure Virtual Desktop Agent**
3. **Install Azure Virtual Desktop Agent Bootloader**
4. **Register VM with AVD Host Pool**

---

## Prerequisites

1. **Azure PowerShell Modules**:
   ```powershell
   Install-Module -Name Az.Compute -Force
   Install-Module -Name Az.DesktopVirtualization -Force
   ```

2. **Azure Authentication**:
   ```powershell
   Connect-AzAccount
   ```

3. **Permissions**:
   - Contributor on VM resource group
   - Contributor on Host Pool resource group
   - Domain admin credentials for domain join

4. **VM Requirements**:
   - VM must be running
   - VM must have internet connectivity
   - VM must be able to reach domain controllers (if joining domain)

---

## Quick Start

### Step 1: Prepare Domain Credentials

```powershell
# Create secure password
$domainPassword = ConvertTo-SecureString "YourDomainAdminPassword" -AsPlainText -Force
```

### Step 2: Configure Single VM

```powershell
.\Configure-AVD-SessionHost.ps1 `
    -VMName "BABAVDSHDTA-5" `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -DomainName "bankalbilad.com.sa" `
    -DomainJoinUserName "admin@bankalbilad.com.sa" `
    -DomainJoinPassword $domainPassword `
    -HostPoolName "bab-avd-hostpool" `
    -HostPoolResourceGroup "bab-vdi-avd-weeu-rg-01" `
    -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5" `
    -Verbose
```

---

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `VMName` | Yes | Name of VM to configure |
| `ResourceGroupName` | Yes | Resource group containing the VM |
| `DomainName` | Conditional* | Active Directory domain name |
| `DomainJoinUserName` | Conditional* | Domain admin username |
| `DomainJoinPassword` | Conditional* | Secure password for domain join |
| `OUPath` | No | OU path for computer object placement |
| `HostPoolName` | Yes | AVD Host Pool name |
| `HostPoolResourceGroup` | Yes | Resource group with host pool |
| `RegistrationToken` | No | Existing token (auto-generated if not provided) |
| `SubscriptionId` | Yes | Azure subscription ID |
| `SkipDomainJoin` | No | Skip domain join step |

\* Required unless `-SkipDomainJoin` is used

---

## Usage Scenarios

### Scenario 1: Full Configuration with OU Path

```powershell
$securePassword = ConvertTo-SecureString "P@ssw0rd!" -AsPlainText -Force

.\Configure-AVD-SessionHost.ps1 `
    -VMName "BABAVDSHDTA-5" `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -DomainName "bankalbilad.com.sa" `
    -DomainJoinUserName "admin@bankalbilad.com.sa" `
    -DomainJoinPassword $securePassword `
    -OUPath "OU=AVD,OU=Servers,DC=bankalbilad,DC=com,DC=sa" `
    -HostPoolName "bab-avd-hostpool" `
    -HostPoolResourceGroup "bab-vdi-avd-weeu-rg-01" `
    -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5" `
    -Verbose
```

### Scenario 2: Using Existing Registration Token

```powershell
# Get existing token from host pool
$hostPool = Get-AzWvdHostPool -ResourceGroupName "bab-vdi-avd-weeu-rg-01" -Name "bab-avd-hostpool"
$existingToken = $hostPool.RegistrationInfo.Token

# Use existing token
.\Configure-AVD-SessionHost.ps1 `
    -VMName "BABAVDSHDTA-5" `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -DomainName "bankalbilad.com.sa" `
    -DomainJoinUserName "admin@bankalbilad.com.sa" `
    -DomainJoinPassword $securePassword `
    -HostPoolName "bab-avd-hostpool" `
    -HostPoolResourceGroup "bab-vdi-avd-weeu-rg-01" `
    -RegistrationToken $existingToken `
    -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5"
```

### Scenario 3: VM Already Domain-Joined

```powershell
# Skip domain join, only install agents
.\Configure-AVD-SessionHost.ps1 `
    -VMName "BABAVDSHDTA-5" `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -HostPoolName "bab-avd-hostpool" `
    -HostPoolResourceGroup "bab-vdi-avd-weeu-rg-01" `
    -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5" `
    -SkipDomainJoin `
    -Verbose
```

### Scenario 4: Configure Multiple VMs (Batch)

```powershell
$securePassword = ConvertTo-SecureString "P@ssw0rd!" -AsPlainText -Force
$vmsToConfig = @("BABAVDSHDTA-5", "BABAVDSHDTA-6", "BABAVDSHDTA-7")

# Generate token once (valid for 24 hours)
$tokenExpiry = (Get-Date).AddHours(24).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
$token = (New-AzWvdRegistrationInfo `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -HostPoolName "bab-avd-hostpool" `
    -ExpirationTime $tokenExpiry).Token

# Configure each VM
foreach ($vm in $vmsToConfig) {
    Write-Host "Configuring $vm..." -ForegroundColor Cyan
    
    .\Configure-AVD-SessionHost.ps1 `
        -VMName $vm `
        -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
        -DomainName "bankalbilad.com.sa" `
        -DomainJoinUserName "admin@bankalbilad.com.sa" `
        -DomainJoinPassword $securePassword `
        -HostPoolName "bab-avd-hostpool" `
        -HostPoolResourceGroup "bab-vdi-avd-weeu-rg-01" `
        -RegistrationToken $token `
        -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5" `
        -Verbose
    
    Write-Host "✅ $vm configured successfully" -ForegroundColor Green
    Write-Host ""
}
```

---

## What the Script Does

### Phase 1: Domain Join
- Checks if VM is already domain-joined
- Joins VM to specified domain
- Places computer object in specified OU (if provided)
- Restarts VM if needed to complete domain join

### Phase 2: Registration Token
- Uses provided token OR generates new 24-hour token
- Validates token is not empty

### Phase 3: AVD Agent Installation
- Downloads latest AVD Agent installer
- Downloads latest AVD Agent Bootloader
- Installs both with registration token
- Verifies RDAgentBootLoader service is running

### Phase 4: Verification
- Checks if session host appears in host pool
- Displays registration status

---

## AVD Agent Download URLs

The script uses official Microsoft download URLs (as of April 2026):

| Component | URL |
|-----------|-----|
| AVD Agent | https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv |
| AVD Bootloader | https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH |

**Note**: These URLs may change. Microsoft maintains these redirects to always point to the latest version.

---

## Troubleshooting

### Issue: Domain join fails

**Check**:
1. Verify domain credentials are correct
2. Ensure VM can reach domain controllers:
   ```powershell
   # Test from VM
   Test-Connection -ComputerName "bankalbilad.com.sa" -Count 2
   nltest /dsgetdc:bankalbilad.com.sa
   ```
3. Check DNS settings on VM NIC
4. Verify NSG allows Active Directory traffic (if any NSG attached)

### Issue: Agent installation fails

**Check**:
1. VM has internet connectivity
2. Review installation logs in VM: `C:\Temp\AVDAgents\AgentInstall.log`
3. Ensure VM is not already registered to another host pool
4. Verify registration token is not expired

**Manual verification**:
```powershell
# Connect to VM and check
Get-Service -Name "RDAgentBootLoader"
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\RDInfraAgent" -ErrorAction SilentlyContinue
```

### Issue: Session host not appearing in host pool

**Wait and check**:
- Allow 5-10 minutes for registration to complete
- Check Azure Portal → AVD → Host Pools → Session Hosts
- Verify RDAgentBootLoader service is running on VM
- Check VM event logs: Applications and Services Logs → Microsoft → Windows → TerminalServices-RdpStack-RdmsPlugin

### Issue: Registration token expired

**Generate new token**:
```powershell
$tokenExpiry = (Get-Date).AddHours(24).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
$newToken = New-AzWvdRegistrationInfo `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -HostPoolName "bab-avd-hostpool" `
    -ExpirationTime $tokenExpiry
$newToken.Token
```

---

## Verification Steps

### 1. Check Domain Join
```powershell
# On the VM
Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object Name, Domain, PartOfDomain
```

### 2. Check AVD Services
```powershell
# On the VM
Get-Service -Name "RDAgentBootLoader", "RDAgent"
```

### 3. Check Host Pool Registration
```powershell
# From Azure PowerShell
Get-AzWvdSessionHost `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -HostPoolName "bab-avd-hostpool" |
    Where-Object { $_.Name -like "*BABAVDSHDTA-5*" }
```

### 4. Check Session Host Status in Portal
1. Navigate to Azure Portal
2. Go to Azure Virtual Desktop
3. Select Host Pools → Your Host Pool
4. Click Session Hosts
5. Verify your VM appears with "Available" status

---

## Log Files

The script creates detailed logs in `.\logs\`:
- `AVD-PostConfig-YYYYMMDD.log` - Main log file
- `AVD-PostConfig-Transcript-YYYYMMDD-HHMMSS.log` - Full transcript

On the VM:
- `C:\Temp\AVDAgents\AgentInstall.log` - Agent installation log
- `C:\Temp\AVDAgents\BootloaderInstall.log` - Bootloader installation log

---

## Complete Workflow: Image to Production

### 1. Create Golden Image
```powershell
# Use Clone-And-Generalize-AVD.ps1
.\Clone-And-Generalize-AVD.ps1 -SourceVMName "BABAVDSHDTA-1" ...
```

### 2. Deploy VMs from Image
```powershell
# Via Azure Portal or ARM template
# Deploy new VMs from Shared Image Gallery image
```

### 3. Configure Session Hosts
```powershell
# Use Configure-AVD-SessionHost.ps1
.\Configure-AVD-SessionHost.ps1 -VMName "BABAVDSHDTA-5" ...
```

### 4. Verify and Test
```powershell
# Check session hosts
Get-AzWvdSessionHost -ResourceGroupName "..." -HostPoolName "..."

# Test user login
# Connect via AVD client and verify user can log in
```

---

## Best Practices

1. ✅ **Generate one registration token for batch deployments** (valid 24 hours)
2. ✅ **Use service accounts for domain join** (not personal admin accounts)
3. ✅ **Specify OU path** for better organizational control
4. ✅ **Run during maintenance window** (VM restarts may be required)
5. ✅ **Verify each VM** before moving to next in batch deployments
6. ✅ **Keep domain credentials secure** (use Azure Key Vault or secure storage)
7. ✅ **Monitor logs** for any errors during batch operations
8. ⚠️ **Don't hardcode passwords** in scripts
9. ⚠️ **Test on single VM** before batch deployment

---

## Security Considerations

### Credential Handling
```powershell
# ✅ Good - Use secure string
$securePassword = Read-Host "Enter domain password" -AsSecureString

# ✅ Better - Retrieve from Key Vault
$secret = Get-AzKeyVaultSecret -VaultName "YourVault" -Name "DomainAdminPassword"
$securePassword = $secret.SecureStringValue

# ❌ Bad - Plain text password
$password = "P@ssw0rd!"
```

### Registration Token
- Generate just before use
- Don't store in version control
- Expires in 24 hours by default
- Regenerate if compromised

---

## Reference Links

- [AVD Agent Documentation](https://learn.microsoft.com/azure/virtual-desktop/agent-overview)
- [Troubleshoot AVD Agent Issues](https://learn.microsoft.com/azure/virtual-desktop/troubleshoot-agent)
- [Domain Join VMs](https://learn.microsoft.com/azure/active-directory-domain-services/join-windows-vm)

---

**Author**: BAB CloudOps Team  
**Last Updated**: April 2026  
**Version**: 1.0
