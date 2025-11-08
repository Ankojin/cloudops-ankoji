# RDP Shortpath Configuration for Azure Virtual Desktop
*Comprehensive toolkit for enabling RDP Shortpath on managed networks (VPN) and public networks*

## Overview
This repository contains all the necessary scripts, documentation, and configuration guides to enable RDP Shortpath for Azure Virtual Desktop session host pools. RDP Shortpath establishes a UDP-based transport between client devices and session hosts, providing better connection reliability and more consistent latency compared to traditional TCP-based connections.

## What's Included

### 📜 Scripts
| Script | Purpose | Usage |
|--------|---------|-------|
| `Check-UDPConfiguration.ps1` | Verify current UDP and RDP Shortpath configuration | Pre-deployment assessment and ongoing monitoring |
| `Enable-RDPShortpath.ps1` | Enable RDP Shortpath listener on session hosts | Session host configuration |
| `Configure-HostPoolRDPShortpath.ps1` | Configure host pool networking settings via Azure PowerShell | Host pool configuration |
| `Configure-RDPShortpathFirewall.ps1` | Configure Windows Firewall and Azure NSG rules | Firewall and network security setup |
| `Test-RDPShortpath.ps1` | Comprehensive testing and validation | Testing and troubleshooting |

### 📚 Documentation
| Document | Purpose |
|----------|---------|
| `RDP-Shortpath-Deployment-Guide.md` | Complete step-by-step deployment guide |
| `Group-Policy-Configuration-Guide.md` | Detailed Group Policy configuration instructions |

## Quick Start Guide

### Prerequisites
- Azure Virtual Desktop environment with session host pools
- Active Directory domain (for Group Policy management)
- Administrative access to session hosts and Azure subscription
- PowerShell 5.1 or later with Azure PowerShell modules

### Step 1: Assessment
```powershell
# Check current configuration
.\Check-UDPConfiguration.ps1 -CheckType "Both" -ComputerNames @("SessionHost1", "SessionHost2") -WriteToFile
```

### Step 2: Session Host Configuration
```powershell
# Enable RDP Shortpath listener (test first with -WhatIf)
.\Enable-RDPShortpath.ps1 -ComputerNames @("SessionHost1", "SessionHost2") -ListenerPort 3390 -ConfigureUDP -EnableFirewallRule -WhatIf

# Remove -WhatIf when ready to apply
.\Enable-RDPShortpath.ps1 -ComputerNames @("SessionHost1", "SessionHost2") -ListenerPort 3390 -ConfigureUDP -EnableFirewallRule
```

### Step 3: Firewall Configuration
```powershell
# Configure Windows Firewall and Azure NSG
.\Configure-RDPShortpathFirewall.ps1 `
    -ComputerNames @("SessionHost1", "SessionHost2") `
    -SubscriptionId "your-subscription-id" `
    -ResourceGroupName "your-rg-name" `
    -NetworkSecurityGroupName "your-nsg-name" `
    -ConfigureWindowsFirewall `
    -ConfigureAzureNSG
```

### Step 4: Host Pool Configuration
Use Azure Portal (recommended) or PowerShell:
```powershell
.\Configure-HostPoolRDPShortpath.ps1 `
    -SubscriptionId "your-subscription-id" `
    -ResourceGroupName "your-rg-name" `
    -HostPoolNames @("HostPool1") `
    -ManagedNetworks "Enabled" `
    -PublicNetworksWithICESTUN "Enabled"
```

### Step 5: Testing and Validation
```powershell
# Comprehensive testing with report generation
.\Test-RDPShortpath.ps1 `
    -SessionHosts @("SessionHost1", "SessionHost2") `
    -TestNetworkConnectivity `
    -TestSTUNConnectivity `
    -GenerateReport `
    -ReportPath "RDP-Shortpath-Test-Report.html"
```

## Configuration Options

### RDP Shortpath Types Supported
1. **RDP Shortpath for managed networks** - Direct UDP connection via VPN/ExpressRoute
2. **RDP Shortpath for managed networks with ICE/STUN** - Dynamic port discovery over private networks
3. **RDP Shortpath for public networks with ICE/STUN** - Direct UDP over internet
4. **RDP Shortpath for public networks via TURN** - Relayed UDP connection through Azure TURN servers

