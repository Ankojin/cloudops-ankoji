# Monitor-RDPTraffic-S2S.ps1
# Script to monitor RDP traffic over Site-to-Site VPN (S2S) to Azure Virtual Desktop
# Author: BAB CloudOps Team
# Date: November 4, 2025

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$SessionHostIP = "10.189.50.135",
    
    [Parameter(Mandatory=$false)]
    [int]$RDPShortpathPort = 3390,
    
    [Parameter(Mandatory=$false)]
    [string]$CorporateGateway = "",  # Auto-detect if empty
    
    [Parameter(Mandatory=$false)]
    [string[]]$AzureSubnets = @("10.0.0.0/8", "172.16.0.0/12"),  # Common Azure subnets
    
    [Parameter(Mandatory=$false)]
    [switch]$RealTimeMonitoring,
    
    [Parameter(Mandatory=$false)]
    [switch]$GenerateReport
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

function Get-CorporateNetworkInfo {
    Write-LogMessage "Analyzing corporate network configuration..."
    
    # Get default gateway (corporate gateway)
    $defaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Sort-Object RouteMetric | Select-Object -First 1
    $corporateGW = $defaultRoute.NextHop
    $corporateInterface = Get-NetAdapter -InterfaceIndex $defaultRoute.InterfaceIndex
    
    # Get local IP configuration
    $localIP = Get-NetIPAddress -InterfaceIndex $defaultRoute.InterfaceIndex -AddressFamily IPv4
    
    return @{
        CorporateGateway = $corporateGW
        CorporateInterface = $corporateInterface.Name
        CorporateInterfaceDescription = $corporateInterface.InterfaceDescription
        LocalIP = $localIP.IPAddress
        LocalSubnet = "$($localIP.IPAddress)/$($localIP.PrefixLength)"
    }
}

function Test-S2SVPNRouting {
    param(
        [string]$TargetIP,
        [object]$NetworkInfo
    )
    
    Write-LogMessage "Checking Site-to-Site VPN routing to $TargetIP..."
    
    try {
        # Get specific route to session host
        $sessionHostRoute = Get-NetRoute -DestinationPrefix "$TargetIP/32" -ErrorAction SilentlyContinue
        
        if (-not $sessionHostRoute) {
            # Check for subnet routes to Azure
            foreach ($subnet in $AzureSubnets) {
                $azureRoute = Get-NetRoute -DestinationPrefix $subnet -ErrorAction SilentlyContinue
                if ($azureRoute) {
                    $sessionHostRoute = $azureRoute | Sort-Object RouteMetric | Select-Object -First 1
                    break
                }
            }
        }
        
        if (-not $sessionHostRoute) {
            # Use default route
            $sessionHostRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Sort-Object RouteMetric | Select-Object -First 1
        }
        
        $routeInterface = Get-NetAdapter -InterfaceIndex $sessionHostRoute.InterfaceIndex
        
        $routingInfo = @{
            DestinationPrefix = $sessionHostRoute.DestinationPrefix
            NextHop = $sessionHostRoute.NextHop
            InterfaceAlias = $routeInterface.Name
            InterfaceDescription = $routeInterface.InterfaceDescription
            RouteMetric = $sessionHostRoute.RouteMetric
            IsViaCorporateGateway = $false
            IsLikelyS2SVPN = $false
        }
        
        # Check if route goes through corporate gateway
        if ($sessionHostRoute.NextHop -eq $NetworkInfo.CorporateGateway) {
            $routingInfo.IsViaCorporateGateway = $true
            Write-LogMessage "✅ Route to $TargetIP goes through corporate gateway: $($NetworkInfo.CorporateGateway)" -Level "Success"
            
            # Check if target is in private IP range (indicates S2S VPN)
            if ($TargetIP -match "^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)" -and
                $NetworkInfo.LocalIP -notmatch "^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)") {
                $routingInfo.IsLikelyS2SVPN = $true
                Write-LogMessage "✅ Traffic likely uses Site-to-Site VPN (private destination from different subnet)" -Level "Success"
            } elseif ($TargetIP -match "^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)" -and
                      $NetworkInfo.LocalIP -match "^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)") {
                $routingInfo.IsLikelyS2SVPN = $true
                Write-LogMessage "✅ Traffic likely uses Site-to-Site VPN (both endpoints in private ranges)" -Level "Success"
            }
        } else {
            Write-LogMessage "⚠️ Route to $TargetIP does NOT go through corporate gateway" -Level "Warning"
            Write-LogMessage "   Next hop: $($sessionHostRoute.NextHop) (Expected: $($NetworkInfo.CorporateGateway))" -Level "Warning"
        }
        
        return $routingInfo
        
    } catch {
        Write-LogMessage "Error checking S2S VPN routing: $($_.Exception.Message)" -Level "Error"
        return $null
    }
}

