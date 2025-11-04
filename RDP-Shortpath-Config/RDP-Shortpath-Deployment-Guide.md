# RDP Shortpath Configuration Deployment Guide
## Azure Virtual Desktop - Managed Networks (VPN) and Public Networks

### Executive Summary
This guide provides comprehensive step-by-step instructions for enabling RDP Shortpath on Azure Virtual Desktop session host pools, supporting both managed networks (VPN connections) and public networks with STUN/TURN relay.

RDP Shortpath establishes a UDP-based transport between client devices and session hosts, offering:
- **Better connection reliability**
- **More consistent latency**
- **Improved user experience**
- **Reduced bandwidth consumption**

---

## Prerequisites

### Environment Requirements
- ✅ Azure Virtual Desktop environment with session host pools
- ✅ Active Directory domain (for Group Policy management)
- ✅ Administrative access to session hosts
- ✅ Azure subscription with appropriate permissions
- ✅ VPN or ExpressRoute connectivity (for managed networks)

### Client Requirements
- ✅ Windows App or Remote Desktop app version 1.2.3488 or later
- ✅ Supported platforms: Windows, macOS, iOS/iPadOS, Android/Chrome OS

### Network Requirements
- ✅ **Managed Networks**: Direct connectivity between client and session host on port 3390 (default)
- ✅ **Public Networks**: Internet access for STUN/TURN servers
- ✅ Firewall rules allowing UDP traffic on configured ports

### Tools and Permissions
- ✅ PowerShell 5.1 or later
- ✅ Azure PowerShell module (Az.DesktopVirtualization)
- ✅ Group Policy Management Console
- ✅ Domain Administrator or Group Policy management permissions
- ✅ Azure Contributor or equivalent permissions

---

## Phase 1: Pre-Deployment Assessment

### Step 1.1: Inventory Assessment
Run the following command to assess your current environment:

```powershell
# Navigate to the RDP-Shortpath-Config directory
cd "c:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\RDP-Shortpath-Config"

# Check current UDP configuration on session hosts
.\Check-UDPConfiguration.ps1 -CheckType "Both" -ComputerNames @("SessionHost1", "SessionHost2") -WriteToFile

# Test current connectivity (if session hosts are available)
.\Test-RDPShortpath.ps1 -SessionHosts @("SessionHost1", "SessionHost2") -GenerateReport -ReportPath "Pre-Deployment-Assessment.html"
```

### Step 1.2: Documentation Review
- 📋 Document current session host inventory
- 📋 Identify client computers that will connect via VPN
- 📋 Review network topology and firewall configurations
- 📋 Plan maintenance windows for session host restarts

---

## Phase 2: Azure Virtual Desktop Administrative Template Setup

### Step 2.1: Download Administrative Template
1. **Download the template:**
   ```powershell
   # Download Azure Virtual Desktop administrative template
   $templateUrl = "https://aka.ms/avdgpo"
   Invoke-WebRequest -Uri $templateUrl -OutFile "$env:TEMP\avd-template.zip"
   Expand-Archive -Path "$env:TEMP\avd-template.zip" -DestinationPath "$env:TEMP\avd-template"
   ```

2. **Install the template:**
   ```powershell
   # Copy to PolicyDefinitions (requires admin rights)
   Copy-Item "$env:TEMP\avd-template\avd.admx" -Destination "$env:SYSTEMROOT\PolicyDefinitions\"
   Copy-Item "$env:TEMP\avd-template\avd.adml" -Destination "$env:SYSTEMROOT\PolicyDefinitions\en-US\"
   
   # Or copy to Central Store if using one
   # Copy-Item "$env:TEMP\avd-template\avd.admx" -Destination "\\domain.com\SYSVOL\domain.com\Policies\PolicyDefinitions\"
   # Copy-Item "$env:TEMP\avd-template\avd.adml" -Destination "\\domain.com\SYSVOL\domain.com\Policies\PolicyDefinitions\en-US\"
   ```

---

## Phase 3: Group Policy Configuration

### Step 3.1: Create Group Policy Object
1. **Open Group Policy Management Console:**
   ```
   Start → Run → gpmc.msc
   ```

2. **Create new GPO:**
   - Right-click the OU containing session hosts
   - Select "Create a GPO in this domain, and Link it here"
   - Name: `Azure Virtual Desktop - RDP Shortpath Configuration`
   - Right-click the new GPO → Edit

