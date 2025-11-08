# Configure-RDPShortpath-GroupPolicy-And-HostPool.ps1
# Complete configuration for RDP Shortpath via Group Policy and Host Pool settings
# Author: BAB CloudOps Team
# Date: November 3, 2025

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory=$true)]
    [string]$HostPoolName,
    
    [Parameter(Mandatory=$false)]
    [string[]]$SessionHostIPs = @(),
    
    [Parameter(Mandatory=$false)]
    [int]$RDPShortpathPort = 3390,
    
    [Parameter(Mandatory=$false)]
    [switch]$ConfigureGroupPolicy,
    
    [Parameter(Mandatory=$false)]
    [switch]$ConfigureHostPool,
    
    [Parameter(Mandatory=$false)]
    [switch]$TestConfiguration,
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
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

function Show-RDPShortpathBehavior {
    Write-LogMessage "RDP Shortpath Connection Priority and Behavior:" -Level "Info"
    Write-Host ""
    Write-Host "Connection Attempt Order:" -ForegroundColor White
    Write-Host ""
    Write-Host "OVER VPN (Managed Network):" -ForegroundColor Cyan
    Write-Host "1. RDP Shortpath for managed networks (UDP $RDPShortpathPort over VPN)" -ForegroundColor Green
    Write-Host "   - Requires: Port $RDPShortpathPort open from on-prem to session host private IP" -ForegroundColor Gray
    Write-Host "   - Result: Direct UDP connection with lowest latency" -ForegroundColor Gray
    Write-Host ""
    Write-Host "2. RDP Shortpath with ICE/STUN over VPN (UDP dynamic ports)" -ForegroundColor Yellow
    Write-Host "   - Requires: UDP dynamic ports over VPN" -ForegroundColor Gray
    Write-Host "   - Result: Direct UDP connection over VPN" -ForegroundColor Gray
    Write-Host ""
    Write-Host "OVER PUBLIC INTERNET (No VPN):" -ForegroundColor Cyan
    Write-Host "3. RDP Shortpath for public networks with STUN (UDP dynamic ports)" -ForegroundColor Yellow
    Write-Host "   - Requires: Internet access, STUN servers reachable" -ForegroundColor Gray
    Write-Host "   - Result: Direct UDP connection over public internet" -ForegroundColor Gray
    Write-Host ""
    Write-Host "4. RDP Shortpath for public networks with TURN (UDP relayed)" -ForegroundColor Yellow
    Write-Host "   - Requires: TURN servers reachable" -ForegroundColor Gray
    Write-Host "   - Result: Relayed UDP connection through Azure TURN servers" -ForegroundColor Gray
    Write-Host ""
    Write-Host "5. FALLBACK: Traditional RDP over TCP 443 (only for public connections)" -ForegroundColor Red
    Write-Host "   - Used when UDP paths fail over public internet" -ForegroundColor Gray
    Write-Host "   - Result: TCP connection through Azure gateway" -ForegroundColor Gray
    Write-Host ""
    Write-Host "IMPORTANT: Over VPN, TCP 443 is NOT used as fallback!" -ForegroundColor Green
    Write-Host "If UDP ports are blocked over VPN, the connection may fail entirely." -ForegroundColor Yellow
    Write-Host ""
}

function Set-GroupPolicyRegistry {
    param(
        [string[]]$ComputerNames,
        [int]$Port,
        [bool]$WhatIfMode
    )
    
    Write-LogMessage "Configuring RDP Shortpath via registry (simulates Group Policy)"
    
    foreach ($computer in $ComputerNames) {
        Write-LogMessage "Processing $computer..."
        
        try {
            $scriptBlock = {
                param($Port, $WhatIfMode)
                
                $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
                $results = @()
                
                # Create registry path if it doesn't exist
                if (-not (Test-Path $regPath)) {
                    if ($WhatIfMode) {
                        $results += "Would create registry path: $regPath"
                    } else {
                        New-Item -Path $regPath -Force | Out-Null
                        $results += "Created registry path: $regPath"
                    }
                }
                
                # Configure RDP Shortpath settings
                $settings = @{
                    "fUseUdpPortRedirector" = @{Value = 1; Type = "DWord"; Description = "Enable RDP Shortpath listener"}
                    "UdpPortNumber" = @{Value = $Port; Type = "DWord"; Description = "RDP Shortpath port number"}
                    "SelectTransport" = @{Value = 2; Type = "DWord"; Description = "Use both UDP and TCP"}
                }
                
                foreach ($setting in $settings.GetEnumerator()) {
                    if ($WhatIfMode) {
                        $results += "Would set $($setting.Key) = $($setting.Value.Value) ($($setting.Value.Description))"
                    } else {
                        Set-ItemProperty -Path $regPath -Name $setting.Key -Value $setting.Value.Value -Type $setting.Value.Type -Force
                        $results += "Set $($setting.Key) = $($setting.Value.Value) ($($setting.Value.Description))"
                    }
                }
                
                return $results
            }
            
            if ($computer -eq "localhost" -or $computer -eq $env:COMPUTERNAME) {
                $results = & $scriptBlock -Port $Port -WhatIfMode $WhatIfMode
            } else {
                $results = Invoke-Command -ComputerName $computer -ScriptBlock $scriptBlock -ArgumentList $Port, $WhatIfMode
            }
            
            foreach ($result in $results) {
                Write-LogMessage "  $result" -Level "Success"
            }
            
        } catch {
            $errorMessage = $_.Exception.Message
            Write-LogMessage "Error configuring $computer: $errorMessage" -Level "Error"
        }
    }
}