function Test-RDPShortpathConnectivity {
    param(
        [string]$TargetIP,
        [int]$Port
    )
    
    Write-LogMessage "Testing RDP Shortpath connectivity to $TargetIP`:$Port..."
    
    $testResults = @{
        UDPConnectivity = $false
        TCPConnectivity = $false
        TraceRouteResults = @()
        Latency = 0
        Error = ""
    }
    
    try {
        # Test UDP connectivity (RDP Shortpath)
        try {
            $udpClient = New-Object System.Net.Sockets.UdpClient
            $udpClient.Connect($TargetIP, $Port)
            $testData = [System.Text.Encoding]::ASCII.GetBytes("RDP_SHORTPATH_TEST")
            $udpClient.Send($testData, $testData.Length) | Out-Null
            $udpClient.Close()
            $testResults.UDPConnectivity = $true
            Write-LogMessage "✅ UDP connectivity to port $Port successful" -Level "Success"
        } catch {
            if ($udpClient) { $udpClient.Close() }
            $testResults.Error += "UDP test failed: $($_.Exception.Message); "
            Write-LogMessage "❌ UDP connectivity to port $Port failed" -Level "Warning"
        }
        
        # Test TCP connectivity (traditional RDP for comparison)
        $tcpTest = Test-NetConnection -ComputerName $TargetIP -Port 3389 -WarningAction SilentlyContinue
        $testResults.TCPConnectivity = $tcpTest.TcpTestSucceeded
        
        # Perform trace route
        Write-LogMessage "Performing trace route to $TargetIP..."
        $traceTest = Test-NetConnection -ComputerName $TargetIP -TraceRoute -WarningAction SilentlyContinue
        $testResults.TraceRouteResults = $traceTest.TraceRoute
        
        # Ping for latency
        $pingResults = Test-Connection -ComputerName $TargetIP -Count 4 -ErrorAction SilentlyContinue
        if ($pingResults) {
            $testResults.Latency = ($pingResults | Measure-Object ResponseTime -Average).Average
            Write-LogMessage "📊 Average latency: $($testResults.Latency)ms" -Level "Info"
        }
        
    } catch {
        $testResults.Error += "Connection test error: $($_.Exception.Message)"
        Write-LogMessage "Error testing connectivity: $($_.Exception.Message)" -Level "Error"
    }
    
    return $testResults
}