### Step 3.2: Configure RDP Shortpath for Managed Networks
Navigate to:
```
Computer Configuration 
→ Policies 
→ Administrative Templates 
→ Windows Components 
→ Remote Desktop Services 
→ Remote Desktop Session Host 
→ Azure Virtual Desktop
```

**Configure these settings:**

1. **Enable RDP Shortpath for managed networks:**
   - Setting: `Enabled`
   - Port: `3390` (or custom port)

2. **Use port range for RDP Shortpath for unmanaged networks:**
   - Setting: `Enabled`
   - UDP base port: `38300`
   - Port pool size: `1000`

### Step 3.3: Configure UDP Transport
Navigate to:
```
Computer Configuration 
→ Policies 
→ Administrative Templates 
→ Windows Components 
→ Remote Desktop Services 
→ Remote Desktop Session Host 
→ Connections
```

**Configure this setting:**
- **Select RDP transport protocols:**
  - Setting: `Enabled`
  - Transport Type: `Use both UDP and TCP`

### Step 3.4: Configure Client-Side Settings
Navigate to:
```
Computer Configuration 
→ Policies 
→ Administrative Templates 
→ Windows Components 
→ Remote Desktop Services 
→ Remote Desktop Connection Client
```

**Configure this setting:**
- **Turn Off UDP On Client:**
  - Setting: `Disabled` or `Not Configured`

### Step 3.5: Apply Group Policy
```powershell
# Force Group Policy update on session hosts
.\Enable-RDPShortpath.ps1 -ComputerNames @("SessionHost1", "SessionHost2") -ListenerPort 3390 -ConfigureUDP -WhatIf

# After review, run without -WhatIf
.\Enable-RDPShortpath.ps1 -ComputerNames @("SessionHost1", "SessionHost2") -ListenerPort 3390 -ConfigureUDP
```

---

## Phase 4: Firewall Configuration

### Step 4.1: Configure Windows Firewall on Session Hosts
```powershell
# Configure Windows Firewall rules
.\Configure-RDPShortpathFirewall.ps1 `
    -ComputerNames @("SessionHost1", "SessionHost2") `
    -RDPShortpathPort 3390 `
    -STUNPortRangeStart 38300 `
    -STUNPortRangeEnd 39299 `
    -ConfigureWindowsFirewall `
    -WhatIf

# After review, run without -WhatIf
.\Configure-RDPShortpathFirewall.ps1 `
    -ComputerNames @("SessionHost1", "SessionHost2") `
    -RDPShortpathPort 3390 `
    -STUNPortRangeStart 38300 `
    -STUNPortRangeEnd 39299 `
    -ConfigureWindowsFirewall
```

### Step 4.2: Configure Azure Network Security Groups
```powershell
# Configure Azure NSG rules
.\Configure-RDPShortpathFirewall.ps1 `
    -SubscriptionId "your-subscription-id" `
    -ResourceGroupName "your-rg-name" `
    -NetworkSecurityGroupName "your-nsg-name" `
    -RDPShortpathPort 3390 `
    -STUNPortRangeStart 38300 `
    -STUNPortRangeEnd 39299 `
    -ConfigureAzureNSG `
    -AllowedSourceIPs @("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16") `
    -WhatIf

# After review, run without -WhatIf
.\Configure-RDPShortpathFirewall.ps1 `
    -SubscriptionId "your-subscription-id" `
    -ResourceGroupName "your-rg-name" `
    -NetworkSecurityGroupName "your-nsg-name" `
    -RDPShortpathPort 3390 `
    -STUNPortRangeStart 38300 `
    -STUNPortRangeEnd 39299 `
    -ConfigureAzureNSG `
    -AllowedSourceIPs @("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
```

---

## Phase 5: Host Pool Configuration

### Step 5.1: Configure Host Pool Networking Settings