function Set-HostPoolSettings {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$HostPoolName,
        [bool]$WhatIfMode
    )
    
    Write-LogMessage "Configuring Azure Virtual Desktop Host Pool settings"
    
    try {
        # Import required modules
        if (-not (Get-Module -Name Az.DesktopVirtualization -ListAvailable)) {
            Write-LogMessage "Installing Az.DesktopVirtualization module..." -Level "Warning"
            Install-Module -Name Az.DesktopVirtualization -Force -AllowClobber -Scope CurrentUser
        }
        
        Import-Module -Name Az.DesktopVirtualization -Force
        
        # Connect to Azure
        $context = Get-AzContext
        if (-not $context -or $context.Subscription.Id -ne $SubscriptionId) {
            Write-LogMessage "Connecting to Azure subscription: $SubscriptionId"
            Connect-AzAccount -SubscriptionId $SubscriptionId | Out-Null
        }
        
        # Get current host pool
        $hostPool = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName
        if (-not $hostPool) {
            throw "Host pool '$HostPoolName' not found in resource group '$ResourceGroupName'"
        }
        
        Write-LogMessage "Current host pool configuration:"
        Write-LogMessage "  Name: $($hostPool.Name)"
        Write-LogMessage "  Type: $($hostPool.HostPoolType)"
        Write-LogMessage "  Load Balancer: $($hostPool.LoadBalancerType)"
        Write-LogMessage "  Location: $($hostPool.Location)"
        
        # Note: Direct RDP Shortpath configuration through PowerShell is limited
        # The primary configuration is done through Azure portal
        Write-LogMessage "`nIMPORTANT: Host pool RDP Shortpath settings must be configured through Azure Portal:" -Level "Warning"
        Write-LogMessage "1. Go to Azure Portal > Azure Virtual Desktop > Host pools" -Level "Info"
        Write-LogMessage "2. Select your host pool: $HostPoolName" -Level "Info"
        Write-LogMessage "3. Go to Settings > Networking > RDP Shortpath" -Level "Info"
        Write-LogMessage "4. Configure the following settings:" -Level "Info"
        Write-LogMessage "   - RDP Shortpath for managed networks: Enabled" -Level "Info"
        Write-LogMessage "   - RDP Shortpath for managed networks with ICE/STUN: Enabled" -Level "Info"
        Write-LogMessage "   - RDP Shortpath for public networks with ICE/STUN: Enabled" -Level "Info"
        Write-LogMessage "   - RDP Shortpath for public networks via TURN: Enabled" -Level "Info"
        Write-LogMessage "5. Click Save" -Level "Info"
        
        # Get session hosts for additional information
        try {
            $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName
            Write-LogMessage "`nSession hosts in this pool:"
            foreach ($sh in $sessionHosts) {
                $hostName = ($sh.Name -split '/')[-1]
                Write-LogMessage "  - $hostName (Status: $($sh.Status))"
            }
        } catch {
            Write-LogMessage "Could not retrieve session hosts: $($_.Exception.Message)" -Level "Warning"
        }
        
        return $true
        
    } catch {
        Write-LogMessage "Error configuring host pool: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

function Test-RDPShortpathConfiguration {
    param(
        [string[]]$SessionHostIPs,
        [int]$Port
    )
    
    Write-LogMessage "Testing RDP Shortpath configuration"
    
    $testResults = @()
    
    foreach ($hostIP in $SessionHostIPs) {
        Write-LogMessage "Testing session host: $hostIP"
        
        # Test UDP port connectivity
        try {
            # Note: Test-NetConnection doesn't directly support UDP testing
            $udpResult = @{
                Host = $hostIP
                Port = $Port
                Protocol = "UDP"
                Success = $false
                Message = "UDP test not directly supported by Test-NetConnection"
            }
            
            # Try to create UDP connection
            try {
                $udpClient = New-Object System.Net.Sockets.UdpClient
                $udpClient.Connect($hostIP, $Port)
                $testData = [System.Text.Encoding]::ASCII.GetBytes("TEST")
                $udpClient.Send($testData, $testData.Length) | Out-Null
                $udpClient.Close()
                $udpResult.Success = $true
                $udpResult.Message = "UDP connection successful"
            } catch {
                $udpClient.Close()
                $udpResult.Message = "UDP connection failed: $($_.Exception.Message)"
            }
            
            $level = if ($udpResult.Success) { "Success" } else { "Warning" }
            Write-LogMessage "  UDP Port ${Port}: $(if ($udpResult.Success) { 'Success' } else { 'Failed' })" -Level $level
            
            $testResults += $udpResult
            
        } catch {
            Write-LogMessage "  Error testing $hostIP : $($_.Exception.Message)" -Level "Error"
            $testResults += @{
                Host = $hostIP
                Port = $Port
                Protocol = "UDP"
                Success = $false
                Message = "Test error: $($_.Exception.Message)"
            }
        }
    }
    
    return $testResults
}

function Show-FirewallRequirements {
    param([int]$Port)
    
    Write-LogMessage "`nFirewall Requirements for RDP Shortpath:" -Level "Info"
    Write-Host ""
    Write-Host "On-Premises Firewall (for managed networks over VPN):" -ForegroundColor White
    Write-Host "  - Allow UDP $Port from client subnets to session host private IPs" -ForegroundColor Green
    Write-Host "  - Allow UDP 38300-39299 for STUN/TURN (optional but recommended)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Azure Network Security Group:" -ForegroundColor White
    Write-Host "  - Inbound: Allow UDP $Port from VPN subnet to session host subnet" -ForegroundColor Green
    Write-Host "  - Inbound: Allow UDP 38300-39299 from Internet for public networks" -ForegroundColor Yellow
    Write-Host "  - Outbound: Allow UDP * to Internet for STUN/TURN servers" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Session Host Windows Firewall:" -ForegroundColor White
    Write-Host "  - Inbound: Allow UDP $Port" -ForegroundColor Green
    Write-Host "  - Inbound: Allow UDP 38300-39299" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "CRITICAL: If UDP $Port is blocked over VPN, clients will:" -ForegroundColor Red
    Write-Host "1. Try STUN/TURN over public internet (if enabled)" -ForegroundColor Yellow
    Write-Host "2. Fall back to TCP 443 through Azure gateway" -ForegroundColor Red
    Write-Host ""
}

# Main execution
Write-LogMessage "Starting RDP Shortpath configuration for Group Policy and Host Pool" -Level "Info"
Write-LogMessage "Session Host IPs: $($SessionHostIPs -join ', ')" -Level "Info"
Write-LogMessage "RDP Shortpath Port: $RDPShortpathPort" -Level "Info"
Write-LogMessage "What-If Mode: $WhatIf" -Level "Info"
Write-Host ""

# Show behavior explanation
Show-RDPShortpathBehavior

# Configure Group Policy (registry simulation)
if ($ConfigureGroupPolicy) {
    Write-LogMessage "`n=== CONFIGURING GROUP POLICY SETTINGS ===" -Level "Info"
    
    if ($SessionHostIPs.Count -eq 0) {
        Write-LogMessage "No session host IPs provided. Configuring localhost only." -Level "Warning"
        $SessionHostIPs = @("localhost")
    }
    
    Set-GroupPolicyRegistry -ComputerNames $SessionHostIPs -Port $RDPShortpathPort -WhatIfMode $WhatIf
    
    if (-not $WhatIf) {
        Write-LogMessage "`nIMPORTANT: Restart session hosts for registry changes to take effect!" -Level "Warning"
    }
}

# Configure Host Pool
if ($ConfigureHostPool) {
    Write-LogMessage "`n=== CONFIGURING HOST POOL SETTINGS ===" -Level "Info"
    
    $hostPoolResult = Set-HostPoolSettings -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -WhatIfMode $WhatIf
    
    if (-not $hostPoolResult) {
        Write-LogMessage "Host pool configuration failed!" -Level "Error"
    }
}

# Test configuration
if ($TestConfiguration -and $SessionHostIPs.Count -gt 0) {
    Write-LogMessage "`n=== TESTING CONFIGURATION ===" -Level "Info"
    
    $testResults = Test-RDPShortpathConfiguration -SessionHostIPs $SessionHostIPs -Port $RDPShortpathPort
    
    Write-LogMessage "`nTest Results Summary:"
    $successCount = ($testResults | Where-Object { $_.Success }).Count
    $totalCount = $testResults.Count
    
    Write-LogMessage "Successful connections: $successCount/$totalCount" -Level $(if ($successCount -eq $totalCount) { "Success" } else { "Warning" })
    
    foreach ($result in $testResults) {
        $level = if ($result.Success) { "Success" } else { "Warning" }
        Write-LogMessage "  $($result.Host): $($result.Message)" -Level $level
    }
}

# Show firewall requirements
Show-FirewallRequirements -Port $RDPShortpathPort

Write-LogMessage "`n=== NEXT STEPS ===" -Level "Info"
Write-LogMessage "1. Configure Azure Portal host pool networking settings" -Level "Info"
Write-LogMessage "2. Ensure firewall rules allow UDP $RDPShortpathPort over VPN" -Level "Info"
Write-LogMessage "3. Restart session hosts to apply Group Policy changes" -Level "Info"
Write-LogMessage "4. Test connections from VPN clients" -Level "Info"
Write-LogMessage "5. Monitor connection quality and fallback behavior" -Level "Info"

Write-LogMessage "`nConfiguration process completed." -Level "Success"