function Monitor-ActiveConnections {
    param(
        [string]$TargetIP,
        [int]$Port
    )
    
    Write-LogMessage "Monitoring active connections to $TargetIP..."
    
    $connections = @{
        TCPConnections = @()
        UDPEndpoints = @()
        RDPProcesses = @()
    }
    
    try {
        # Get TCP connections to session host
        $tcpConns = Get-NetTCPConnection -RemoteAddress $TargetIP -ErrorAction SilentlyContinue
        foreach ($conn in $tcpConns) {
            $process = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            $connections.TCPConnections += @{
                LocalAddress = $conn.LocalAddress
                LocalPort = $conn.LocalPort
                RemotePort = $conn.RemotePort
                State = $conn.State
                ProcessName = if ($process) { $process.ProcessName } else { "Unknown" }
                ProcessId = $conn.OwningProcess
            }
        }
        
        # Get UDP endpoints on RDP Shortpath port
        $udpEndpoints = Get-NetUDPEndpoint | Where-Object { $_.LocalPort -eq $Port }
        foreach ($udp in $udpEndpoints) {
            $process = Get-Process -Id $udp.OwningProcess -ErrorAction SilentlyContinue
            $connections.UDPEndpoints += @{
                LocalAddress = $udp.LocalAddress
                LocalPort = $udp.LocalPort
                ProcessName = if ($process) { $process.ProcessName } else { "Unknown" }
                ProcessId = $udp.OwningProcess
            }
        }
        
        # Get RDP-related processes
        $rdpProcesses = Get-Process | Where-Object { 
            $_.ProcessName -match "mstsc|msrdc|rdpclip|WindowsApp|DesktopApp" 
        }
        $connections.RDPProcesses = $rdpProcesses | Select-Object ProcessName, Id, CPU, WorkingSet
        
    } catch {
        Write-LogMessage "Error monitoring connections: $($_.Exception.Message)" -Level "Error"
    }
    
    return $connections
}

function Start-RealTimeS2SMonitoring {
    param(
        [string]$TargetIP,
        [int]$Port,
        [object]$NetworkInfo
    )
    
    Write-LogMessage "Starting real-time S2S VPN monitoring (Press Ctrl+C to stop)..."
    
    try {
        while ($true) {
            Clear-Host
            Write-Host "=== Site-to-Site VPN RDP Traffic Monitor ===" -ForegroundColor Cyan
            Write-Host "Target: $TargetIP`:$Port | Corporate GW: $($NetworkInfo.CorporateGateway) | Time: $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor White
            Write-Host "Local IP: $($NetworkInfo.LocalIP) | Interface: $($NetworkInfo.CorporateInterface)" -ForegroundColor Gray
            Write-Host ""
            
            # Monitor connections
            $connections = Monitor-ActiveConnections -TargetIP $TargetIP -Port $Port
            
            # Display TCP connections
            if ($connections.TCPConnections.Count -gt 0) {
                Write-Host "Active TCP Connections to Session Host:" -ForegroundColor Green
                foreach ($conn in $connections.TCPConnections) {
                    Write-Host "  $($conn.LocalAddress):$($conn.LocalPort) → $TargetIP`:$($conn.RemotePort) [$($conn.State)] ($($conn.ProcessName))" -ForegroundColor Gray
                }
            } else {
                Write-Host "No active TCP connections to session host" -ForegroundColor Yellow
            }
            
            Write-Host ""
            
            # Display UDP endpoints
            if ($connections.UDPEndpoints.Count -gt 0) {
                Write-Host "UDP Endpoints (RDP Shortpath Port $Port):" -ForegroundColor Green
                foreach ($udp in $connections.UDPEndpoints) {
                    Write-Host "  $($udp.LocalAddress):$($udp.LocalPort) [Listening] ($($udp.ProcessName))" -ForegroundColor Gray
                }
            } else {
                Write-Host "No UDP endpoints on RDP Shortpath port $Port" -ForegroundColor Yellow
            }
            
            Write-Host ""
            
            # Display RDP processes
            if ($connections.RDPProcesses.Count -gt 0) {
                Write-Host "RDP-Related Processes:" -ForegroundColor Green
                foreach ($proc in $connections.RDPProcesses) {
                    $memory = [math]::Round($proc.WorkingSet / 1MB, 1)
                    Write-Host "  $($proc.ProcessName) (PID: $($proc.Id)) - Memory: ${memory}MB" -ForegroundColor Gray
                }
            }
            
            Write-Host ""
            Write-Host "Network Path: Your PC → Corporate Network → S2S VPN → Azure → Session Host" -ForegroundColor Cyan
            Write-Host "Press Ctrl+C to stop monitoring" -ForegroundColor Yellow
            
            Start-Sleep -Seconds 3
        }
    } catch [System.Management.Automation.PipelineStoppedException] {
        Write-Host "`nMonitoring stopped by user" -ForegroundColor Yellow
    }
}

