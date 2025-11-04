# How to Check RDP Traffic is Going via VPN to Azure Virtual Desktop

## 🔍 **Quick Verification Methods**

### **Method 1: Use the Monitoring Script**
```powershell
# Basic check - verify routing and connectivity
.\Monitor-RDPTraffic.ps1 -SessionHostIP "10.189.50.135" -GenerateReport

# Real-time monitoring during RDP session
.\Monitor-RDPTraffic.ps1 -SessionHostIP "10.189.50.135" -RealTimeMonitoring

# Monitor for specific duration
.\Monitor-RDPTraffic.ps1 -SessionHostIP "10.189.50.135" -MonitorDurationSeconds 120
```

### **Method 2: Manual PowerShell Commands**

#### **Check Network Route:**
```powershell
# Check route to session host
Get-NetRoute -DestinationPrefix "10.189.50.135/32"

# Check default route
Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Sort-Object RouteMetric

# Identify VPN interface
Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "VPN|TAP|Tunnel" }
```

#### **Check Active Connections:**
```powershell
# Check TCP connections to session host
Get-NetTCPConnection -RemoteAddress "10.189.50.135"

# Check UDP endpoints on RDP Shortpath port
Get-NetUDPEndpoint | Where-Object { $_.LocalPort -eq 3390 }

# Check processes using these connections
Get-NetTCPConnection -RemoteAddress "10.189.50.135" | ForEach-Object {
    Get-Process -Id $_.OwningProcess
}
```

### **Method 3: Built-in Windows Tools**

#### **Command Prompt:**
```cmd
# Show route table
route print

# Show active connections
netstat -an | findstr "10.189.50.135"

# Trace route to session host
tracert 10.189.50.135
```

#### **PowerShell Network Utilities:**
```powershell
# Test connectivity
Test-NetConnection -ComputerName "10.189.50.135" -Port 3390

# Ping with source interface (if VPN supports it)
Test-Connection -ComputerName "10.189.50.135" -Source "VPN_Interface_IP"
```

## 🎯 **What to Look For**

### **✅ Signs Traffic is Going via VPN:**

1. **Route Check:**
   ```
   DestinationPrefix: 10.189.50.135/32
   InterfaceAlias: "VPN Connection" (or similar)
   NextHop: VPN gateway IP
   ```

2. **Interface Metrics:**
   - VPN interface has lower route metric for session host subnet
   - Traffic counters increasing on VPN interface during RDP session

3. **Connection Information in RDP Client:**
   - Transport shows "UDP (Private Network)"
   - Low latency consistent with VPN connection

### **❌ Signs Traffic is NOT Going via VPN:**

1. **Route Issues:**
   ```
   InterfaceAlias: "Ethernet" or "Wi-Fi" (not VPN)
   NextHop: Local gateway IP (not VPN)
   ```

2. **Connection Fallback:**
   - Transport shows "TCP" instead of "UDP"
   - Higher latency inconsistent with VPN

## 🛠️ **Advanced Monitoring Techniques**

### **Method 4: Wireshark/Network Capture**
```powershell
# Start network capture (requires admin)
netsh trace start capture=yes tracefile=rdp-traffic.etl provider=Microsoft-Windows-TCPIP

# Stop capture after testing
netsh trace stop

# Or use Wireshark with filters:
# ip.dst == 10.189.50.135 and (tcp.port == 3389 or udp.port == 3390)
```

### **Method 5: Performance Counters**
```powershell
# Monitor network interface usage
Get-Counter -Counter "\Network Interface(*)\Bytes Total/sec" -SampleInterval 2 -MaxSamples 30

# Monitor specific VPN interface
Get-Counter -Counter "\Network Interface(VPN Connection)\Bytes Total/sec"
```

### **Method 6: Event Log Analysis**
```powershell
# Check for VPN connection events
Get-WinEvent -FilterHashtable @{LogName="Application"; ProviderName="RasClient"}

# Check for RDP connection events
Get-WinEvent -FilterHashtable @{LogName="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"}
```

## 🔧 **Troubleshooting Common Issues**

### **Issue 1: Traffic Not Going via VPN**
```powershell
# Check VPN connection status
Get-VpnConnection

# Check VPN route metrics
Get-NetRoute | Where-Object { $_.InterfaceAlias -like "*VPN*" }

# Force route through VPN (temporary)
New-NetRoute -DestinationPrefix "10.189.50.0/24" -InterfaceAlias "VPN Connection" -NextHop "VPN_Gateway_IP"
```

### **Issue 2: VPN Interface Not Detected**
```powershell
# List all network adapters
Get-NetAdapter | Format-Table Name, InterfaceDescription, Status

# Check for hidden/disabled adapters
Get-NetAdapter -IncludeHidden | Where-Object { $_.InterfaceDescription -match "VPN|TAP|Tunnel" }
```

### **Issue 3: Multiple Routes Conflict**
```powershell
# Check route priorities
Get-NetRoute -DestinationPrefix "10.0.0.0/8" | Sort-Object RouteMetric

# Remove conflicting routes (be careful!)
# Remove-NetRoute -DestinationPrefix "x.x.x.x/x" -Confirm
```

## 📊 **Real-Time Monitoring During RDP Session**

### **Step-by-Step Verification:**

1. **Before connecting to AVD:**
   ```powershell
   .\Monitor-RDPTraffic.ps1 -SessionHostIP "10.189.50.135" -RealTimeMonitoring
   ```

2. **Connect to Azure Virtual Desktop session**

3. **Verify in real-time display:**
   - Active connections to 10.189.50.135
   - UDP endpoints on port 3390
   - VPN interface statistics increasing

4. **Check RDP client connection info:**
   - Click signal strength icon in RDP session
   - Verify "Transport: UDP (Private Network)"

## 🎯 **Expected Results for VPN Traffic**

### **Successful VPN Routing:**
```
Route Analysis:
✅ Destination: 10.189.50.135/32
✅ Interface: VPN Connection
✅ Next Hop: 192.168.100.1 (VPN gateway)
✅ Via VPN: Yes

Connection Test:
✅ UDP Test: Success
✅ Latency: 15-50ms (typical VPN latency)

RDP Client Shows:
✅ Transport: UDP (Private Network)
```

### **Failed VPN Routing:**
```
Route Analysis:
❌ Interface: Ethernet/Wi-Fi
❌ Next Hop: Local gateway
❌ Via VPN: No

Connection Test:
⚠️ Higher latency (100+ms)
⚠️ May fall back to TCP

RDP Client Shows:
❌ Transport: TCP or UDP (public)
```

## 🔗 **Related Commands for Verification**

```powershell
# Quick one-liners for common checks:

# Check if session host route goes through VPN
(Get-NetRoute -DestinationPrefix "10.189.50.135/32").InterfaceAlias

# Show VPN interface stats
Get-NetAdapterStatistics | Where-Object { $_.Name -like "*VPN*" }

# List active RDP processes
Get-Process | Where-Object { $_.ProcessName -match "mstsc|msrdc|WindowsApp" }

# Check UDP 3390 listeners
Get-NetUDPEndpoint -LocalPort 3390
```