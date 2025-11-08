# Test-RDPShortpath.ps1
# Script to verify RDP Shortpath configuration and connectivity
# Author: BAB CloudOps Team
# Date: November 3, 2025

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string[]]$SessionHosts = @(),
    
    [Parameter(Mandatory=$false)]
    [string[]]$ClientComputers = @("localhost"),
    
    [Parameter(Mandatory=$false)]
    [int]$RDPShortpathPort = 3390,
    
    [Parameter(Mandatory=$false)]
    [string]$HostPoolResourceGroup,
    
    [Parameter(Mandatory=$false)]
    [string]$HostPoolName,
    
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$false)]
    [switch]$TestNetworkConnectivity,
    
    [Parameter(Mandatory=$false)]
    [switch]$TestSTUNConnectivity,
    
    [Parameter(Mandatory=$false)]
    [switch]$GenerateReport,
    
    [Parameter(Mandatory=$false)]
    [string]$ReportPath = "RDP-Shortpath-Test-Report.html"
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
    
    return @{
        Timestamp = $timestamp
        Level = $Level
        Message = $Message
    }
}

function Test-SessionHostConfiguration {
    param([string]$ComputerName)
    
    Write-LogMessage "Testing session host configuration on: $ComputerName"
    
    try {
        $scriptBlock = {
            $results = @{
                ComputerName = $env:COMPUTERNAME
                UDPTransport = "Unknown"
                RDPShortpathListener = "Unknown"
                ListenerPort = 0
                FirewallRules = @()
                Errors = @()
            }
            
            try {
                # Check UDP transport configuration
                $regKey = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -ErrorAction SilentlyContinue
                
                if ($regKey -and $regKey.PSObject.Properties.name -contains "SelectTransport") {
                    switch ($regKey.SelectTransport) {
                        1 { $results.UDPTransport = "TCP Only (UDP Disabled)" }
                        2 { $results.UDPTransport = "UDP and TCP Enabled" }
                        default { $results.UDPTransport = "Unknown Value: $($regKey.SelectTransport)" }
                    }
                } else {
                    $results.UDPTransport = "Default (UDP Enabled)"
                }
                
                # Check RDP Shortpath listener
                if ($regKey -and $regKey.PSObject.Properties.name -contains "fUseUdpPortRedirector") {
                    if ($regKey.fUseUdpPortRedirector -eq 1) {
                        $results.RDPShortpathListener = "Enabled"
                        if ($regKey.PSObject.Properties.name -contains "UdpPortNumber") {
                            $results.ListenerPort = $regKey.UdpPortNumber
                        } else {
                            $results.ListenerPort = 3390
                        }
                    } else {
                        $results.RDPShortpathListener = "Disabled"
                    }
                } else {
                    $results.RDPShortpathListener = "Not Configured"
                }
                
                # Check firewall rules
                $firewallRules = Get-NetFirewallRule | Where-Object { 
                    $_.DisplayName -like "*Azure Virtual Desktop*" -and 
                    $_.DisplayName -like "*RDP Shortpath*" 
                }
                
                foreach ($rule in $firewallRules) {
                    $portFilter = $rule | Get-NetFirewallPortFilter
                    $results.FirewallRules += @{
                        Name = $rule.DisplayName
                        Direction = $rule.Direction
                        Enabled = $rule.Enabled
                        Action = $rule.Action
                        Protocol = $portFilter.Protocol
                        LocalPort = $portFilter.LocalPort
                    }
                }
                
            } catch {
                $results.Errors += "Error checking configuration: $($_.Exception.Message)"
            }
            
            return $results
        }
        
        if ($ComputerName -eq "localhost") {
            $result = & $scriptBlock
        } else {
            $result = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock
        }
        
        # Display results
        Write-LogMessage "  UDP Transport: $($result.UDPTransport)" -Level $(if ($result.UDPTransport -like "*TCP Only*") { "Warning" } else { "Success" })
        Write-LogMessage "  RDP Shortpath Listener: $($result.RDPShortpathListener)" -Level $(if ($result.RDPShortpathListener -eq "Enabled") { "Success" } else { "Warning" })
        
        if ($result.ListenerPort -gt 0) {
            Write-LogMessage "  Listener Port: $($result.ListenerPort)" -Level "Info"
        }
        
        Write-LogMessage "  Firewall Rules: $($result.FirewallRules.Count) found" -Level $(if ($result.FirewallRules.Count -gt 0) { "Success" } else { "Warning" })
        
        foreach ($error in $result.Errors) {
            Write-LogMessage "  Error: $error" -Level "Error"
        }
        
        return $result
        
    } catch {
        Write-LogMessage "Error testing session host configuration: $($_.Exception.Message)" -Level "Error"
        return @{
            ComputerName = $ComputerName
            UDPTransport = "Error"
            RDPShortpathListener = "Error"
            ListenerPort = 0
            FirewallRules = @()
            Errors = @($_.Exception.Message)
        }
    }
}

