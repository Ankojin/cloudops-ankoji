# Configure-RDPShortpathFirewall.ps1
# Script to configure Windows Firewall and Azure NSG rules for RDP Shortpath
# Author: BAB CloudOps Team
# Date: November 3, 2025

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string[]]$ComputerNames = @("localhost"),
    
    [Parameter(Mandatory=$false)]
    [int]$RDPShortpathPort = 3390,
    
    [Parameter(Mandatory=$false)]
    [int]$STUNPortRangeStart = 38300,
    
    [Parameter(Mandatory=$false)]
    [int]$STUNPortRangeEnd = 39299,
    
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory=$false)]
    [string]$NetworkSecurityGroupName,
    
    [Parameter(Mandatory=$false)]
    [string[]]$AllowedSourceIPs = @(),
    
    [Parameter(Mandatory=$false)]
    [switch]$ConfigureWindowsFirewall,
    
    [Parameter(Mandatory=$false)]
    [switch]$ConfigureAzureNSG,
    
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

function Add-WindowsFirewallRules {
    param(
        [string]$ComputerName,
        [int]$RDPPort,
        [int]$STUNStart,
        [int]$STUNEnd,
        [string[]]$SourceIPs,
        [bool]$WhatIfMode
    )
    
    Write-LogMessage "Configuring Windows Firewall rules on $ComputerName"
    
    try {
        $scriptBlock = {
            param($RDPPort, $STUNStart, $STUNEnd, $SourceIPs, $WhatIfMode)
            
            $results = @()
            
            # Define firewall rules
            $firewallRules = @(
                @{
                    Name = "Azure Virtual Desktop - RDP Shortpath (UDP-In)"
                    Direction = "Inbound"
                    Protocol = "UDP"
                    LocalPort = $RDPPort
                    Description = "Allows inbound UDP traffic for Azure Virtual Desktop RDP Shortpath managed networks"
                },
                @{
                    Name = "Azure Virtual Desktop - RDP Shortpath STUN (UDP-In)"
                    Direction = "Inbound"
                    Protocol = "UDP"
                    LocalPort = "$STUNStart-$STUNEnd"
                    Description = "Allows inbound UDP traffic for Azure Virtual Desktop RDP Shortpath public networks with STUN/TURN"
                },
                @{
                    Name = "Azure Virtual Desktop - RDP Shortpath (UDP-Out)"
                    Direction = "Outbound"
                    Protocol = "UDP"
                    LocalPort = "Any"
                    Description = "Allows outbound UDP traffic for Azure Virtual Desktop RDP Shortpath"
                }
            )
            
            foreach ($rule in $firewallRules) {
                try {
                    # Check if rule already exists
                    $existingRule = Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
                    
                    if ($existingRule) {
                        if ($WhatIfMode) {
                            $results += "Would remove existing rule: $($rule.Name)"
                        } else {
                            Remove-NetFirewallRule -DisplayName $rule.Name
                            $results += "Removed existing rule: $($rule.Name)"
                        }
                    }
                    
                    # Create the firewall rule
                    $ruleParams = @{
                        DisplayName = $rule.Name
                        Direction = $rule.Direction
                        Protocol = $rule.Protocol
                        Action = "Allow"
                        Enabled = "True"
                        Description = $rule.Description
                    }
                    
                    if ($rule.LocalPort -ne "Any") {
                        $ruleParams.LocalPort = $rule.LocalPort
                    }
                    
                    # Add source IP restriction if specified
                    if ($SourceIPs.Count -gt 0 -and $rule.Direction -eq "Inbound") {
                        $ruleParams.RemoteAddress = $SourceIPs
                    }
                    
                    if ($WhatIfMode) {
                        $results += "Would create rule: $($rule.Name) for port $($rule.LocalPort)"
                    } else {
                        New-NetFirewallRule @ruleParams | Out-Null
                        $results += "Created rule: $($rule.Name) for port $($rule.LocalPort)"
                    }
                    
                } catch {
                    $results += "Error with rule $($rule.Name): $($_.Exception.Message)"
                }
            }
            
            return $results
        }
        
        if ($ComputerName -eq "localhost") {
            $results = & $scriptBlock -RDPPort $RDPPort -STUNStart $STUNStart -STUNEnd $STUNEnd -SourceIPs $SourceIPs -WhatIfMode $WhatIfMode
        } else {
            $results = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ArgumentList $RDPPort, $STUNStart, $STUNEnd, $SourceIPs, $WhatIfMode
        }
        
        foreach ($result in $results) {
            Write-LogMessage "  $result"
        }
        
        return @{Success = $true; Message = "Windows Firewall rules configured successfully"; Details = $results}
        
    } catch {
        Write-LogMessage "Error configuring Windows Firewall rules: $($_.Exception.Message)" -Level "Error"
        return @{Success = $false; Message = $_.Exception.Message}
    }
}

