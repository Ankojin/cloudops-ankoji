# Monitor-RDPTraffic.ps1
# Script to monitor and verify RDP traffic is going via VPN to Azure Virtual Desktop
# Author: BAB CloudOps Team
# Date: November 3, 2025

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$SessionHostIP = "10.189.50.135",
    
    [Parameter(Mandatory=$false)]
    [int]$RDPShortpathPort = 3390,
    
    [Parameter(Mandatory=$false)]
    [string]$VPNInterfaceName = "",  # Auto-detect if empty
    
    [Parameter(Mandatory=$false)]
    [int]$MonitorDurationSeconds = 60,
    
    [Parameter(Mandatory=$false)]
    [switch]$RealTimeMonitoring,
    
    [Parameter(Mandatory=$false)]
    [switch]$GenerateReport,
    
    [Parameter(Mandatory=$false)]
    [string]$ReportPath = "RDP-Traffic-Analysis.html"
)

function Write-LogMessage {
    param(
        [string]$Message,
        [ValidateSet("Info", "Warning", "Error", "Success")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    switch ($Level) {
        "Info" { Write-Host $logMessage -ForegroundColor Cyan }
        "Warning" { Write-Host $logMessage -ForegroundColor Yellow }
        "Error" { Write-Host $logMessage -ForegroundColor Red }
        "Success" { Write-Host $logMessage -ForegroundColor Green }
    }
}

function Get-NetworkInterfaces {
    Write-LogMessage "Analyzing network interfaces..."
    
    $interfaces = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Sort-Object Name
    $interfaceInfo = @()
    
    foreach ($interface in $interfaces) {
        $ipConfig = Get-NetIPAddress -InterfaceIndex $interface.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $gateway = Get-NetRoute -InterfaceIndex $interface.InterfaceIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue
        
        $interfaceData = @{
            Name = $interface.Name
            Description = $interface.InterfaceDescription
            Status = $interface.Status
            LinkSpeed = $interface.LinkSpeed
            IPAddress = if ($ipConfig) { $ipConfig.IPAddress } else { "None" }
            Gateway = if ($gateway) { $gateway.NextHop } else { "None" }
            IsVPN = $false
            InterfaceIndex = $interface.InterfaceIndex
        }
        
        # Detect VPN interfaces (common patterns)
        if ($interface.InterfaceDescription -match "VPN|TAP|OpenVPN|Cisco|FortiClient|Pulse|GlobalProtect|WireGuard|L2TP|SSTP|IKEv2|Point-to-Point" -or
            $interface.Name -match "VPN|Tunnel|PPP") {
            $interfaceData.IsVPN = $true
        }
        
        $interfaceInfo += $interfaceData
    }
    
    return $interfaceInfo
}

function Get-VPNInterface {
    param([string]$InterfaceName)
    
    $interfaces = Get-NetworkInterfaces
    
    if ($InterfaceName) {
        $vpnInterface = $interfaces | Where-Object { $_.Name -eq $InterfaceName }
        if (-not $vpnInterface) {
            Write-LogMessage "Specified VPN interface '$InterfaceName' not found" -Level "Warning"
        }
        return $vpnInterface
    }
    
    # Auto-detect VPN interface
    $vpnInterfaces = $interfaces | Where-Object { $_.IsVPN -eq $true }
    
    if ($vpnInterfaces.Count -eq 0) {
        Write-LogMessage "No VPN interface detected automatically" -Level "Warning"
        Write-LogMessage "Available interfaces:" -Level "Info"
        foreach ($iface in $interfaces) {
            Write-LogMessage "  $($iface.Name) - $($iface.Description) - IP: $($iface.IPAddress)" -Level "Info"
        }
        return $null
    } elseif ($vpnInterfaces.Count -eq 1) {
        Write-LogMessage "Detected VPN interface: $($vpnInterfaces[0].Name)" -Level "Success"
        return $vpnInterfaces[0]
    } else {
        Write-LogMessage "Multiple VPN interfaces detected:" -Level "Warning"
        foreach ($vpn in $vpnInterfaces) {
            Write-LogMessage "  $($vpn.Name) - $($vpn.Description)" -Level "Info"
        }
        Write-LogMessage "Using first detected: $($vpnInterfaces[0].Name)" -Level "Info"
        return $vpnInterfaces[0]
    }
}

function Test-RouteToSessionHost {
    param(
        [string]$TargetIP,
        [object]$VPNInterface
    )
    
    Write-LogMessage "Checking route to session host: $TargetIP"
    
    try {
        # Get route to session host
        $route = Get-NetRoute -DestinationPrefix "$TargetIP/32" -ErrorAction SilentlyContinue
        if (-not $route) {
            # Try to find route for the subnet
            $subnet = ($TargetIP -split '\.')[0..2] -join '.'
            $route = Get-NetRoute | Where-Object { 
                $_.DestinationPrefix -like "$subnet.*" -or 
                ($_.DestinationPrefix -eq "0.0.0.0/0" -and $_.RouteMetric -eq (Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Measure-Object RouteMetric -Minimum).Minimum)
            } | Sort-Object RouteMetric | Select-Object -First 1
        }
        
        if ($route) {
            $routeInterface = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex
            
            $routeInfo = @{
                DestinationPrefix = $route.DestinationPrefix
                NextHop = $route.NextHop
                InterfaceAlias = $routeInterface.Name
                InterfaceDescription = $routeInterface.InterfaceDescription
                RouteMetric = $route.RouteMetric
                IsViaVPN = $false
            }
            
            # Check if route goes through VPN
            if ($VPNInterface -and $route.InterfaceIndex -eq $VPNInterface.InterfaceIndex) {
                $routeInfo.IsViaVPN = $true
                Write-LogMessage "✅ Route to $TargetIP goes through VPN interface: $($routeInterface.Name)" -Level "Success"
            } else {
                Write-LogMessage "⚠️ Route to $TargetIP goes through: $($routeInterface.Name) (NOT VPN)" -Level "Warning"
            }
            
            return $routeInfo
        } else {
            Write-LogMessage "❌ No route found to $TargetIP" -Level "Error"
            return $null
        }
        
    } catch {
        Write-LogMessage "Error checking route: $($_.Exception.Message)" -Level "Error"
        return $null
    }
}

function Monitor-NetworkConnections {
    param(
        [string]$TargetIP,
        [int]$TargetPort,
        [int]$Duration,
        [object]$VPNInterface
    )
    
    Write-LogMessage "Monitoring network connections to $TargetIP`:$TargetPort for $Duration seconds..."
    
    $connections = @()
    $startTime = Get-Date
    $endTime = $startTime.AddSeconds($Duration)
    
    while ((Get-Date) -lt $endTime) {
        try {
            # Get current TCP connections
            $tcpConnections = Get-NetTCPConnection -RemoteAddress $TargetIP -ErrorAction SilentlyContinue
            
            # Get UDP endpoints (harder to track active connections)
            $udpEndpoints = Get-NetUDPEndpoint | Where-Object { $_.LocalPort -eq $TargetPort }
            
            foreach ($conn in $tcpConnections) {
                $connInfo = @{
                    Timestamp = Get-Date
                    Protocol = "TCP"
                    LocalAddress = $conn.LocalAddress
                    LocalPort = $conn.LocalPort
                    RemoteAddress = $conn.RemoteAddress
                    RemotePort = $conn.RemotePort
                    State = $conn.State
                    OwningProcess = $conn.OwningProcess
                }
                
                # Get process name
                try {
                    $process = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
                    $connInfo.ProcessName = if ($process) { $process.ProcessName } else { "Unknown" }
                } catch {
                    $connInfo.ProcessName = "Unknown"
                }
                
                $connections += $connInfo
            }
            
            foreach ($udp in $udpEndpoints) {
                $connInfo = @{
                    Timestamp = Get-Date
                    Protocol = "UDP"
                    LocalAddress = $udp.LocalAddress
                    LocalPort = $udp.LocalPort
                    RemoteAddress = "N/A"
                    RemotePort = "N/A"
                    State = "Listening"
                    OwningProcess = $udp.OwningProcess
                }
                
                # Get process name
                try {
                    $process = Get-Process -Id $udp.OwningProcess -ErrorAction SilentlyContinue
                    $connInfo.ProcessName = if ($process) { $process.ProcessName } else { "Unknown" }
                } catch {
                    $connInfo.ProcessName = "Unknown"
                }
                
                $connections += $connInfo
            }
            
            Start-Sleep -Seconds 2
            
        } catch {
            Write-LogMessage "Error monitoring connections: $($_.Exception.Message)" -Level "Error"
        }
    }
    
    return $connections | Sort-Object Timestamp | Group-Object Protocol, ProcessName | ForEach-Object {
        @{
            Protocol = ($_.Name -split ', ')[0]
            ProcessName = ($_.Name -split ', ')[1]
            ConnectionCount = $_.Count
            FirstSeen = ($_.Group | Sort-Object Timestamp | Select-Object -First 1).Timestamp
            LastSeen = ($_.Group | Sort-Object Timestamp | Select-Object -Last 1).Timestamp
            Connections = $_.Group
        }
    }
}

function Test-RDPShortpathConnection {
    param(
        [string]$TargetIP,
        [int]$Port
    )
    
    Write-LogMessage "Testing RDP Shortpath connection to $TargetIP`:$Port"
    
    $testResults = @{
        UDPTest = $false
        TCPTest = $false
        Latency = 0
        PacketLoss = 0
        Error = ""
    }
    
    try {
        # Test UDP connectivity
        $udpClient = New-Object System.Net.Sockets.UdpClient
        try {
            $udpClient.Connect($TargetIP, $Port)
            $testData = [System.Text.Encoding]::ASCII.GetBytes("RDP_SHORTPATH_TEST")
            $udpClient.Send($testData, $testData.Length) | Out-Null
            $testResults.UDPTest = $true
            Write-LogMessage "✅ UDP connectivity test successful" -Level "Success"
        } catch {
            $testResults.Error += "UDP test failed: $($_.Exception.Message); "
            Write-LogMessage "❌ UDP connectivity test failed" -Level "Warning"
        } finally {
            $udpClient.Close()
        }
        
        # Test TCP connectivity (for comparison)
        $tcpTest = Test-NetConnection -ComputerName $TargetIP -Port 3389 -WarningAction SilentlyContinue
        $testResults.TCPTest = $tcpTest.TcpTestSucceeded
        
        # Ping test for latency
        $pingTest = Test-Connection -ComputerName $TargetIP -Count 4 -Quiet
        if ($pingTest) {
            $pingResults = Test-Connection -ComputerName $TargetIP -Count 4
            $testResults.Latency = ($pingResults | Measure-Object ResponseTime -Average).Average
            Write-LogMessage "📊 Average latency: $($testResults.Latency)ms" -Level "Info"
        }
        
    } catch {
        $testResults.Error += "Connection test error: $($_.Exception.Message)"
        Write-LogMessage "Error testing connection: $($_.Exception.Message)" -Level "Error"
    }
    
    return $testResults
}

function Start-RealTimeMonitoring {
    param(
        [string]$TargetIP,
        [int]$Port,
        [object]$VPNInterface
    )
    
    Write-LogMessage "Starting real-time monitoring (Press Ctrl+C to stop)..."
    Write-Host ""
    Write-Host "Monitoring RDP traffic to $TargetIP`:$Port" -ForegroundColor White
    Write-Host "VPN Interface: $($VPNInterface.Name)" -ForegroundColor Green
    Write-Host "Press Ctrl+C to stop monitoring" -ForegroundColor Yellow
    Write-Host ""
    
    $lastConnections = @()
    
    try {
        while ($true) {
            Clear-Host
            Write-Host "=== Real-Time RDP Traffic Monitor ===" -ForegroundColor Cyan
            Write-Host "Target: $TargetIP`:$Port | VPN: $($VPNInterface.Name) | Time: $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor White
            Write-Host ""
            
            # Get current connections
            $currentConnections = Get-NetTCPConnection -RemoteAddress $TargetIP -ErrorAction SilentlyContinue
            $currentUDP = Get-NetUDPEndpoint | Where-Object { $_.LocalPort -eq $Port }
            
            # Display TCP connections
            if ($currentConnections) {
                Write-Host "Active TCP Connections:" -ForegroundColor Green
                foreach ($conn in $currentConnections) {
                    $process = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
                    $processName = if ($process) { $process.ProcessName } else { "Unknown" }
                    Write-Host "  $($conn.LocalAddress):$($conn.LocalPort) → $($conn.RemoteAddress):$($conn.RemotePort) [$($conn.State)] ($processName)" -ForegroundColor Gray
                }
            } else {
                Write-Host "No active TCP connections to target" -ForegroundColor Yellow
            }
            
            Write-Host ""
            
            # Display UDP endpoints
            if ($currentUDP) {
                Write-Host "UDP Endpoints (Port $Port):" -ForegroundColor Green
                foreach ($udp in $currentUDP) {
                    $process = Get-Process -Id $udp.OwningProcess -ErrorAction SilentlyContinue
                    $processName = if ($process) { $process.ProcessName } else { "Unknown" }
                    Write-Host "  $($udp.LocalAddress):$($udp.LocalPort) [Listening] ($processName)" -ForegroundColor Gray
                }
            } else {
                Write-Host "No UDP endpoints listening on port $Port" -ForegroundColor Yellow
            }
            
            Write-Host ""
            
            # Show network stats
            $networkStats = Get-NetAdapterStatistics -Name $VPNInterface.Name -ErrorAction SilentlyContinue
            if ($networkStats) {
                Write-Host "VPN Interface Statistics:" -ForegroundColor Green
                Write-Host "  Bytes Sent: $($networkStats.BytesSent)" -ForegroundColor Gray
                Write-Host "  Bytes Received: $($networkStats.BytesReceived)" -ForegroundColor Gray
                Write-Host "  Packets Sent: $($networkStats.PacketsSent)" -ForegroundColor Gray
                Write-Host "  Packets Received: $($networkStats.PacketsReceived)" -ForegroundColor Gray
            }
            
            Start-Sleep -Seconds 2
        }
    } catch [System.Management.Automation.PipelineStoppedException] {
        Write-Host "`nMonitoring stopped by user" -ForegroundColor Yellow
    }
}

function Generate-TrafficReport {
    param(
        [object]$NetworkInfo,
        [object]$RouteInfo,
        [object]$ConnectionData,
        [object]$TestResults,
        [string]$OutputPath
    )
    
    Write-LogMessage "Generating traffic analysis report: $OutputPath"
    
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>RDP Traffic Analysis Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .header { background-color: #f0f0f0; padding: 10px; border-radius: 5px; }
        .section { margin: 20px 0; }
        .success { color: green; }
        .warning { color: orange; }
        .error { color: red; }
        .info { color: blue; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
        .status-ok { background-color: #d4edda; }
        .status-warning { background-color: #fff3cd; }
        .status-error { background-color: #f8d7da; }
    </style>
</head>
<body>
    <div class="header">
        <h1>RDP Traffic Analysis Report</h1>
        <p>Generated on: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>
        <p>Target Session Host: $SessionHostIP</p>
    </div>
"@

    # Network Interfaces section
    $html += @"
    <div class="section">
        <h2>Network Interfaces</h2>
        <table>
            <tr>
                <th>Interface Name</th>
                <th>Description</th>
                <th>IP Address</th>
                <th>Gateway</th>
                <th>Type</th>
                <th>Status</th>
            </tr>
"@
    
    foreach ($interface in $NetworkInfo) {
        $typeClass = if ($interface.IsVPN) { "status-ok" } else { "status-warning" }
        $type = if ($interface.IsVPN) { "VPN" } else { "Standard" }
        
        $html += @"
            <tr class="$typeClass">
                <td>$($interface.Name)</td>
                <td>$($interface.Description)</td>
                <td>$($interface.IPAddress)</td>
                <td>$($interface.Gateway)</td>
                <td>$type</td>
                <td>$($interface.Status)</td>
            </tr>
"@
    }
    
    $html += "</table></div>"

    # Route Analysis section
    if ($RouteInfo) {
        $routeClass = if ($RouteInfo.IsViaVPN) { "status-ok" } else { "status-error" }
        $html += @"
    <div class="section">
        <h2>Route Analysis</h2>
        <table>
            <tr>
                <th>Destination</th>
                <th>Next Hop</th>
                <th>Interface</th>
                <th>Metric</th>
                <th>Via VPN</th>
            </tr>
            <tr class="$routeClass">
                <td>$($RouteInfo.DestinationPrefix)</td>
                <td>$($RouteInfo.NextHop)</td>
                <td>$($RouteInfo.InterfaceAlias)</td>
                <td>$($RouteInfo.RouteMetric)</td>
                <td>$(if ($RouteInfo.IsViaVPN) { 'Yes' } else { 'No' })</td>
            </tr>
        </table>
    </div>
"@
    }

    $html += @"
    <div class="section">
        <h2>Connection Test Results</h2>
        <p><strong>UDP Test:</strong> $(if ($TestResults.UDPTest) { '✅ Success' } else { '❌ Failed' })</p>
        <p><strong>TCP Test:</strong> $(if ($TestResults.TCPTest) { '✅ Success' } else { '❌ Failed' })</p>
        <p><strong>Average Latency:</strong> $($TestResults.Latency)ms</p>
        $(if ($TestResults.Error) { "<p><strong>Errors:</strong> $($TestResults.Error)</p>" })
    </div>
    
    <div class="section">
        <h2>Recommendations</h2>
        <ul>
"@

    if ($RouteInfo -and $RouteInfo.IsViaVPN) {
        $html += "<li class='success'>✅ Traffic is correctly routed through VPN</li>"
    } else {
        $html += "<li class='error'>❌ Traffic is NOT going through VPN - check routing</li>"
    }
    
    if ($TestResults.UDPTest) {
        $html += "<li class='success'>✅ UDP connectivity is working</li>"
    } else {
        $html += "<li class='warning'>⚠️ UDP connectivity issues detected</li>"
    }

    $html += @"
        </ul>
    </div>
</body>
</html>
"@

    try {
        $html | Out-File -FilePath $OutputPath -Encoding UTF8
        Write-LogMessage "Report generated successfully: $OutputPath" -Level "Success"
        return $true
    } catch {
        Write-LogMessage "Error generating report: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

# Main execution
Write-LogMessage "Starting RDP traffic monitoring and analysis..." -Level "Info"
Write-LogMessage "Target Session Host: $SessionHostIP" -Level "Info"
Write-LogMessage "RDP Shortpath Port: $RDPShortpathPort" -Level "Info"
Write-Host ""

# Get network interfaces
$networkInterfaces = Get-NetworkInterfaces
Write-LogMessage "Found $($networkInterfaces.Count) active network interfaces" -Level "Info"

# Identify VPN interface
$vpnInterface = Get-VPNInterface -InterfaceName $VPNInterfaceName
if (-not $vpnInterface) {
    Write-LogMessage "Cannot proceed without VPN interface identification" -Level "Error"
    Write-LogMessage "Please specify -VPNInterfaceName parameter or ensure VPN is connected" -Level "Error"
    exit 1
}

# Check routing
$routeInfo = Test-RouteToSessionHost -TargetIP $SessionHostIP -VPNInterface $vpnInterface

# Test connectivity
$connectionTest = Test-RDPShortpathConnection -TargetIP $SessionHostIP -Port $RDPShortpathPort

# Real-time monitoring if requested
if ($RealTimeMonitoring) {
    Start-RealTimeMonitoring -TargetIP $SessionHostIP -Port $RDPShortpathPort -VPNInterface $vpnInterface
} else {
    # Monitor connections for specified duration
    $connectionData = Monitor-NetworkConnections -TargetIP $SessionHostIP -TargetPort $RDPShortpathPort -Duration $MonitorDurationSeconds -VPNInterface $vpnInterface
    
    Write-LogMessage "`n=== ANALYSIS SUMMARY ===" -Level "Info"
    
    if ($routeInfo -and $routeInfo.IsViaVPN) {
        Write-LogMessage "✅ TRAFFIC ROUTING: Via VPN ($($vpnInterface.Name))" -Level "Success"
    } else {
        Write-LogMessage "❌ TRAFFIC ROUTING: NOT via VPN" -Level "Error"
    }
    
    if ($connectionTest.UDPTest) {
        Write-LogMessage "✅ UDP CONNECTIVITY: Working" -Level "Success"
    } else {
        Write-LogMessage "❌ UDP CONNECTIVITY: Failed" -Level "Warning"
    }
    
    Write-LogMessage "📊 LATENCY: $($connectionTest.Latency)ms" -Level "Info"
    
    if ($connectionData.Count -gt 0) {
        Write-LogMessage "📈 CONNECTIONS MONITORED: $($connectionData.Count) unique connection types" -Level "Info"
        foreach ($conn in $connectionData) {
            Write-LogMessage "  $($conn.Protocol) - $($conn.ProcessName): $($conn.ConnectionCount) connections" -Level "Info"
        }
    }
}

# Generate report if requested
if ($GenerateReport) {
    Generate-TrafficReport -NetworkInfo $networkInterfaces -RouteInfo $routeInfo -ConnectionData $connectionData -TestResults $connectionTest -OutputPath $ReportPath | Out-Null
}

Write-LogMessage "`nTraffic analysis completed." -Level "Success"