function Test-ClientConfiguration {
    param([string]$ComputerName)
    
    Write-LogMessage "Testing client configuration on: $ComputerName"
    
    try {
        $scriptBlock = {
            $results = @{
                ComputerName = $env:COMPUTERNAME
                UDPEnabled = "Unknown"
                ClientVersion = "Unknown"
                Errors = @()
            }
            
            try {
                # Check client UDP configuration
                $regKey = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\Client" -ErrorAction SilentlyContinue
                
                if ($regKey -and $regKey.PSObject.Properties.name -contains "fClientDisableUDP") {
                    if ($regKey.fClientDisableUDP -eq 1) {
                        $results.UDPEnabled = "Disabled"
                    } else {
                        $results.UDPEnabled = "Enabled"
                    }
                } else {
                    $results.UDPEnabled = "Default (Enabled)"
                }
                
                # Try to get Remote Desktop client version
                $rdpClient = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\MSRDC" -ErrorAction SilentlyContinue
                if ($rdpClient -and $rdpClient.Version) {
                    $results.ClientVersion = $rdpClient.Version
                }
                
            } catch {
                $results.Errors += "Error checking client configuration: $($_.Exception.Message)"
            }
            
            return $results
        }
        
        if ($ComputerName -eq "localhost") {
            $result = & $scriptBlock
        } else {
            $result = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock
        }
        
        # Display results
        Write-LogMessage "  UDP Enabled: $($result.UDPEnabled)" -Level $(if ($result.UDPEnabled -like "*Disabled*") { "Warning" } else { "Success" })
        Write-LogMessage "  Client Version: $($result.ClientVersion)" -Level "Info"
        
        foreach ($error in $result.Errors) {
            Write-LogMessage "  Error: $error" -Level "Error"
        }
        
        return $result
        
    } catch {
        Write-LogMessage "Error testing client configuration: $($_.Exception.Message)" -Level "Error"
        return @{
            ComputerName = $ComputerName
            UDPEnabled = "Error"
            ClientVersion = "Unknown"
            Errors = @($_.Exception.Message)
        }
    }
}

function Test-NetworkConnectivity {
    param(
        [string]$TargetHost,
        [int]$Port,
        [string]$Protocol = "UDP"
    )
    
    Write-LogMessage "Testing $Protocol connectivity to $TargetHost on port $Port"
    
    try {
        if ($Protocol -eq "TCP") {
            $result = Test-NetConnection -ComputerName $TargetHost -Port $Port -WarningAction SilentlyContinue
            return @{
                Success = $result.TcpTestSucceeded
                Details = "TCP connection test"
                RemoteAddress = $result.RemoteAddress
                SourceAddress = $result.SourceAddress.IPAddress
            }
        } else {
            # For UDP, we'll try to create a UDP client and send a test packet
            $udpClient = New-Object System.Net.Sockets.UdpClient
            try {
                $udpClient.Connect($TargetHost, $Port)
                $testData = [System.Text.Encoding]::ASCII.GetBytes("TEST")
                $udpClient.Send($testData, $testData.Length) | Out-Null
                $udpClient.Close()
                
                return @{
                    Success = $true
                    Details = "UDP connection test (packet sent)"
                    RemoteAddress = $TargetHost
                    SourceAddress = "Local"
                }
            } catch {
                $udpClient.Close()
                throw
            }
        }
        
    } catch {
        return @{
            Success = $false
            Details = "Connection failed: $($_.Exception.Message)"
            RemoteAddress = $TargetHost
            SourceAddress = "Unknown"
        }
    }
}

