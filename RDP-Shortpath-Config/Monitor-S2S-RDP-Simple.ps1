# Monitor-S2S-RDP-Simple.ps1
# Simple script to monitor RDP traffic over Site-to-Site VPN
# Author: BAB CloudOps Team
# Date: November 4, 2025

param(
    [string]$SessionHostIP = "10.189.50.135",
    [int]$Port = 3390,
    [switch]$RealTime
)

function Write-Status {
    param([string]$Message, [string]$Type = "Info")
    $timestamp = Get-Date -Format "HH:mm:ss"
    switch ($Type) {
        "Success" { Write-Host "[$timestamp] [SUCCESS] $Message" -ForegroundColor Green }
        "Warning" { Write-Host "[$timestamp] [WARNING] $Message" -ForegroundColor Yellow }
        "Error" { Write-Host "[$timestamp] [ERROR] $Message" -ForegroundColor Red }
        default { Write-Host "[$timestamp] [INFO] $Message" -ForegroundColor Cyan }
    }
}

function Get-NetworkGateway {
    Write-Status "Getting corporate network gateway..."
    $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Sort-Object RouteMetric | Select-Object -First 1
    $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex
    $ip = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4
    
    return @{
        Gateway = $route.NextHop
        Interface = $adapter.Name
        LocalIP = $ip.IPAddress
    }
}

function Test-S2SRouting {
    param([string]$Target, [object]$NetInfo)
    
    Write-Status "Checking route to $Target..."
    
    $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Sort-Object RouteMetric | Select-Object -First 1
    
    if ($route.NextHop -eq $NetInfo.Gateway) {
        Write-Status "Route goes through corporate gateway: $($NetInfo.Gateway)" -Type "Success"
        return $true
    } else {
        Write-Status "Route does NOT go through corporate gateway" -Type "Warning"
        Write-Status "Next hop: $($route.NextHop)" -Type "Warning"
        return $false
    }
}

function Test-UDPConnectivity {
    param([string]$Target, [int]$Port)
    
    Write-Status "Testing connectivity to $Target port $Port..."
    
    try {
        $test = Test-NetConnection -ComputerName $Target -Port $Port -WarningAction SilentlyContinue
        if ($test.TcpTestSucceeded) {
            Write-Status "Port $Port is accessible" -Type "Success"
            return $true
        } else {
            Write-Status "Port $Port is not accessible" -Type "Warning"
            return $false
        }
    } catch {
        Write-Status "Connection test failed: $($_.Exception.Message)" -Type "Error"
        return $false
    }
}

function Get-ActiveConnections {
    param([string]$Target)
    
    $tcp = @(Get-NetTCPConnection -RemoteAddress $Target -ErrorAction SilentlyContinue)
    $udp = @(Get-NetUDPEndpoint | Where-Object { $_.LocalPort -eq 3390 })
    $rdp = @(Get-Process | Where-Object { $_.ProcessName -match "mstsc|msrdc|rdpclip" })
    
    return @{
        TCP = $tcp.Count
        UDP = $udp.Count
        RDP = $rdp.Count
    }
}

# Main execution
Write-Host ""
Write-Host "=== Site-to-Site VPN RDP Monitor ===" -ForegroundColor Cyan
Write-Host ""

$networkInfo = Get-NetworkGateway
Write-Status "Corporate Gateway: $($networkInfo.Gateway)"
Write-Status "Local IP: $($networkInfo.LocalIP)"
Write-Status "Interface: $($networkInfo.Interface)"

$routeCheck = Test-S2SRouting -Target $SessionHostIP -NetInfo $networkInfo
$portCheck = Test-UDPConnectivity -Target $SessionHostIP -Port $Port

if ($RealTime) {
    Write-Status "Starting real-time monitoring (Press Ctrl+C to stop)..."
    try {
        while ($true) {
            Clear-Host
            Write-Host "=== S2S VPN RDP Monitor - $(Get-Date -Format 'HH:mm:ss') ===" -ForegroundColor Cyan
            Write-Host "Target: $SessionHostIP | Gateway: $($networkInfo.Gateway)" -ForegroundColor White
            
            $connections = Get-ActiveConnections -Target $SessionHostIP
            Write-Host "TCP: $($connections.TCP) | UDP: $($connections.UDP) | RDP: $($connections.RDP)" -ForegroundColor Gray
            
            Start-Sleep -Seconds 3
        }
    } catch {
        Write-Status "Monitoring stopped" -Type "Warning"
    }
} else {
    $connections = Get-ActiveConnections -Target $SessionHostIP
    
    Write-Host ""
    Write-Status "=== ANALYSIS SUMMARY ==="
    Write-Status "Route via Corporate Gateway: $routeCheck"
    Write-Status "Port $Port Accessible: $portCheck"
    Write-Status "Active TCP Connections: $($connections.TCP)"
    Write-Status "Active UDP Endpoints: $($connections.UDP)"
    Write-Status "RDP Processes Running: $($connections.RDP)"
    
    Write-Host ""
    Write-Status "=== VERIFICATION STEPS ==="
    Write-Status "1. Connect to Azure Virtual Desktop"
    Write-Status "2. Click connection info icon in session"
    Write-Status "3. Look for 'Transport: UDP (Private Network)'"
    Write-Status "4. Run: .\Monitor-S2S-RDP-Simple.ps1 -RealTime"
}

Write-Host ""
Write-Status "Analysis completed" -Type "Success"