function Add-AzureNSGRules {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$NSGName,
        [int]$RDPPort,
        [int]$STUNStart,
        [int]$STUNEnd,
        [string[]]$SourceIPs,
        [bool]$WhatIfMode
    )
    
    Write-LogMessage "Configuring Azure Network Security Group rules"
    
    try {
        # Import Azure modules
        if (-not (Get-Module -Name Az.Network -ListAvailable)) {
            Write-LogMessage "Installing Az.Network module..." -Level "Warning"
            Install-Module -Name Az.Network -Force -AllowClobber -Scope CurrentUser
        }
        Import-Module -Name Az.Network -Force
        
        # Connect to Azure if not already connected
        $context = Get-AzContext
        if (-not $context -or $context.Subscription.Id -ne $SubscriptionId) {
            Connect-AzAccount -SubscriptionId $SubscriptionId | Out-Null
        }
        
        # Get the NSG
        $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $NSGName
        if (-not $nsg) {
            throw "Network Security Group '$NSGName' not found in resource group '$ResourceGroupName'"
        }
        
        # Determine source address prefix
        $sourceAddressPrefix = if ($SourceIPs.Count -gt 0) { $SourceIPs } else { "*" }
        
        # Define NSG rules
        $nsgRules = @(
            @{
                Name = "AllowRDPShortpathManagedNetworks"
                Priority = 1100
                Direction = "Inbound"
                Access = "Allow"
                Protocol = "UDP"
                SourcePortRange = "*"
                DestinationPortRange = $RDPPort.ToString()
                SourceAddressPrefix = $sourceAddressPrefix
                DestinationAddressPrefix = "*"
                Description = "Allow RDP Shortpath for managed networks"
            },
            @{
                Name = "AllowRDPShortpathSTUNTURN"
                Priority = 1101
                Direction = "Inbound"
                Access = "Allow"
                Protocol = "UDP"
                SourcePortRange = "*"
                DestinationPortRange = "$STUNStart-$STUNEnd"
                SourceAddressPrefix = "*"
                DestinationAddressPrefix = "*"
                Description = "Allow RDP Shortpath for public networks with STUN/TURN"
            },
            @{
                Name = "AllowRDPShortpathOutbound"
                Priority = 1100
                Direction = "Outbound"
                Access = "Allow"
                Protocol = "UDP"
                SourcePortRange = "*"
                DestinationPortRange = "*"
                SourceAddressPrefix = "*"
                DestinationAddressPrefix = "*"
                Description = "Allow outbound UDP for RDP Shortpath"
            }
        )
        
        $results = @()
        
        foreach ($rule in $nsgRules) {
            try {
                # Check if rule already exists
                $existingRule = $nsg.SecurityRules | Where-Object { $_.Name -eq $rule.Name }
                
                if ($existingRule) {
                    if ($WhatIfMode) {
                        $results += "Would remove existing NSG rule: $($rule.Name)"
                    } else {
                        $nsg.SecurityRules.Remove($existingRule)
                        $results += "Removed existing NSG rule: $($rule.Name)"
                    }
                }
                
                # Create new rule
                if ($WhatIfMode) {
                    $results += "Would create NSG rule: $($rule.Name) for port $($rule.DestinationPortRange)"
                } else {
                    $ruleConfig = New-AzNetworkSecurityRuleConfig @rule
                    $nsg.SecurityRules.Add($ruleConfig)
                    $results += "Created NSG rule: $($rule.Name) for port $($rule.DestinationPortRange)"
                }
                
            } catch {
                $results += "Error with NSG rule $($rule.Name): $($_.Exception.Message)"
            }
        }
        
        # Update the NSG
        if (-not $WhatIfMode) {
            Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg | Out-Null
            Write-LogMessage "Network Security Group updated successfully" -Level "Success"
        }
        
        foreach ($result in $results) {
            Write-LogMessage "  $result"
        }
        
        return @{Success = $true; Message = "Azure NSG rules configured successfully"; Details = $results}
        
    } catch {
        Write-LogMessage "Error configuring Azure NSG rules: $($_.Exception.Message)" -Level "Error"
        return @{Success = $false; Message = $_.Exception.Message}
    }
}