function Test-STUNConnectivity {
    param([string]$ClientComputer)
    
    Write-LogMessage "Testing STUN/TURN connectivity from: $ClientComputer"
    
    try {
        # Download and run avdnettest.exe if available
        $avdTestPath = "$env:TEMP\avdnettest.exe"
        
        $scriptBlock = {
            param($TestPath)
            
            $results = @{
                STUNTest = "Not Available"
                TURNTest = "Not Available"
                NATType = "Unknown"
                Errors = @()
            }
            
            try {
                # Try to download avdnettest.exe if not present
                if (-not (Test-Path $TestPath)) {
                    $downloadUrl = "https://raw.githubusercontent.com/Azure/RDS-Templates/master/AVD-TestShortpath/avdnettest.exe"
                    try {
                        Invoke-WebRequest -Uri $downloadUrl -OutFile $TestPath -UseBasicParsing
                    } catch {
                        $results.Errors += "Could not download avdnettest.exe: $($_.Exception.Message)"
                        return $results
                    }
                }
                
                if (Test-Path $TestPath) {
                    # Run the network test
                    $testOutput = & $TestPath 2>&1
                    
                    # Parse the output
                    $outputText = $testOutput -join "`n"
                    
                    if ($outputText -match "Checking TURN support.*OK") {
                        $results.TURNTest = "Success"
                    } elseif ($outputText -match "Checking TURN support.*FAIL") {
                        $results.TURNTest = "Failed"
                    }
                    
                    if ($outputText -match "NAT type appears to be '(.+?)'") {
                        $results.NATType = $matches[1]
                    }
                    
                    if ($outputText -match "Shortpath.*very likely to work") {
                        $results.STUNTest = "Success"
                    } elseif ($outputText -match "Shortpath.*may not work") {
                        $results.STUNTest = "Warning"
                    }
                    
                } else {
                    $results.Errors += "avdnettest.exe not available"
                }
                
            } catch {
                $results.Errors += "Error running STUN/TURN test: $($_.Exception.Message)"
            }
            
            return $results
        }
        
        if ($ClientComputer -eq "localhost") {
            $result = & $scriptBlock -TestPath $avdTestPath
        } else {
            $result = Invoke-Command -ComputerName $ClientComputer -ScriptBlock $scriptBlock -ArgumentList $avdTestPath
        }
        
        # Display results
        Write-LogMessage "  STUN Test: $($result.STUNTest)" -Level $(if ($result.STUNTest -eq "Success") { "Success" } elseif ($result.STUNTest -eq "Warning") { "Warning" } else { "Info" })
        Write-LogMessage "  TURN Test: $($result.TURNTest)" -Level $(if ($result.TURNTest -eq "Success") { "Success" } else { "Info" })
        Write-LogMessage "  NAT Type: $($result.NATType)" -Level "Info"
        
        foreach ($error in $result.Errors) {
            Write-LogMessage "  Error: $error" -Level "Error"
        }
        
        return $result
        
    } catch {
        Write-LogMessage "Error testing STUN connectivity: $($_.Exception.Message)" -Level "Error"
        return @{
            STUNTest = "Error"
            TURNTest = "Error"
            NATType = "Unknown"
            Errors = @($_.Exception.Message)
        }
    }
}

function Get-HostPoolSessionHosts {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$HostPoolName
    )
    
    try {
        Write-LogMessage "Retrieving session hosts from host pool: $HostPoolName"
        
        # Import required modules
        if (-not (Get-Module -Name Az.DesktopVirtualization -ListAvailable)) {
            Write-LogMessage "Installing Az.DesktopVirtualization module..." -Level "Warning"
            Install-Module -Name Az.DesktopVirtualization -Force -AllowClobber -Scope CurrentUser
        }
        Import-Module -Name Az.DesktopVirtualization -Force
        
        # Connect to Azure if not already connected
        $context = Get-AzContext
        if (-not $context -or $context.Subscription.Id -ne $SubscriptionId) {
            Connect-AzAccount -SubscriptionId $SubscriptionId | Out-Null
        }
        
        # Get session hosts
        $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName
        
        $hostNames = @()
        foreach ($sessionHost in $sessionHosts) {
            # Extract the computer name from the session host name
            if ($sessionHost.Name -match '([^/]+)$') {
                $hostNames += $matches[1]
            }
        }
        
        Write-LogMessage "Found $($hostNames.Count) session hosts" -Level "Success"
        return $hostNames
        
    } catch {
        Write-LogMessage "Error retrieving session hosts: $($_.Exception.Message)" -Level "Error"
        return @()
    }
}

