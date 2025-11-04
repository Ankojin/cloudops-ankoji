# Configure-RDPShortpath-Local.ps1
# Script to configure RDP Shortpath directly on the session host (run locally)
# Author: BAB CloudOps Team
# Date: November 3, 2025
# Usage: Run this script directly on the session host as Administrator

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [int]$RDPShortpathPort = 3390,
    
    [Parameter(Mandatory=$false)]
    [int]$STUNPortRangeStart = 38300,
    
    [Parameter(Mandatory=$false)]
    [int]$STUNPortRangeEnd = 39299,
    
    [Parameter(Mandatory=$false)]
    [switch]$ConfigureFirewall,
    
    [Parameter(Mandatory=$false)]
    [switch]$RestartRequired,
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
)

# Require Administrator privileges
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "This script requires Administrator privileges. Please run as Administrator."
    exit 1
}

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
    
    # Also log to file
    $logMessage | Out-File -FilePath "RDP-Shortpath-Local-Config.log" -Append
}

function Get-CurrentConfiguration {
    Write-LogMessage "Checking current RDP Shortpath configuration..."
    
    $config = @{
        ComputerName = $env:COMPUTERNAME
        UDPTransport = "Unknown"
        RDPShortpathListener = "Unknown"
        ListenerPort = 0
        FirewallRules = @()
        OSVersion = (Get-WmiObject -Class Win32_OperatingSystem).Caption
        Errors = @()
    }
    
    try {
        # Check UDP transport configuration
        $regKey = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -ErrorAction SilentlyContinue
        
        if ($regKey -and $regKey.PSObject.Properties.name -contains "SelectTransport") {
            switch ($regKey.SelectTransport) {
                1 { $config.UDPTransport = "TCP Only (UDP Disabled)" }
                2 { $config.UDPTransport = "UDP and TCP Enabled" }
                default { $config.UDPTransport = "Unknown Value: $($regKey.SelectTransport)" }
            }
        } else {
            $config.UDPTransport = "Default (UDP Enabled)"
        }
        
        # Check RDP Shortpath listener
        if ($regKey -and $regKey.PSObject.Properties.name -contains "fUseUdpPortRedirector") {
            if ($regKey.fUseUdpPortRedirector -eq 1) {
                $config.RDPShortpathListener = "Enabled"
                if ($regKey.PSObject.Properties.name -contains "UdpPortNumber") {
                    $config.ListenerPort = $regKey.UdpPortNumber
                } else {
                    $config.ListenerPort = 3390
                }
            } else {
                $config.RDPShortpathListener = "Disabled"
            }
        } else {
            $config.RDPShortpathListener = "Not Configured"
        }
        
        # Check firewall rules
        $firewallRules = Get-NetFirewallRule | Where-Object { 
            $_.DisplayName -like "*Azure Virtual Desktop*" -and 
            $_.DisplayName -like "*RDP Shortpath*" 
        }
        
        foreach ($rule in $firewallRules) {
            $portFilter = $rule | Get-NetFirewallPortFilter
            $config.FirewallRules += @{
                Name = $rule.DisplayName
                Direction = $rule.Direction
                Enabled = $rule.Enabled
                Action = $rule.Action
                Protocol = $portFilter.Protocol
                LocalPort = $portFilter.LocalPort
            }
        }
        
    } catch {
        $config.Errors += "Error checking configuration: $($_.Exception.Message)"
    }
    
    return $config
}