# Main execution
Write-LogMessage "Starting Site-to-Site VPN RDP traffic analysis..." -Level "Info"
Write-LogMessage "Target Session Host: $SessionHostIP" -Level "Info"
Write-LogMessage "RDP Shortpath Port: $RDPShortpathPort" -Level "Info"
Write-Host ""

# Get corporate network information
$networkInfo = Get-CorporateNetworkInfo
Write-LogMessage "Corporate Gateway: $($networkInfo.CorporateGateway)" -Level "Info"
Write-LogMessage "Corporate Interface: $($networkInfo.CorporateInterface)" -Level "Info"
Write-LogMessage "Local IP: $($networkInfo.LocalIP)" -Level "Info"

# Test S2S VPN routing
$routingInfo = Test-S2SVPNRouting -TargetIP $SessionHostIP -NetworkInfo $networkInfo

# Test connectivity
$connectivityTest = Test-RDPShortpathConnectivity -TargetIP $SessionHostIP -Port $RDPShortpathPort

# Real-time monitoring if requested
if ($RealTimeMonitoring) {
    Start-RealTimeS2SMonitoring -TargetIP $SessionHostIP -Port $RDPShortpathPort -NetworkInfo $networkInfo
} else {
    # Display analysis summary
    Write-LogMessage "`n=== SITE-TO-SITE VPN ANALYSIS SUMMARY ===" -Level "Info"
    
    if ($routingInfo -and $routingInfo.IsViaCorporateGateway) {
        Write-LogMessage "✅ ROUTING: Traffic goes through corporate gateway" -Level "Success"
        if ($routingInfo.IsLikelyS2SVPN) {
            Write-LogMessage "✅ S2S VPN: Likely using Site-to-Site VPN" -Level "Success"
        } else {
            Write-LogMessage "⚠️ S2S VPN: Cannot confirm S2S VPN usage" -Level "Warning"
        }
    } else {
        Write-LogMessage "❌ ROUTING: Traffic NOT going through corporate gateway" -Level "Error"
    }
    
    if ($connectivityTest.UDPConnectivity) {
        Write-LogMessage "✅ UDP CONNECTIVITY: RDP Shortpath port accessible" -Level "Success"
    } else {
        Write-LogMessage "❌ UDP CONNECTIVITY: RDP Shortpath port not accessible" -Level "Warning"
    }
    
    Write-LogMessage "📊 LATENCY: $($connectivityTest.Latency)ms" -Level "Info"
    
    if ($connectivityTest.TraceRouteResults.Count -gt 0) {
        Write-LogMessage "🔍 TRACE ROUTE HOPS: $($connectivityTest.TraceRouteResults.Count)" -Level "Info"
        Write-LogMessage "   First hop: $($connectivityTest.TraceRouteResults[0])" -Level "Info"
        Write-LogMessage "   Last hop: $($connectivityTest.TraceRouteResults[-1])" -Level "Info"
    }
    
    # Monitor current connections
    $connections = Monitor-ActiveConnections -TargetIP $SessionHostIP -Port $RDPShortpathPort
    
    Write-LogMessage "`n=== CURRENT CONNECTION STATUS ===" -Level "Info"
    Write-LogMessage "TCP Connections: $($connections.TCPConnections.Count)" -Level "Info"
    Write-LogMessage "UDP Endpoints: $($connections.UDPEndpoints.Count)" -Level "Info"
    Write-LogMessage "RDP Processes: $($connections.RDPProcesses.Count)" -Level "Info"
}

Write-LogMessage "`n=== VERIFICATION STEPS ===" -Level "Info"
Write-LogMessage "1. Connect to Azure Virtual Desktop session" -Level "Info"
Write-LogMessage "2. Click signal strength icon in RDP session" -Level "Info"
Write-LogMessage "3. Check for 'Transport: UDP (Private Network)'" -Level "Info"
Write-LogMessage "4. Run this script with -RealTimeMonitoring during session" -Level "Info"

Write-LogMessage "`nSite-to-Site VPN analysis completed." -Level "Success"