### Default Ports
- **RDP Shortpath Listener:** 3390 (configurable)
- **STUN/TURN Port Range:** 38300-39299 (configurable)
- **Client Ephemeral Range:** 49152-65535 (fallback)

## Group Policy Configuration

For domain-joined environments, use Group Policy to centrally manage RDP Shortpath settings:

1. **Download Azure Virtual Desktop Administrative Template:**
   - https://aka.ms/avdgpo

2. **Key Policy Settings:**
   - Enable RDP Shortpath for managed networks
   - Configure UDP transport protocols
   - Set port ranges for STUN/TURN

3. **Apply to Session Hosts:**
   - Target appropriate OUs
   - Force policy updates: `gpupdate /force`

See `Group-Policy-Configuration-Guide.md` for detailed instructions.

## Network Requirements

### Managed Networks (VPN/ExpressRoute)
- Direct connectivity between client and session host
- UDP port 3390 (default) allowed through firewalls
- Network Security Group rules configured

### Public Networks
- Internet access for session hosts and clients
- Access to Microsoft STUN/TURN servers
- UDP ephemeral port range available

### Firewall Rules Required
```
Inbound:  UDP 3390 (RDP Shortpath managed)
Inbound:  UDP 38300-39299 (STUN/TURN range)
Outbound: UDP * (general outbound)
```

## Security Considerations

### Network Security
- Restrict source IP ranges for managed networks
- Use Azure Firewall for centralized filtering
- Monitor UDP traffic patterns
- Implement network segmentation

### Access Control
- Enable Conditional Access for Azure Virtual Desktop
- Use Multi-Factor Authentication
- Regular Group Policy audits
- Monitor session access logs

## Troubleshooting

### Common Issues
1. **UDP disabled in configuration**
   ```powershell
   .\Check-UDPConfiguration.ps1 -CheckType "SessionHost" -ComputerNames @("HostName")
   ```

2. **Firewall blocking connections**
   ```powershell
   Test-NetConnection -ComputerName "SessionHost1" -Port 3390
   ```

3. **STUN/TURN connectivity issues**
   ```powershell
   .\Test-RDPShortpath.ps1 -TestSTUNConnectivity
   ```

### Validation Steps
1. Check Connection Information dialog in Remote Desktop app
2. Verify transport shows "UDP" or "UDP (Private Network)"
3. Monitor connection quality and latency
4. Review generated test reports

## Monitoring and Maintenance

### Regular Checks
```powershell
# Weekly configuration validation
.\Check-UDPConfiguration.ps1 -CheckType "Both" -WriteToFile

# Monthly comprehensive testing
.\Test-RDPShortpath.ps1 -GenerateReport -ReportPath "Monthly-Report-$(Get-Date -Format 'yyyy-MM').html"
```

### Performance Monitoring
- Azure Monitor integration
- Connection quality metrics
- UDP vs TCP usage ratios
- Latency measurements

## Support and Resources

### Microsoft Documentation
- [Azure Virtual Desktop RDP Shortpath](https://docs.microsoft.com/en-us/azure/virtual-desktop/rdp-shortpath)
- [Configure RDP Shortpath](https://docs.microsoft.com/en-us/azure/virtual-desktop/configure-rdp-shortpath)
- [Network configuration requirements](https://docs.microsoft.com/en-us/azure/virtual-desktop/rdp-shortpath#network-configuration)

### Community Resources
- [Azure Virtual Desktop Tech Community](https://techcommunity.microsoft.com/t5/azure-virtual-desktop/bd-p/AzureVirtualDesktop)
- [Microsoft Q&A for Azure Virtual Desktop](https://docs.microsoft.com/en-us/answers/topics/azure-virtual-desktop.html)

### Testing Tools
- **avdnettest.exe** - Microsoft's official STUN/TURN connectivity tester
- **Test-NetConnection** - PowerShell connectivity testing
- **Connection Information dialog** - Built-in RDP connection details

## Contributing

This toolkit is designed for the BAB CloudOps team and migration projects. For improvements or issues:

1. Test changes in non-production environments
2. Document any modifications
3. Update version information
4. Follow change management procedures

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-11-03 | Initial release with full RDP Shortpath configuration toolkit |

## License

This toolkit is developed for internal use by the BAB CloudOps team for Azure Virtual Desktop migrations and configurations.

---

**Author:** BAB CloudOps Team  
**Last Updated:** November 3, 2025  
**Next Review:** December 3, 2025