**Option A: Azure Portal Method**
1. Sign in to the [Azure portal](https://portal.azure.com/)
2. Navigate to Azure Virtual Desktop → Host pools
3. Select your host pool
4. Go to Settings → Networking → RDP Shortpath
5. Configure the following settings:
   - **RDP Shortpath for managed networks:** `Enabled`
   - **RDP Shortpath for managed networks with ICE/STUN:** `Enabled`
   - **RDP Shortpath for public networks with ICE/STUN:** `Enabled`
   - **RDP Shortpath for public networks via TURN:** `Enabled`
6. Click Save

**Option B: PowerShell Method**
```powershell
# Configure host pool settings
.\Configure-HostPoolRDPShortpath.ps1 `
    -SubscriptionId "your-subscription-id" `
    -ResourceGroupName "your-rg-name" `
    -HostPoolNames @("HostPool1", "HostPool2") `
    -ManagedNetworks "Enabled" `
    -ManagedNetworksWithICESTUN "Enabled" `
    -PublicNetworksWithICESTUN "Enabled" `
    -PublicNetworksWithTURN "Enabled" `
    -WhatIf

# After review, run without -WhatIf
.\Configure-HostPoolRDPShortpath.ps1 `
    -SubscriptionId "your-subscription-id" `
    -ResourceGroupName "your-rg-name" `
    -HostPoolNames @("HostPool1", "HostPool2") `
    -ManagedNetworks "Enabled" `
    -ManagedNetworksWithICESTUN "Enabled" `
    -PublicNetworksWithICESTUN "Enabled" `
    -PublicNetworksWithTURN "Enabled"
```

---

## Phase 6: Session Host Restart and Validation

### Step 6.1: Restart Session Hosts
```powershell
# Schedule restart during maintenance window
$sessionHosts = @("SessionHost1", "SessionHost2")

foreach ($host in $sessionHosts) {
    Write-Host "Restarting $host..." -ForegroundColor Yellow
    Restart-Computer -ComputerName $host -Force -Wait
    Write-Host "$host restarted successfully" -ForegroundColor Green
}
```

### Step 6.2: Validate Configuration
```powershell
# Validate configuration after restart
.\Check-UDPConfiguration.ps1 -CheckType "SessionHost" -ComputerNames $sessionHosts -WriteToFile
```

---

## Phase 7: Testing and Validation

### Step 7.1: Comprehensive Testing
```powershell
# Run comprehensive tests
.\Test-RDPShortpath.ps1 `
    -SessionHosts @("SessionHost1", "SessionHost2") `
    -ClientComputers @("ClientPC1", "ClientPC2") `
    -RDPShortpathPort 3390 `
    -HostPoolResourceGroup "your-rg-name" `
    -HostPoolName "HostPool1" `
    -SubscriptionId "your-subscription-id" `
    -TestNetworkConnectivity `
    -TestSTUNConnectivity `
    -GenerateReport `
    -ReportPath "Post-Deployment-Test-Report.html"
```

### Step 7.2: Client Connection Testing
1. **Connect from VPN client:**
   - Open Windows App or Remote Desktop app
   - Connect to session host
   - Check Connection Information dialog (signal strength icon)
   - Verify transport shows "UDP (Private Network)"

2. **Connect from public network:**
   - Connect without VPN
   - Check Connection Information dialog
   - Verify transport shows "UDP" or "UDP (Relay)"

### Step 7.3: Monitor Connection Quality
```powershell
# Enable Teredo for better connectivity (optional)
Set-NetTeredoConfiguration -Type Enterpriseclient

# Test STUN connectivity
$avdTestPath = "$env:TEMP\avdnettest.exe"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Azure/RDS-Templates/master/AVD-TestShortpath/avdnettest.exe" -OutFile $avdTestPath
& $avdTestPath
```

---

## Phase 8: Monitoring and Maintenance

### Step 8.1: Configure Monitoring
1. **Enable Azure Monitor:**
   - Configure Log Analytics workspace
   - Enable diagnostic settings for host pools
   - Set up connection quality alerts

2. **Monitor Key Metrics:**
   - Connection success rates
   - Latency measurements
   - UDP vs TCP connection ratios
   - STUN/TURN usage patterns

### Step 8.2: Ongoing Maintenance Tasks
```powershell
# Weekly configuration check
.\Check-UDPConfiguration.ps1 -CheckType "Both" -ComputerNames $sessionHosts -WriteToFile

# Monthly comprehensive test
.\Test-RDPShortpath.ps1 `
    -SessionHosts $sessionHosts `
    -TestNetworkConnectivity `
    -TestSTUNConnectivity `
    -GenerateReport `
    -ReportPath "Monthly-Health-Check-$(Get-Date -Format 'yyyy-MM-dd').html"
```

---

## Troubleshooting Guide

### Common Issues and Solutions

#### 1. RDP Shortpath Not Working
**Symptoms:**
- Connection Information shows "TCP" instead of "UDP"
- Poor connection quality over VPN

**Solutions:**
```powershell
# Check session host configuration
.\Check-UDPConfiguration.ps1 -CheckType "SessionHost" -ComputerNames @("SessionHost1")

# Verify firewall rules
Get-NetFirewallRule | Where-Object { $_.DisplayName -like "*RDP Shortpath*" }

# Check Group Policy application
gpresult /r /scope computer
```

#### 2. Firewall Blocking Connections
**Symptoms:**
- Network connectivity tests fail
- Connection timeouts

**Solutions:**
```powershell
# Test specific ports
Test-NetConnection -ComputerName "SessionHost1" -Port 3390

# Verify NSG rules in Azure portal
# Check Windows Firewall logs
```

#### 3. STUN/TURN Connectivity Issues
**Symptoms:**
- avdnettest.exe shows failures
- Public network connections fall back to TCP

**Solutions:**
```powershell
# Test STUN connectivity
.\Test-RDPShortpath.ps1 -ClientComputers @("ClientPC1") -TestSTUNConnectivity

# Check NAT type and configuration
# Review corporate firewall settings
```

#### 4. Client UDP Disabled
**Symptoms:**
- Client shows UDP disabled in tests
- All connections use TCP

**Solutions:**
```powershell
# Check client configuration
.\Check-UDPConfiguration.ps1 -CheckType "Client" -ComputerNames @("ClientPC1")

# Update Group Policy for clients
gpupdate /force
```

---

## Security Considerations

### Network Security
- ✅ Restrict source IP ranges in NSG rules for managed networks
- ✅ Use Azure Firewall for centralized traffic filtering
- ✅ Monitor UDP traffic patterns for anomalies
- ✅ Implement network segmentation for session hosts

### Access Control
- ✅ Use Conditional Access policies for Azure Virtual Desktop
- ✅ Enable MFA for administrative accounts
- ✅ Regularly review and audit Group Policy settings
- ✅ Monitor session host access logs

### Data Protection
- ✅ Ensure encryption in transit for all connections
- ✅ Configure appropriate session timeouts
- ✅ Implement data loss prevention policies
- ✅ Regular security assessments and penetration testing

---

## Performance Optimization

### Network Optimization
```powershell
# Configure optimal port ranges
.\Configure-RDPShortpathFirewall.ps1 `
    -STUNPortRangeStart 38300 `
    -STUNPortRangeEnd 38399  # Smaller range for better management

# Enable Teredo for IPv4 networks
Set-NetTeredoConfiguration -Type Enterpriseclient
```

### Session Host Optimization
- Configure appropriate VM sizes for workload
- Optimize network interface settings
- Regular Windows Updates and driver updates
- Monitor CPU and memory usage patterns

### Client Optimization
- Use latest Remote Desktop app versions
- Configure optimal display settings
- Test different network paths (VPN vs direct)
- Monitor client-side network performance

---

## Compliance and Documentation

### Documentation Requirements
- 📋 Network topology diagrams
- 📋 Firewall rule documentation
- 📋 Group Policy settings inventory
- 📋 Change management procedures

### Compliance Considerations
- ✅ Data residency requirements
- ✅ Industry-specific compliance (HIPAA, SOX, etc.)
- ✅ Audit trail maintenance
- ✅ Regular compliance assessments

### Backup and Recovery
- ✅ Group Policy backup procedures
- ✅ Configuration documentation
- ✅ Disaster recovery testing
- ✅ Rollback procedures

---

## Conclusion

This deployment guide provides a comprehensive approach to implementing RDP Shortpath for Azure Virtual Desktop environments. The configuration supports both managed networks (VPN) and public networks, ensuring optimal connectivity for all user scenarios.

### Key Success Factors:
1. **Thorough planning** and pre-deployment assessment
2. **Systematic implementation** following the phased approach
3. **Comprehensive testing** and validation
4. **Ongoing monitoring** and maintenance
5. **Regular security reviews** and updates

### Next Steps:
1. Execute the deployment plan in a test environment
2. Conduct user acceptance testing
3. Plan production rollout with appropriate change management
4. Establish monitoring and maintenance procedures
5. Train support staff on troubleshooting procedures

For additional support and resources, refer to:
- [Microsoft Azure Virtual Desktop Documentation](https://docs.microsoft.com/en-us/azure/virtual-desktop/)
- [RDP Shortpath Technical Documentation](https://docs.microsoft.com/en-us/azure/virtual-desktop/rdp-shortpath)
- [Azure Virtual Desktop Community Forums](https://techcommunity.microsoft.com/t5/azure-virtual-desktop/bd-p/AzureVirtualDesktop)

---

**Document Version:** 1.0  
**Last Updated:** November 3, 2025  
**Author:** BAB CloudOps Team  
**Review Date:** December 3, 2025