function Generate-TestReport {
    param(
        [hashtable]$TestResults,
        [string]$OutputPath
    )
    
    Write-LogMessage "Generating test report: $OutputPath"
    
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>RDP Shortpath Configuration Test Report</title>
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
        <h1>RDP Shortpath Configuration Test Report</h1>
        <p>Generated on: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>
    </div>
"@

    # Session Hosts section
    if ($TestResults.SessionHosts) {
        $html += @"
    <div class="section">
        <h2>Session Host Configuration</h2>
        <table>
            <tr>
                <th>Computer Name</th>
                <th>UDP Transport</th>
                <th>RDP Shortpath Listener</th>
                <th>Listener Port</th>
                <th>Firewall Rules</th>
                <th>Status</th>
            </tr>
"@
        
        foreach ($host in $TestResults.SessionHosts) {
            $statusClass = "status-ok"
            $status = "OK"
            
            if ($host.UDPTransport -like "*TCP Only*" -or $host.RDPShortpathListener -ne "Enabled" -or $host.FirewallRules.Count -eq 0) {
                $statusClass = "status-warning"
                $status = "Warning"
            }
            
            if ($host.Errors.Count -gt 0) {
                $statusClass = "status-error"
                $status = "Error"
            }
            
            $html += @"
            <tr class="$statusClass">
                <td>$($host.ComputerName)</td>
                <td>$($host.UDPTransport)</td>
                <td>$($host.RDPShortpathListener)</td>
                <td>$($host.ListenerPort)</td>
                <td>$($host.FirewallRules.Count)</td>
                <td>$status</td>
            </tr>
"@
        }
        
        $html += "</table></div>"
    }

    # Client Computers section
    if ($TestResults.Clients) {
        $html += @"
    <div class="section">
        <h2>Client Configuration</h2>
        <table>
            <tr>
                <th>Computer Name</th>
                <th>UDP Enabled</th>
                <th>Client Version</th>
                <th>Status</th>
            </tr>
"@
        
        foreach ($client in $TestResults.Clients) {
            $statusClass = if ($client.UDPEnabled -like "*Disabled*") { "status-warning" } else { "status-ok" }
            $status = if ($client.UDPEnabled -like "*Disabled*") { "Warning" } else { "OK" }
            
            if ($client.Errors.Count -gt 0) {
                $statusClass = "status-error"
                $status = "Error"
            }
            
            $html += @"
            <tr class="$statusClass">
                <td>$($client.ComputerName)</td>
                <td>$($client.UDPEnabled)</td>
                <td>$($client.ClientVersion)</td>
                <td>$status</td>
            </tr>
"@
        }
        
        $html += "</table></div>"
    }

    # Network Connectivity section
    if ($TestResults.NetworkTests) {
        $html += @"
    <div class="section">
        <h2>Network Connectivity Tests</h2>
        <table>
            <tr>
                <th>Source</th>
                <th>Target</th>
                <th>Protocol</th>
                <th>Port</th>
                <th>Result</th>
                <th>Details</th>
            </tr>
"@
        
        foreach ($test in $TestResults.NetworkTests) {
            $statusClass = if ($test.Success) { "status-ok" } else { "status-error" }
            $status = if ($test.Success) { "Success" } else { "Failed" }
            
            $html += @"
            <tr class="$statusClass">
                <td>$($test.Source)</td>
                <td>$($test.Target)</td>
                <td>$($test.Protocol)</td>
                <td>$($test.Port)</td>
                <td>$status</td>
                <td>$($test.Details)</td>
            </tr>
"@
        }
        
        $html += "</table></div>"
    }

    $html += @"
    <div class="section">
        <h2>Summary</h2>
        <p>This report shows the current configuration status of RDP Shortpath for Azure Virtual Desktop.</p>
        <p>Review any warnings or errors and follow the configuration guides to resolve issues.</p>
    </div>
</body>
</html>
"@

    try {
        $html | Out-File -FilePath $OutputPath -Encoding UTF8
        Write-LogMessage "Test report generated successfully: $OutputPath" -Level "Success"
        return $true
    } catch {
        Write-LogMessage "Error generating test report: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

# Main execution
Write-LogMessage "Starting RDP Shortpath configuration test..." -Level "Info"

$testResults = @{
    SessionHosts = @()
    Clients = @()
    NetworkTests = @()
    STUNTests = @()
}

# Get session hosts from Azure if host pool is specified
if ($HostPoolResourceGroup -and $HostPoolName -and $SubscriptionId) {
    $azureSessionHosts = Get-HostPoolSessionHosts -SubscriptionId $SubscriptionId -ResourceGroupName $HostPoolResourceGroup -HostPoolName $HostPoolName
    $SessionHosts += $azureSessionHosts
}

# Test session host configuration
if ($SessionHosts.Count -gt 0) {
    Write-LogMessage "`n=== TESTING SESSION HOST CONFIGURATION ===" -Level "Info"
    
    foreach ($sessionHost in $SessionHosts) {
        $result = Test-SessionHostConfiguration -ComputerName $sessionHost
        $testResults.SessionHosts += $result
    }
}

# Test client configuration
Write-LogMessage "`n=== TESTING CLIENT CONFIGURATION ===" -Level "Info"

foreach ($client in $ClientComputers) {
    $result = Test-ClientConfiguration -ComputerName $client
    $testResults.Clients += $result
}

# Test network connectivity
if ($TestNetworkConnectivity -and $SessionHosts.Count -gt 0) {
    Write-LogMessage "`n=== TESTING NETWORK CONNECTIVITY ===" -Level "Info"
    
    foreach ($client in $ClientComputers) {
        foreach ($sessionHost in $SessionHosts) {
            Write-LogMessage "Testing connectivity from $client to $sessionHost"
            
            # Test RDP Shortpath port
            $udpTest = Test-NetworkConnectivity -TargetHost $sessionHost -Port $RDPShortpathPort -Protocol "UDP"
            $testResults.NetworkTests += @{
                Source = $client
                Target = $sessionHost
                Protocol = "UDP"
                Port = $RDPShortpathPort
                Success = $udpTest.Success
                Details = $udpTest.Details
            }
            
            $level = if ($udpTest.Success) { "Success" } else { "Warning" }
            $statusText = if ($udpTest.Success) { 'Success' } else { 'Failed' }
            Write-LogMessage "  UDP Port ${RDPShortpathPort}: $statusText" -Level $level
        }
    }
}

# Test STUN connectivity
if ($TestSTUNConnectivity) {
    Write-LogMessage "`n=== TESTING STUN/TURN CONNECTIVITY ===" -Level "Info"
    
    foreach ($client in $ClientComputers) {
        $result = Test-STUNConnectivity -ClientComputer $client
        $testResults.STUNTests += @{
            Computer = $client
            Result = $result
        }
    }
}

# Generate report
if ($GenerateReport) {
    Write-LogMessage "`n=== GENERATING TEST REPORT ===" -Level "Info"
    Generate-TestReport -TestResults $testResults -OutputPath $ReportPath | Out-Null
}

# Display summary
Write-LogMessage "`n=== TEST SUMMARY ===" -Level "Info"

$sessionHostsOK = ($testResults.SessionHosts | Where-Object { $_.UDPTransport -notlike "*TCP Only*" -and $_.RDPShortpathListener -eq "Enabled" -and $_.FirewallRules.Count -gt 0 }).Count
$sessionHostsTotal = $testResults.SessionHosts.Count

$clientsOK = ($testResults.Clients | Where-Object { $_.UDPEnabled -notlike "*Disabled*" }).Count
$clientsTotal = $testResults.Clients.Count

Write-LogMessage "Session Hosts: $sessionHostsOK/$sessionHostsTotal configured correctly" -Level $(if ($sessionHostsOK -eq $sessionHostsTotal -and $sessionHostsTotal -gt 0) { "Success" } else { "Warning" })
Write-LogMessage "Clients: $clientsOK/$clientsTotal configured correctly" -Level $(if ($clientsOK -eq $clientsTotal -and $clientsTotal -gt 0) { "Success" } else { "Warning" })

if ($TestNetworkConnectivity) {
    $networkTestsOK = ($testResults.NetworkTests | Where-Object { $_.Success }).Count
    $networkTestsTotal = $testResults.NetworkTests.Count
    Write-LogMessage "Network Tests: $networkTestsOK/$networkTestsTotal successful" -Level $(if ($networkTestsOK -eq $networkTestsTotal -and $networkTestsTotal -gt 0) { "Success" } else { "Warning" })
}

Write-LogMessage "`nRDP Shortpath configuration test completed." -Level "Success"

# Return results for further processing
return $testResults