function Set-RDPShortpathConfiguration {
    param(
        [int]$Port,
        [bool]$WhatIfMode
    )
    
    Write-LogMessage "Configuring RDP Shortpath settings..."
    
    try {
        $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
        
        # Create registry path if it doesn't exist
        if (-not (Test-Path $regPath)) {
            if ($WhatIfMode) {
                Write-LogMessage "Would create registry path: $regPath" -Level "Info"
            } else {
                New-Item -Path $regPath -Force | Out-Null
                Write-LogMessage "Created registry path: $regPath" -Level "Success"
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
                Write-LogMessage "Would set $($setting.Key) = $($setting.Value.Value) ($($setting.Value.Description))" -Level "Info"
            } else {
                Set-ItemProperty -Path $regPath -Name $setting.Key -Value $setting.Value.Value -Type $setting.Value.Type -Force
                Write-LogMessage "Set $($setting.Key) = $($setting.Value.Value) ($($setting.Value.Description))" -Level "Success"
            }
        }
        
        return $true
        
    } catch {
        Write-LogMessage "Error configuring RDP Shortpath: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

function Set-FirewallRules {
    param(
        [int]$RDPPort,
        [int]$STUNStart,
        [int]$STUNEnd,
        [bool]$WhatIfMode
    )
    
    Write-LogMessage "Configuring Windows Firewall rules..."
    
    try {
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
                        Write-LogMessage "Would remove existing rule: $($rule.Name)" -Level "Info"
                    } else {
                        Remove-NetFirewallRule -DisplayName $rule.Name
                        Write-LogMessage "Removed existing rule: $($rule.Name)" -Level "Success"
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
                
                if ($WhatIfMode) {
                    Write-LogMessage "Would create rule: $($rule.Name) for port $($rule.LocalPort)" -Level "Info"
                } else {
                    New-NetFirewallRule @ruleParams | Out-Null
                    Write-LogMessage "Created rule: $($rule.Name) for port $($rule.LocalPort)" -Level "Success"
                }
                
            } catch {
                Write-LogMessage "Error with rule $($rule.Name): $($_.Exception.Message)" -Level "Error"
            }
        }
        
        return $true
        
    } catch {
        Write-LogMessage "Error configuring firewall rules: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

function Test-RDPShortpathListener {
    param([int]$Port)
    
    Write-LogMessage "Testing RDP Shortpath listener on port $Port..."
    
    try {
        $listener = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
        if ($listener) {
            Write-LogMessage "Port $Port is in use by another service" -Level "Warning"
            return $false
        }
        
        # Try to bind to the UDP port
        $udpClient = New-Object System.Net.Sockets.UdpClient
        try {
            $udpClient.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $Port))
            $udpClient.Close()
            Write-LogMessage "Port $Port is available for RDP Shortpath" -Level "Success"
            return $true
        } catch {
            $udpClient.Close()
            Write-LogMessage "Port $Port test failed: $($_.Exception.Message)" -Level "Warning"
            return $false
        }
        
    } catch {
        Write-LogMessage "Error testing port $Port : $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

function Show-ConfigurationSummary {
    param($BeforeConfig, $AfterConfig)
    
    Write-LogMessage "`n=== CONFIGURATION SUMMARY ===" -Level "Info"
    Write-Host ""
    Write-Host "Computer: $($AfterConfig.ComputerName)" -ForegroundColor White
    Write-Host "OS: $($AfterConfig.OSVersion)" -ForegroundColor Gray
    Write-Host ""
    
    Write-Host "BEFORE:" -ForegroundColor Yellow
    Write-Host "  UDP Transport: $($BeforeConfig.UDPTransport)" -ForegroundColor Gray
    Write-Host "  RDP Shortpath Listener: $($BeforeConfig.RDPShortpathListener)" -ForegroundColor Gray
    Write-Host "  Listener Port: $($BeforeConfig.ListenerPort)" -ForegroundColor Gray
    Write-Host "  Firewall Rules: $($BeforeConfig.FirewallRules.Count)" -ForegroundColor Gray
    Write-Host ""
    
    Write-Host "AFTER:" -ForegroundColor Green
    Write-Host "  UDP Transport: $($AfterConfig.UDPTransport)" -ForegroundColor Gray
    Write-Host "  RDP Shortpath Listener: $($AfterConfig.RDPShortpathListener)" -ForegroundColor Gray
    Write-Host "  Listener Port: $($AfterConfig.ListenerPort)" -ForegroundColor Gray
    Write-Host "  Firewall Rules: $($AfterConfig.FirewallRules.Count)" -ForegroundColor Gray
    Write-Host ""
    
    if ($AfterConfig.Errors.Count -gt 0) {
        Write-Host "ERRORS:" -ForegroundColor Red
        foreach ($error in $AfterConfig.Errors) {
            Write-Host "  - $error" -ForegroundColor Red
        }
        Write-Host ""
    }
}

# Main execution
Write-LogMessage "Starting RDP Shortpath local configuration on $env:COMPUTERNAME" -Level "Info"
Write-LogMessage "RDP Shortpath Port: $RDPShortpathPort" -Level "Info"
Write-LogMessage "STUN Port Range: $STUNPortRangeStart-$STUNPortRangeEnd" -Level "Info"
Write-LogMessage "Configure Firewall: $ConfigureFirewall" -Level "Info"
Write-LogMessage "What-If Mode: $WhatIf" -Level "Info"
Write-Host ""

# Get current configuration
Write-LogMessage "=== CHECKING CURRENT CONFIGURATION ===" -Level "Info"
$beforeConfig = Get-CurrentConfiguration

Write-LogMessage "Current Status:"
Write-LogMessage "  UDP Transport: $($beforeConfig.UDPTransport)" -Level $(if ($beforeConfig.UDPTransport -like "*TCP Only*") { "Warning" } else { "Info" })
Write-LogMessage "  RDP Shortpath Listener: $($beforeConfig.RDPShortpathListener)" -Level $(if ($beforeConfig.RDPShortpathListener -eq "Enabled") { "Success" } else { "Warning" })
Write-LogMessage "  Listener Port: $($beforeConfig.ListenerPort)" -Level "Info"
Write-LogMessage "  Firewall Rules: $($beforeConfig.FirewallRules.Count) found" -Level $(if ($beforeConfig.FirewallRules.Count -gt 0) { "Success" } else { "Warning" })

# Test port availability
Write-LogMessage "`n=== TESTING PORT AVAILABILITY ===" -Level "Info"
$portAvailable = Test-RDPShortpathListener -Port $RDPShortpathPort

# Configure RDP Shortpath
Write-LogMessage "`n=== CONFIGURING RDP SHORTPATH ===" -Level "Info"
$configSuccess = Set-RDPShortpathConfiguration -Port $RDPShortpathPort -WhatIfMode $WhatIf

# Configure firewall if requested
if ($ConfigureFirewall) {
    Write-LogMessage "`n=== CONFIGURING FIREWALL RULES ===" -Level "Info"
    $firewallSuccess = Set-FirewallRules -RDPPort $RDPShortpathPort -STUNStart $STUNPortRangeStart -STUNEnd $STUNPortRangeEnd -WhatIfMode $WhatIf
}

# Get updated configuration
Write-LogMessage "`n=== CHECKING UPDATED CONFIGURATION ===" -Level "Info"
$afterConfig = Get-CurrentConfiguration

# Show summary
Show-ConfigurationSummary -BeforeConfig $beforeConfig -AfterConfig $afterConfig

# Final recommendations
Write-LogMessage "`n=== NEXT STEPS ===" -Level "Info"

if (-not $WhatIf) {
    if ($configSuccess) {
        Write-LogMessage "✅ RDP Shortpath configuration applied successfully" -Level "Success"
    } else {
        Write-LogMessage "❌ RDP Shortpath configuration failed" -Level "Error"
    }
    
    if ($ConfigureFirewall -and $firewallSuccess) {
        Write-LogMessage "✅ Firewall rules configured successfully" -Level "Success"
    } elseif ($ConfigureFirewall) {
        Write-LogMessage "❌ Firewall configuration failed" -Level "Error"
    }
    
    Write-LogMessage "`nIMPORTANT: Restart this session host for changes to take effect!" -Level "Warning"
    Write-LogMessage "After restart:" -Level "Info"
    Write-LogMessage "1. Test RDP connections from VPN clients" -Level "Info"
    Write-LogMessage "2. Check Connection Information dialog shows 'UDP (Private Network)'" -Level "Info"
    Write-LogMessage "3. Configure host pool networking settings in Azure Portal" -Level "Info"
    Write-LogMessage "4. Ensure on-premises firewall allows UDP $RDPShortpathPort over VPN" -Level "Info"
    
    if ($RestartRequired) {
        Write-LogMessage "`nRestarting computer in 30 seconds (Ctrl+C to cancel)..." -Level "Warning"
        Start-Sleep -Seconds 30
        Restart-Computer -Force
    }
    
} else {
    Write-LogMessage "What-If mode completed. No changes were made." -Level "Info"
    Write-LogMessage "To apply changes, run the script again without -WhatIf parameter" -Level "Info"
}

Write-LogMessage "`nConfiguration log saved to: RDP-Shortpath-Local-Config.log" -Level "Info"
Write-LogMessage "Local configuration completed." -Level "Success"