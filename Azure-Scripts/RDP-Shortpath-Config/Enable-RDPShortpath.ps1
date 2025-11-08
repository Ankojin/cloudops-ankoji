# Enable-RDPShortpath.ps1
# Script to enable RDP Shortpath listener on session hosts
# Author: BAB CloudOps Team
# Date: November 3, 2025

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string[]]$ComputerNames = @("localhost"),
    
    [Parameter(Mandatory=$false)]
    [int]$ListenerPort = 3390,
    
    [Parameter(Mandatory=$false)]
    [switch]$EnableFirewallRule,
    
    [Parameter(Mandatory=$false)]
    [switch]$ConfigureUDP,
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
)

function Write-LogMessage {
    param(
        [string]$Message,
        [ValidateSet("Info", "Warning", "Error")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    switch ($Level) {
        "Info" { Write-Host $logMessage -ForegroundColor Green }
        "Warning" { Write-Host $logMessage -ForegroundColor Yellow }
        "Error" { Write-Host $logMessage -ForegroundColor Red }
    }
}

function Enable-RDPShortpathListener {
    param(
        [string]$ComputerName,
        [int]$Port,
        [bool]$WhatIfMode
    )
    
    Write-LogMessage "Configuring RDP Shortpath listener on $ComputerName (Port: $Port)"
    
    try {
        $scriptBlock = {
            param($Port, $WhatIfMode)
            
            $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
            
            if (-not (Test-Path $regPath)) {
                if ($WhatIfMode) {
                    Write-Output "Would create registry path: $regPath"
                } else {
                    New-Item -Path $regPath -Force | Out-Null
                    Write-Output "Created registry path: $regPath"
                }
            }
            
            # Enable RDP Shortpath listener
            if ($WhatIfMode) {
                Write-Output "Would set fUseUdpPortRedirector = 1"
                Write-Output "Would set UdpPortNumber = $Port"
            } else {
                Set-ItemProperty -Path $regPath -Name "fUseUdpPortRedirector" -Value 1 -Type DWord
                Set-ItemProperty -Path $regPath -Name "UdpPortNumber" -Value $Port -Type DWord
                Write-Output "Enabled RDP Shortpath listener on port $Port"
            }
            
            return @{Success = $true; Message = "RDP Shortpath listener configured successfully"}
        }
        
        if ($ComputerName -eq "localhost") {
            $result = & $scriptBlock -Port $Port -WhatIfMode $WhatIfMode
        } else {
            $result = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ArgumentList $Port, $WhatIfMode
        }
        
        Write-LogMessage $result.Message
        return $result
        
    } catch {
        Write-LogMessage "Error configuring RDP Shortpath listener: $($_.Exception.Message)" -Level "Error"
        return @{Success = $false; Message = $_.Exception.Message}
    }
}

function Enable-UDPTransport {
    param(
        [string]$ComputerName,
        [bool]$WhatIfMode
    )
    
    Write-LogMessage "Configuring UDP transport on $ComputerName"
    
    try {
        $scriptBlock = {
            param($WhatIfMode)
            
            $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
            
            if (-not (Test-Path $regPath)) {
                if ($WhatIfMode) {
                    Write-Output "Would create registry path: $regPath"
                } else {
                    New-Item -Path $regPath -Force | Out-Null
                    Write-Output "Created registry path: $regPath"
                }
            }
            
            # Enable UDP transport (2 = Use both UDP and TCP)
            if ($WhatIfMode) {
                Write-Output "Would set SelectTransport = 2 (UDP and TCP)"
            } else {
                Set-ItemProperty -Path $regPath -Name "SelectTransport" -Value 2 -Type DWord
                Write-Output "Enabled UDP transport (UDP and TCP)"
            }
            
            return @{Success = $true; Message = "UDP transport configured successfully"}
        }
        
        if ($ComputerName -eq "localhost") {
            $result = & $scriptBlock -WhatIfMode $WhatIfMode
        } else {
            $result = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ArgumentList $WhatIfMode
        }
        
        Write-LogMessage $result.Message
        return $result
        
    } catch {
        Write-LogMessage "Error configuring UDP transport: $($_.Exception.Message)" -Level "Error"
        return @{Success = $false; Message = $_.Exception.Message}
    }
}

function Add-FirewallRule {
    param(
        [string]$ComputerName,
        [int]$Port,
        [bool]$WhatIfMode
    )
    
    Write-LogMessage "Configuring Windows Firewall rule on $ComputerName for port $Port"
    
    try {
        $scriptBlock = {
            param($Port, $WhatIfMode)
            
            $ruleName = "Azure Virtual Desktop - RDP Shortpath (UDP-In)"
            
            # Check if rule already exists
            $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
            
            if ($existingRule) {
                if ($WhatIfMode) {
                    Write-Output "Would remove existing firewall rule: $ruleName"
                    Write-Output "Would create new firewall rule for port $Port"
                } else {
                    Remove-NetFirewallRule -DisplayName $ruleName
                    Write-Output "Removed existing firewall rule: $ruleName"
                }
            }
            
            if ($WhatIfMode) {
                Write-Output "Would create firewall rule: $ruleName on port $Port"
            } else {
                New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol UDP -LocalPort $Port -Action Allow -Enabled True
                Write-Output "Created firewall rule: $ruleName on port $Port"
            }
            
            return @{Success = $true; Message = "Firewall rule configured successfully"}
        }
        
        if ($ComputerName -eq "localhost") {
            $result = & $scriptBlock -Port $Port -WhatIfMode $WhatIfMode
        } else {
            $result = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ArgumentList $Port, $WhatIfMode
        }
        
        Write-LogMessage $result.Message
        return $result
        
    } catch {
        Write-LogMessage "Error configuring firewall rule: $($_.Exception.Message)" -Level "Error"
        return @{Success = $false; Message = $_.Exception.Message}
    }
}

# Main execution
Write-LogMessage "Starting RDP Shortpath configuration..." -Level "Info"
Write-LogMessage "Target Computers: $($ComputerNames -join ', ')" -Level "Info"
Write-LogMessage "Listener Port: $ListenerPort" -Level "Info"
Write-LogMessage "What-If Mode: $WhatIf" -Level "Info"

$results = @()

foreach ($computer in $ComputerNames) {
    Write-LogMessage "`nProcessing computer: $computer" -Level "Info"
    
    $computerResult = @{
        ComputerName = $computer
        ListenerConfig = $null
        UDPConfig = $null
        FirewallConfig = $null
        Success = $true
    }
    
    # Configure RDP Shortpath listener
    $computerResult.ListenerConfig = Enable-RDPShortpathListener -ComputerName $computer -Port $ListenerPort -WhatIfMode $WhatIf
    if (-not $computerResult.ListenerConfig.Success) {
        $computerResult.Success = $false
    }
    
    # Configure UDP transport if requested
    if ($ConfigureUDP) {
        $computerResult.UDPConfig = Enable-UDPTransport -ComputerName $computer -WhatIfMode $WhatIf
        if (-not $computerResult.UDPConfig.Success) {
            $computerResult.Success = $false
        }
    }
    
    # Configure firewall rule if requested
    if ($EnableFirewallRule) {
        $computerResult.FirewallConfig = Add-FirewallRule -ComputerName $computer -Port $ListenerPort -WhatIfMode $WhatIf
        if (-not $computerResult.FirewallConfig.Success) {
            $computerResult.Success = $false
        }
    }
    
    $results += $computerResult
}

# Display summary
Write-LogMessage "`n=== CONFIGURATION SUMMARY ===" -Level "Info"
foreach ($result in $results) {
    $status = if ($result.Success) { "SUCCESS" } else { "FAILED" }
    $level = if ($result.Success) { "Info" } else { "Error" }
    
    Write-LogMessage "Computer: $($result.ComputerName) - $status" -Level $level
    
    if ($result.ListenerConfig) {
        Write-LogMessage "  RDP Shortpath Listener: $($result.ListenerConfig.Message)" -Level $level
    }
    
    if ($result.UDPConfig) {
        Write-LogMessage "  UDP Transport: $($result.UDPConfig.Message)" -Level $level
    }
    
    if ($result.FirewallConfig) {
        Write-LogMessage "  Firewall Rule: $($result.FirewallConfig.Message)" -Level $level
    }
}

if (-not $WhatIf) {
    Write-LogMessage "`nIMPORTANT: Restart the session hosts for the changes to take effect." -Level "Warning"
}

Write-LogMessage "`nRDP Shortpath configuration completed." -Level "Info"

# Return results for further processing
return $results