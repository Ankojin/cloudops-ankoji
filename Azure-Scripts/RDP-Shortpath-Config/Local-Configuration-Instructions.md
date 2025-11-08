# RDP Shortpath Local Configuration Instructions

## 🎯 **Quick Setup for Session Host: 10.189.50.135**

### **Step 1: Copy Script to Session Host**
1. Copy `Configure-RDPShortpath-Local.ps1` to the session host `10.189.50.135`
2. Place it in a folder like `C:\Temp\` or `C:\Scripts\`

### **Step 2: Run on Session Host (as Administrator)**

#### **Option A: Test First (Recommended)**
```powershell
# Run in What-If mode to see what would be changed
.\Configure-RDPShortpath-Local.ps1 -ConfigureFirewall -WhatIf
```

#### **Option B: Apply Configuration**
```powershell
# Apply the configuration with firewall rules
.\Configure-RDPShortpath-Local.ps1 -ConfigureFirewall
```

#### **Option C: Apply and Auto-Restart**
```powershell
# Apply configuration and restart automatically
.\Configure-RDPShortpath-Local.ps1 -ConfigureFirewall -RestartRequired
```

### **Step 3: What This Script Does**

#### ✅ **Registry Configuration:**
- Enables RDP Shortpath listener on port 3390
- Configures UDP transport (both UDP and TCP)
- Sets up proper registry keys in `HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services`

#### ✅ **Firewall Rules (if -ConfigureFirewall used):**
- **Inbound UDP 3390** - For managed networks (VPN)
- **Inbound UDP 38300-39299** - For STUN/TURN (public networks)
- **Outbound UDP** - For general RDP Shortpath traffic

#### ✅ **Validation:**
- Checks current configuration before changes
- Tests port availability
- Shows before/after comparison
- Creates detailed log file

### **Step 4: Expected Output**
```
[2025-11-03 23:30:00] [Info] Starting RDP Shortpath local configuration on SESSION-HOST-01
[2025-11-03 23:30:01] [Info] Current Status:
[2025-11-03 23:30:01] [Warning]   RDP Shortpath Listener: Not Configured
[2025-11-03 23:30:02] [Success] Set fUseUdpPortRedirector = 1 (Enable RDP Shortpath listener)
[2025-11-03 23:30:02] [Success] Set UdpPortNumber = 3390 (RDP Shortpath port number)
[2025-11-03 23:30:03] [Success] Created rule: Azure Virtual Desktop - RDP Shortpath (UDP-In)
[2025-11-03 23:30:03] [Warning] IMPORTANT: Restart this session host for changes to take effect!
```

### **Step 5: After Configuration**

#### **Manual Restart (if not using -RestartRequired):**
```powershell
Restart-Computer -Force
```

#### **Verify Configuration After Restart:**
```powershell
# Check if RDP Shortpath is working
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name "fUseUdpPortRedirector"
Get-NetFirewallRule | Where-Object { $_.DisplayName -like "*RDP Shortpath*" }
```

## 🔥 **Firewall Requirements**

### **On-Premises Firewall (Critical!):**
```
Rule: Allow UDP 3390
Source: VPN client subnets (e.g., 192.168.x.x/24)
Destination: Session host private IP (10.189.50.135)
Protocol: UDP
Action: Allow
```

### **Azure Network Security Group:**
```
Rule Name: Allow-RDP-Shortpath-VPN
Source: VPN subnet
Destination: Session host subnet
Port: 3390
Protocol: UDP
Action: Allow
```

## 🎯 **Testing After Configuration**

### **From VPN Client:**
1. Connect to Azure Virtual Desktop
2. During connection, press the signal strength icon
3. Check "Connection Information" dialog
4. Look for: **"Transport: UDP (Private Network)"**

### **Expected Behavior:**
- ✅ **With VPN + Port 3390 open:** UDP (Private Network) - Best performance
- ⚠️ **With VPN but Port 3390 blocked:** May use ICE/STUN over VPN or connection may fail
- ⚠️ **Without VPN:** Uses public internet paths (STUN/TURN) or TCP 443 fallback
- ❌ **VPN with all UDP blocked:** Connection will likely fail (no TCP 443 fallback over VPN)

## 🚨 **Important Notes**

1. **Administrator Rights Required:** Script must run as Administrator
2. **Restart Required:** Session host must restart for changes to take effect
3. **Firewall Configuration:** On-premises firewall must allow UDP 3390 over VPN
4. **Host Pool Settings:** Also configure in Azure Portal (Host pools → Networking → RDP Shortpath)
5. **Log File:** Check `RDP-Shortpath-Local-Config.log` for detailed results

## ❗ **Important: VPN vs Public Network Behavior**

### **Over VPN (Managed Network):**
- **Primary:** UDP 3390 direct to session host private IP
- **Secondary:** UDP dynamic ports (ICE/STUN) over VPN  
- **NO TCP 443 fallback** - VPN provides direct connectivity

### **Over Public Internet (No VPN):**
- **Primary:** UDP with STUN/TURN over public internet
- **Fallback:** TCP 443 through Azure gateway

**Key Point:** If all UDP ports are blocked over VPN, the connection may fail entirely because TCP 443 reverse connect is not used over VPN connections!

## 📞 **Support**
- Check the generated log file for errors
- Verify firewall rules with `Get-NetFirewallRule`
- Test connectivity with `Test-NetConnection`