function Test-FirewallConnectivity {
    param(
        [string]$ComputerName,
        [int]$Port
    )
    
    Write-LogMessage "Testing firewall connectivity to $ComputerName on port $Port"
    
    try {
        $result = Test-NetConnection -ComputerName $ComputerName -Port $Port -WarningAction SilentlyContinue
        
        if ($result.TcpTestSucceeded) {
            Write-LogMessage "  Connection to $ComputerName on port $Port: SUCCESS" -Level "Success"
            return $true
        } else {
            Write-LogMessage "  Connection to $ComputerName on port $Port: FAILED" -Level "Warning"
            return $false
        }
        
    } catch {
        Write-LogMessage "  Error testing connection to $ComputerName on port $Port: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

function Show-FirewallRules {
    param([string]$ComputerName)
    
    Write-LogMessage "Current RDP Shortpath firewall rules on $ComputerName:"
    
    try {
        $scriptBlock = {
            $rules = Get-NetFirewallRule | Where-Object { $_.DisplayName -like "*Azure Virtual Desktop*" -and $_.DisplayName -like "*RDP Shortpath*" }
            
            if ($rules.Count -eq 0) {
                return "No RDP Shortpath firewall rules found"
            }
            
            $results = @()
            foreach ($rule in $rules) {
                $portFilter = $rule | Get-NetFirewallPortFilter
                $addressFilter = $rule | Get-NetFirewallAddressFilter
                
                $results += "  Rule: $($rule.DisplayName)"
                $results += "    Direction: $($rule.Direction)"
                $results += "    Action: $($rule.Action)"
                $results += "    Enabled: $($rule.Enabled)"
                $results += "    Protocol: $($portFilter.Protocol)"
                $results += "    Local Port: $($portFilter.LocalPort)"
                $results += "    Remote Address: $($addressFilter.RemoteAddress)"
                $results += ""
            }
            
            return $results
        }
        
        if ($ComputerName -eq "localhost") {
            $results = & $scriptBlock
        } else {
            $results = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock
        }
        
        if ($results -is [array]) {
            foreach ($result in $results) {
                Write-Host "  $result" -ForegroundColor Gray
            }
        } else {
            Write-Host "  $results" -ForegroundColor Gray
        }
        
    } catch {
        Write-LogMessage "Error retrieving firewall rules: $($_.Exception.Message)" -Level "Error"
    }
}

# Main execution
Write-LogMessage "Starting RDP Shortpath firewall configuration..." -Level "Info"
Write-LogMessage "RDP Shortpath Port: $RDPShortpathPort" -Level "Info"
Write-LogMessage "STUN Port Range: $STUNPortRangeStart-$STUNPortRangeEnd" -Level "Info"
Write-LogMessage "What-If Mode: $WhatIf" -Level "Info"

if ($AllowedSourceIPs.Count -gt 0) {
    Write-LogMessage "Allowed Source IPs: $($AllowedSourceIPs -join ', ')" -Level "Info"
} else {
    Write-LogMessage "Source IPs: Any (not restricted)" -Level "Warning"
}

$results = @()

# Configure Windows Firewall
if ($ConfigureWindowsFirewall) {
    Write-LogMessage "`n=== CONFIGURING WINDOWS FIREWALL ===" -Level "Info"
    
    foreach ($computer in $ComputerNames) {
        Write-LogMessage "`nProcessing computer: $computer" -Level "Info"
        
        # Show current rules
        Show-FirewallRules -ComputerName $computer
        
        # Configure firewall rules
        $firewallResult = Add-WindowsFirewallRules -ComputerName $computer -RDPPort $RDPShortpathPort -STUNStart $STUNPortRangeStart -STUNEnd $STUNPortRangeEnd -SourceIPs $AllowedSourceIPs -WhatIfMode $WhatIf
        
        $results += @{
            Computer = $computer
            Type = "WindowsFirewall"
            Result = $firewallResult
        }
    }
}

# Configure Azure NSG
if ($ConfigureAzureNSG) {
    Write-LogMessage "`n=== CONFIGURING AZURE NETWORK SECURITY GROUP ===" -Level "Info"
    
    if (-not $SubscriptionId -or -not $ResourceGroupName -or -not $NetworkSecurityGroupName) {
        Write-LogMessage "Azure NSG configuration requires SubscriptionId, ResourceGroupName, and NetworkSecurityGroupName parameters" -Level "Error"
    } else {
        $nsgResult = Add-AzureNSGRules -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -NSGName $NetworkSecurityGroupName -RDPPort $RDPShortpathPort -STUNStart $STUNPortRangeStart -STUNEnd $STUNPortRangeEnd -SourceIPs $AllowedSourceIPs -WhatIfMode $WhatIf
        
        $results += @{
            Computer = "Azure NSG: $NetworkSecurityGroupName"
            Type = "AzureNSG"
            Result = $nsgResult
        }
    }
}

# Display summary
Write-LogMessage "`n=== CONFIGURATION SUMMARY ===" -Level "Info"
foreach ($result in $results) {
    $status = if ($result.Result.Success) { "SUCCESS" } else { "FAILED" }
    $level = if ($result.Result.Success) { "Success" } else { "Error" }
    
    Write-LogMessage "$($result.Type) - $($result.Computer): $status" -Level $level
    Write-LogMessage "  Message: $($result.Result.Message)" -Level $level
}

Write-LogMessage "`nIMPORTANT SECURITY NOTES:" -Level "Warning"
Write-LogMessage "1. Review and test all firewall rules before production deployment" -Level "Warning"
Write-LogMessage "2. Consider restricting source IP addresses for managed networks" -Level "Warning"
Write-LogMessage "3. Monitor connection logs and adjust rules as needed" -Level "Warning"
Write-LogMessage "4. Ensure STUN/TURN port range doesn't conflict with other services" -Level "Warning"

Write-LogMessage "`nFirewall configuration completed." -Level "Success"

# Return results for further processing
return $results