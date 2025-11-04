# Deploy-RDPShortpath-Firewall.ps1
# Script to deploy RDP Shortpath firewall rules to multiple session hosts
# Author: BAB CloudOps Team
# Date: November 4, 2025

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$SessionHostsFile = "session-hosts.txt",
    
    [Parameter(Mandatory=$false)]
    [string[]]$RemoteAddresses = @("10.80.0.0/16", "10.189.0.0/16"),
    
    [Parameter(Mandatory=$false)]
    [string]$RuleName = "Allow RDP Shortpath UDP",
    
    [Parameter(Mandatory=$false)]
    [int]$Port = 3390,
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf,
    
    [Parameter(Mandatory=$false)]
    [switch]$RemoveExisting
)

function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    switch ($Level) {
        "Success" { Write-Host "[$timestamp] [SUCCESS] $Message" -ForegroundColor Green }
        "Warning" { Write-Host "[$timestamp] [WARNING] $Message" -ForegroundColor Yellow }
        "Error" { Write-Host "[$timestamp] [ERROR] $Message" -ForegroundColor Red }
        default { Write-Host "[$timestamp] [INFO] $Message" -ForegroundColor Cyan }
    }
}

function Test-HostConnectivity {
    param([string]$ComputerName)
    
    try {
        $result = Test-NetConnection -ComputerName $ComputerName -Port 5985 -WarningAction SilentlyContinue
        return $result.TcpTestSucceeded
    } catch {
        return $false
    }
}

function Deploy-FirewallRule {
    param(
        [string]$ComputerName,
        [string[]]$Networks,
        [string]$DisplayName,
        [int]$LocalPort,
        [bool]$TestMode = $false
    )
    
    $scriptBlock = {
        param($RuleName, $Networks, $Port, $TestMode)
        
        $results = @{
            ComputerName = $env:COMPUTERNAME
            Success = $false
            ExistingRules = @()
            NewRule = $null
            Error = ""
        }
        
        try {
            # Check for existing rules
            $existingRules = Get-NetFirewallRule -DisplayName "*RDP*Shortpath*" -ErrorAction SilentlyContinue
            $results.ExistingRules = $existingRules | Select-Object DisplayName, Enabled, Direction, Action
            
            if ($TestMode) {
                $results.NewRule = "WHATIF: Would create rule '$RuleName' for UDP port $Port"
                $results.Success = $true
                return $results
            }
            
            # Remove existing RDP Shortpath rules if they exist
            if ($existingRules) {
                Write-Host "Removing existing RDP Shortpath rules..." -ForegroundColor Yellow
                $existingRules | Remove-NetFirewallRule -Confirm:$false
            }
            
            # Create new firewall rule
            $newRule = New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Protocol UDP -LocalPort $Port -Action Allow -RemoteAddress $Networks -Profile Domain -Enabled True
            
            $results.NewRule = "Created rule: $RuleName for UDP port $Port"
            $results.Success = $true
            
        } catch {
            $results.Error = $_.Exception.Message
            $results.Success = $false
        }
        
        return $results
    }
    
    try {
        Write-Log "Deploying firewall rule to $ComputerName..."
        
        if ($TestMode) {
            Write-Log "Running in WHATIF mode - no changes will be made" -Level "Warning"
        }
        
        $result = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ArgumentList $DisplayName, $Networks, $LocalPort, $TestMode -ErrorAction Stop
        
        if ($result.Success) {
            Write-Log "SUCCESS on $ComputerName`: $($result.NewRule)" -Level "Success"
            
            if ($result.ExistingRules.Count -gt 0) {
                Write-Log "Existing rules found on $ComputerName`:" -Level "Warning"
                foreach ($rule in $result.ExistingRules) {
                    Write-Log "  - $($rule.DisplayName) [$($rule.Enabled)]" -Level "Warning"
                }
            }
        } else {
            Write-Log "FAILED on $ComputerName`: $($result.Error)" -Level "Error"
        }
        
        return $result
        
    } catch {
        Write-Log "ERROR connecting to $ComputerName`: $($_.Exception.Message)" -Level "Error"
        return @{
            ComputerName = $ComputerName
            Success = $false
            Error = $_.Exception.Message
            ExistingRules = @()
            NewRule = $null
        }
    }
}

# Main execution
Write-Host ""
Write-Host "=== RDP Shortpath Firewall Deployment ===" -ForegroundColor Cyan
Write-Host ""

# Check if session hosts file exists
if (-not (Test-Path $SessionHostsFile)) {
    Write-Log "Session hosts file not found: $SessionHostsFile" -Level "Error"
    Write-Log "Creating sample file..." -Level "Warning"
    
    @"
# Session Hosts List
# One hostname or IP address per line
# Lines starting with # are comments
10.189.50.135
session-host-01.domain.com
session-host-02.domain.com
"@ | Out-File -FilePath $SessionHostsFile -Encoding UTF8
    
    Write-Log "Sample file created: $SessionHostsFile" -Level "Success"
    Write-Log "Please edit the file with your actual session hosts and run the script again" -Level "Warning"
    exit 1
}

# Read session hosts from file
$sessionHosts = Get-Content $SessionHostsFile | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$' }

if ($sessionHosts.Count -eq 0) {
    Write-Log "No session hosts found in $SessionHostsFile" -Level "Error"
    exit 1
}

Write-Log "Session hosts file: $SessionHostsFile"
Write-Log "Found $($sessionHosts.Count) session hosts"
Write-Log "Remote addresses: $($RemoteAddresses -join ', ')"
Write-Log "Rule name: $RuleName"
Write-Log "UDP Port: $Port"

if ($WhatIf) {
    Write-Log "WHATIF MODE - No changes will be made" -Level "Warning"
}

Write-Host ""

# Deploy to each session host
$results = @()
$successCount = 0
$failureCount = 0

foreach ($sessionHost in $sessionHosts) {
    $sessionHost = $sessionHost.Trim()
    
    Write-Log "Processing: $sessionHost"
    
    # Test connectivity
    Write-Log "Testing connectivity to $sessionHost..."
    if (-not (Test-HostConnectivity -ComputerName $sessionHost)) {
        Write-Log "Cannot connect to $sessionHost (WinRM port 5985)" -Level "Error"
        $failureCount++
        continue
    }
    
    # Deploy firewall rule
    $result = Deploy-FirewallRule -ComputerName $sessionHost -Networks $RemoteAddresses -DisplayName $RuleName -LocalPort $Port -TestMode $WhatIf
    $results += $result
    
    if ($result.Success) {
        $successCount++
    } else {
        $failureCount++
    }
    
    Write-Host ""
}

# Summary
Write-Host ""
Write-Log "=== DEPLOYMENT SUMMARY ===" -Level "Info"
Write-Log "Total session hosts: $($sessionHosts.Count)"
Write-Log "Successful deployments: $successCount" -Level "Success"
Write-Log "Failed deployments: $failureCount" $(if ($failureCount -gt 0) { "Error" } else { "Info" })

if ($WhatIf) {
    Write-Host ""
    Write-Log "This was a WHATIF run - no actual changes were made" -Level "Warning"
    Write-Log "To apply changes, run: .\Deploy-RDPShortpath-Firewall.ps1" -Level "Info"
}

# Generate report
$reportPath = "RDP-Shortpath-Deployment-Report-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
$results | ConvertTo-Json -Depth 3 | Out-File -FilePath $reportPath -Encoding UTF8
Write-Log "Detailed report saved: $reportPath" -Level "Info"

Write-Host ""
Write-Log "Deployment completed" -Level "Success"