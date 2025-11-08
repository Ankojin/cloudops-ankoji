# Group Policy Configuration Guide for RDP Shortpath
## Azure Virtual Desktop - Managed Networks Configuration

### Overview
This guide provides step-by-step instructions for configuring Group Policy settings to enable RDP Shortpath for managed networks (VPN connections) in Azure Virtual Desktop environments.

### Prerequisites
- Active Directory domain environment
- Group Policy Management Console (GPMC) installed
- Azure Virtual Desktop Administrative Template downloaded and installed
- Domain Administrator or Group Policy management permissions

### Step 1: Download and Install Azure Virtual Desktop Administrative Template

1. **Download the Administrative Template:**
   - Navigate to: https://aka.ms/avdgpo
   - Download the latest Azure Virtual Desktop administrative template (avd.admx and avd.adml files)

2. **Install the Administrative Template:**
   - Copy `avd.admx` to `%SYSTEMROOT%\PolicyDefinitions\`
   - Copy `avd.adml` to `%SYSTEMROOT%\PolicyDefinitions\en-US\` (or appropriate language folder)
   - Alternatively, copy to the Central Store if using one: `\\domain.com\SYSVOL\domain.com\Policies\PolicyDefinitions\`

### Step 2: Create or Edit Group Policy Object

1. **Open Group Policy Management Console (GPMC)**
   ```
   Start → Run → gpmc.msc
   ```

2. **Create New GPO or Edit Existing:**
   - Right-click on the appropriate OU containing your session hosts
   - Select "Create a GPO in this domain, and Link it here"
   - Name it: "Azure Virtual Desktop - RDP Shortpath Configuration"
   - Right-click the new GPO and select "Edit"

### Step 3: Configure RDP Shortpath for Managed Networks

1. **Navigate to Azure Virtual Desktop Settings:**
   ```
   Computer Configuration 
   → Policies 
   → Administrative Templates 
   → Windows Components 
   → Remote Desktop Services 
   → Remote Desktop Session Host 
   → Azure Virtual Desktop
   ```

2. **Enable RDP Shortpath for Managed Networks:**
   - Double-click "Enable RDP Shortpath for managed networks"
   - Select "Enabled"
   - Configure the port number (default: 3390)
   - Click "OK"

### Step 4: Configure UDP Transport Settings

1. **Navigate to RDP Transport Settings:**
   ```
   Computer Configuration 
   → Policies 
   → Administrative Templates 
   → Windows Components 
   → Remote Desktop Services 
   → Remote Desktop Session Host 
   → Connections
   ```

2. **Configure Transport Protocol:**
   - Double-click "Select RDP transport protocols"
   - Select "Enabled"
   - For "Select Transport Type," choose "Use both UDP and TCP"
   - Click "OK"

### Step 5: Configure Windows Firewall Rules

1. **Navigate to Windows Firewall Settings:**
   ```
   Computer Configuration 
   → Policies 
   → Windows Settings 
   → Security Settings 
   → Windows Defender Firewall with Advanced Security 
   → Windows Defender Firewall with Advanced Security 
   → Inbound Rules
   ```

2. **Create New Inbound Rule:**
   - Right-click "Inbound Rules" → "New Rule"
   - Rule Type: "Port"
   - Protocol: "UDP"
   - Specific Local Ports: "3390" (or your custom port)
   - Action: "Allow the connection"
   - Profile: "Domain, Private, Public" (as appropriate)
   - Name: "Azure Virtual Desktop - RDP Shortpath (UDP)"
   - Description: "Allows inbound UDP traffic for Azure Virtual Desktop RDP Shortpath"

### Step 6: Configure Port Range for Public Networks (Optional)

1. **Navigate to Azure Virtual Desktop Settings:**
   ```
   Computer Configuration 
   → Policies 
   → Administrative Templates 
   → Windows Components 
   → Remote Desktop Services 
   → Remote Desktop Session Host 
   → Azure Virtual Desktop
   ```

2. **Configure Port Range:**
   - Double-click "Use port range for RDP Shortpath for unmanaged networks"
   - Select "Enabled"
   - UDP base port: 38300 (default)
   - Port pool size: 1000 (default)
   - Click "OK"

### Step 7: Link and Apply the Policy

1. **Link the GPO:**
   - Ensure the GPO is linked to the OU containing your session hosts
   - Verify the link is enabled

2. **Set Security Filtering (if needed):**
   - In the GPO properties, configure security filtering to target specific computer groups
   - Add "Domain Computers" or specific security groups containing session hosts

3. **Force Policy Update:**
   ```powershell
   # On session hosts, run:
   gpupdate /force
   
   # Or remotely:
   Invoke-GPUpdate -Computer "SessionHostName" -Force
   ```

### Step 8: Verification

1. **Check Policy Application:**
   ```powershell
   # On session host, check applied policies:
   gpresult /r
   
   # Or generate detailed report:
   gpresult /h GPReport.html
   ```

2. **Verify Registry Settings:**
   ```powershell
   # Check if RDP Shortpath listener is enabled:
   Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name "fUseUdpPortRedirector"
   
   # Check UDP port:
   Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name "UdpPortNumber"
   
   # Check transport protocol:
   Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name "SelectTransport"
   ```

### Client-Side Group Policy Configuration

#### For Windows Clients connecting via VPN:

1. **Navigate to Client Settings:**
   ```
   Computer Configuration 
   → Policies 
   → Administrative Templates 
   → Windows Components 
   → Remote Desktop Services 
   → Remote Desktop Connection Client
   ```

2. **Enable UDP on Client:**
   - Double-click "Turn Off UDP On Client"
   - Select "Disabled" or "Not Configured"
   - Click "OK"

### Troubleshooting

#### Common Issues:
1. **Policy not applying:**
   - Check GPO link and security filtering
   - Verify session hosts are in the correct OU
   - Run `gpupdate /force` on session hosts

2. **Firewall blocking connections:**
   - Verify Windows Firewall rules are created
   - Check Network Security Groups (NSGs) in Azure
   - Ensure VPN/ExpressRoute allows UDP traffic on configured port

3. **UDP disabled:**
   - Check for conflicting policies
   - Verify transport protocol settings
   - Review client-side UDP configuration

#### Registry Validation:
```powershell
# Expected values for successful configuration:
# fUseUdpPortRedirector = 1 (RDP Shortpath listener enabled)
# UdpPortNumber = 3390 (or custom port)
# SelectTransport = 2 (UDP and TCP enabled)
```

### Security Considerations

1. **Firewall Configuration:**
   - Only open necessary ports
   - Restrict source IP ranges if possible
   - Use Network Security Groups for additional protection

2. **Network Isolation:**
   - Ensure session hosts are in appropriate subnets
   - Configure NSG rules to allow traffic only from VPN/ExpressRoute
   - Consider using Azure Firewall for centralized filtering

3. **Monitoring:**
   - Enable Azure Monitor for session hosts
   - Configure alerts for connection failures
   - Monitor UDP traffic patterns

### Best Practices

1. **Testing:**
   - Test policy application on a small group first
   - Verify connectivity before full deployment
   - Use the Check-UDPConfiguration.ps1 script for validation

2. **Documentation:**
   - Document custom port numbers
   - Maintain inventory of configured session hosts
   - Track policy versions and changes

3. **Maintenance:**
   - Regularly review and update administrative templates
   - Monitor Microsoft updates for new RDP Shortpath features
   - Test configuration after Azure Virtual Desktop updates

### Related Resources

- [Azure Virtual Desktop RDP Shortpath Documentation](https://docs.microsoft.com/en-us/azure/virtual-desktop/rdp-shortpath)
- [Azure Virtual Desktop Administrative Template](https://aka.ms/avdgpo)
- [Group Policy Management Best Practices](https://docs.microsoft.com/en-us/windows-server/identity/ad-ds/deploy/managing-group-policy-object-links)