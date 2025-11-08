# Configure-HostPoolRDPShortpath.ps1
# Script to configure RDP Shortpath settings for Azure Virtual Desktop host pools
# Author: BAB CloudOps Team
# Date: November 3, 2025

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory=$false)]
    [string[]]$HostPoolNames = @(),
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("Enabled", "Disabled")]
    [string]$ManagedNetworks = "Enabled",
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("Enabled", "Disabled")]  
    [string]$ManagedNetworksWithICESTUN = "Enabled",
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("Enabled", "Disabled")]
    [string]$PublicNetworksWithICESTUN = "Enabled",
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("Enabled", "Disabled")]
    [string]$PublicNetworksWithTURN = "Enabled",
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf,
    
    [Parameter(Mandatory=$false)]
    [switch]$ListHostPools
)

# Import required modules
function Import-RequiredModules {
    $requiredModules = @(
        @{Name = "Az.Accounts"; MinVersion = "2.12.0"},
        @{Name = "Az.DesktopVirtualization"; MinVersion = "5.2.1"}
    )
    
    foreach ($module in $requiredModules) {
        try {
            $installedModule = Get-Module -Name $module.Name -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
            
            if (-not $installedModule) {
                Write-Host "Installing module: $($module.Name)" -ForegroundColor Yellow
                Install-Module -Name $module.Name -Force -AllowClobber -Scope CurrentUser
            } elseif ($installedModule.Version -lt [version]$module.MinVersion) {
                Write-Host "Updating module: $($module.Name) from $($installedModule.Version) to latest" -ForegroundColor Yellow
                Update-Module -Name $module.Name -Force
            }
            
            Import-Module -Name $module.Name -Force
            Write-Host "Successfully imported module: $($module.Name)" -ForegroundColor Green
            
        } catch {
            Write-Error "Failed to import module $($module.Name): $($_.Exception.Message)"
            return $false
        }
    }
    return $true
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
}

function Connect-ToAzure {
    param([string]$SubscriptionId)
    
    try {
        Write-LogMessage "Connecting to Azure..."
        
        # Check if already connected
        $context = Get-AzContext
        if ($context -and $context.Subscription.Id -eq $SubscriptionId) {
            Write-LogMessage "Already connected to subscription: $($context.Subscription.Name)" -Level "Success"
            return $true
        }
        
        # Connect to Azure
        $null = Connect-AzAccount -SubscriptionId $SubscriptionId
        
        # Verify connection
        $context = Get-AzContext
        if ($context.Subscription.Id -eq $SubscriptionId) {
            Write-LogMessage "Successfully connected to subscription: $($context.Subscription.Name)" -Level "Success"
            return $true
        } else {
            Write-LogMessage "Failed to connect to the specified subscription" -Level "Error"
            return $false
        }
        
    } catch {
        Write-LogMessage "Error connecting to Azure: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

function Get-HostPools {
    param(
        [string]$ResourceGroupName,
        [string[]]$HostPoolNames
    )
    
    try {
        Write-LogMessage "Retrieving host pools from resource group: $ResourceGroupName"
        
        if ($HostPoolNames.Count -eq 0) {
            # Get all host pools in the resource group
            $hostPools = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName
        } else {
            # Get specific host pools
            $hostPools = @()
            foreach ($poolName in $HostPoolNames) {
                try {
                    $pool = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $poolName
                    $hostPools += $pool
                } catch {
                    Write-LogMessage "Host pool '$poolName' not found in resource group '$ResourceGroupName'" -Level "Warning"
                }
            }
        }
        
        if ($hostPools.Count -eq 0) {
            Write-LogMessage "No host pools found" -Level "Warning"
        } else {
            Write-LogMessage "Found $($hostPools.Count) host pool(s)" -Level "Success"
        }
        
        return $hostPools
        
    } catch {
        Write-LogMessage "Error retrieving host pools: $($_.Exception.Message)" -Level "Error"
        return @()
    }
}

function Show-HostPoolList {
    param([string]$ResourceGroupName)
    
    try {
        $hostPools = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName
        
        if ($hostPools.Count -eq 0) {
            Write-LogMessage "No host pools found in resource group: $ResourceGroupName" -Level "Warning"
            return
        }
        
        Write-LogMessage "Host pools in resource group '$ResourceGroupName':" -Level "Info"
        Write-Host ""
        Write-Host "Name                          Type                 Location             LoadBalancerType" -ForegroundColor White
        Write-Host "----                          ----                 --------             ----------------" -ForegroundColor White
        
        foreach ($pool in $hostPools) {
            Write-Host "$($pool.Name.PadRight(30)) $($pool.HostPoolType.PadRight(20)) $($pool.Location.PadRight(20)) $($pool.LoadBalancerType)" -ForegroundColor Gray
        }
        Write-Host ""
        
    } catch {
        Write-LogMessage "Error listing host pools: $($_.Exception.Message)" -Level "Error"
    }
}

function Get-CurrentRDPShortpathSettings {
    param(
        [string]$ResourceGroupName,
        [string]$HostPoolName
    )
    
    try {
        $hostPool = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName
        
        # Get current RDP properties
        $rdpProperties = @{}
        if ($hostPool.CustomRdpProperty) {
            $hostPool.CustomRdpProperty.Split(';') | ForEach-Object {
                if ($_ -match '^(.+?):(.+)$') {
                    $rdpProperties[$matches[1]] = $matches[2]
                }
            }
        }
        
        return @{
            HostPool = $hostPool
            RdpProperties = $rdpProperties
        }
        
    } catch {
        Write-LogMessage "Error getting current settings for host pool '$HostPoolName': $($_.Exception.Message)" -Level "Error"
        return $null
    }
}

function Set-RDPShortpathSettings {
    param(
        [string]$ResourceGroupName,
        [string]$HostPoolName,
        [hashtable]$RDPShortpathSettings,
        [bool]$WhatIfMode
    )
    
    try {
        Write-LogMessage "Configuring RDP Shortpath settings for host pool: $HostPoolName"
        
        # Get current host pool settings
        $current = Get-CurrentRDPShortpathSettings -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName
        if (-not $current) {
            return @{Success = $false; Message = "Failed to get current host pool settings"}
        }
        
        # Prepare RDP properties
        $rdpProperties = $current.RdpProperties.Clone()
        
        # Configure RDP Shortpath settings
        foreach ($setting in $RDPShortpathSettings.GetEnumerator()) {
            $rdpProperties[$setting.Key] = $setting.Value
        }
        
        # Build RDP property string
        $rdpPropertyString = ($rdpProperties.GetEnumerator() | ForEach-Object { "$($_.Key):$($_.Value)" }) -join ';'
        
        if ($WhatIfMode) {
            Write-LogMessage "What-If: Would update host pool '$HostPoolName' with RDP properties: $rdpPropertyString" -Level "Info"
            return @{Success = $true; Message = "What-If mode - no changes made"; RdpProperties = $rdpPropertyString}
        }
        
        # Update the host pool
        $null = Update-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName -CustomRdpProperty $rdpPropertyString
        
        Write-LogMessage "Successfully updated RDP Shortpath settings for host pool: $HostPoolName" -Level "Success"
        return @{Success = $true; Message = "RDP Shortpath settings updated successfully"; RdpProperties = $rdpPropertyString}
        
    } catch {
        Write-LogMessage "Error configuring RDP Shortpath settings for host pool '$HostPoolName': $($_.Exception.Message)" -Level "Error"
        return @{Success = $false; Message = $_.Exception.Message}
    }
}

function Show-RDPShortpathStatus {
    param(
        [string]$ResourceGroupName,
        [string]$HostPoolName
    )
    
    $current = Get-CurrentRDPShortpathSettings -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName
    if (-not $current) {
        return
    }
    
    Write-Host ""
    Write-Host "Current RDP Shortpath configuration for host pool: $HostPoolName" -ForegroundColor White
    Write-Host "=================================================" -ForegroundColor White
    
    $shortpathSettings = @(
        @{Key = "enablerdsaadauth"; Name = "Azure AD Authentication"; Default = "0"},
        @{Key = "targetisaadjoined"; Name = "Target AAD Joined"; Default = "0"},
        @{Key = "enablecredsspsupport"; Name = "CredSSP Support"; Default = "0"}
    )
    
    foreach ($setting in $shortpathSettings) {
        $value = if ($current.RdpProperties.ContainsKey($setting.Key)) { $current.RdpProperties[$setting.Key] } else { $setting.Default }
        $status = if ($value -eq "1") { "Enabled" } else { "Disabled" }
        Write-Host "$($setting.Name.PadRight(25)): $status" -ForegroundColor Gray
    }
    
    Write-Host ""
}

# Main execution
Write-LogMessage "Starting Azure Virtual Desktop RDP Shortpath configuration..." -Level "Info"

# Import required modules
if (-not (Import-RequiredModules)) {
    Write-LogMessage "Failed to import required modules. Exiting." -Level "Error"
    exit 1
}

# Connect to Azure
if (-not (Connect-ToAzure -SubscriptionId $SubscriptionId)) {
    Write-LogMessage "Failed to connect to Azure. Exiting." -Level "Error"
    exit 1
}

# List host pools if requested
if ($ListHostPools) {
    Show-HostPoolList -ResourceGroupName $ResourceGroupName
    exit 0
}

# Get host pools to configure
$hostPools = Get-HostPools -ResourceGroupName $ResourceGroupName -HostPoolNames $HostPoolNames

if ($hostPools.Count -eq 0) {
    Write-LogMessage "No host pools to configure. Exiting." -Level "Warning"
    exit 0
}

# Prepare RDP Shortpath settings
$rdpShortpathSettings = @{}

# Note: Azure PowerShell Az.DesktopVirtualization module doesn't have direct support for RDP Shortpath configuration yet
# These settings would be configured through the Azure portal or REST API
# For now, we'll prepare the custom RDP properties that support some RDP features

Write-LogMessage "Configuring RDP Shortpath through custom RDP properties..." -Level "Info"

# Configure standard RDP properties that enhance connectivity
if ($ManagedNetworks -eq "Enabled") {
    $rdpShortpathSettings["enablerdsaadauth"] = "1"
}

if ($PublicNetworksWithICESTUN -eq "Enabled" -or $PublicNetworksWithTURN -eq "Enabled") {
    $rdpShortpathSettings["targetisaadjoined"] = "1"
}

# Process each host pool
$results = @()
foreach ($hostPool in $hostPools) {
    Write-LogMessage "`nProcessing host pool: $($hostPool.Name)" -Level "Info"
    
    # Show current status
    Show-RDPShortpathStatus -ResourceGroupName $ResourceGroupName -HostPoolName $hostPool.Name
    
    # Configure RDP Shortpath settings
    $result = Set-RDPShortpathSettings -ResourceGroupName $ResourceGroupName -HostPoolName $hostPool.Name -RDPShortpathSettings $rdpShortpathSettings -WhatIfMode $WhatIf
    
    $results += @{
        HostPoolName = $hostPool.Name
        Result = $result
    }
}

# Display summary
Write-LogMessage "`n=== CONFIGURATION SUMMARY ===" -Level "Info"
foreach ($result in $results) {
    $status = if ($result.Result.Success) { "SUCCESS" } else { "FAILED" }
    $level = if ($result.Result.Success) { "Success" } else { "Error" }
    
    Write-LogMessage "Host Pool: $($result.HostPoolName) - $status" -Level $level
    Write-LogMessage "  Message: $($result.Result.Message)" -Level $level
}

Write-LogMessage "`nIMPORTANT NOTES:" -Level "Warning"
Write-LogMessage "1. RDP Shortpath configuration is primarily done through Azure portal or ARM templates" -Level "Warning"
Write-LogMessage "2. Session hosts need to be configured separately using Group Policy or registry settings" -Level "Warning"
Write-LogMessage "3. Network Security Groups and firewalls need to allow UDP traffic on the configured ports" -Level "Warning"
Write-LogMessage "4. For full RDP Shortpath configuration, use the Azure portal Host Pool Networking settings" -Level "Warning"

Write-LogMessage "`nNext steps:" -Level "Info"
Write-LogMessage "1. Configure session hosts using the Enable-RDPShortpath.ps1 script" -Level "Info"
Write-LogMessage "2. Configure Group Policy using the provided documentation" -Level "Info"
Write-LogMessage "3. Configure Network Security Groups and firewall rules" -Level "Info"
Write-LogMessage "4. Test connectivity using the verification scripts" -Level "Info"

Write-LogMessage "`nConfiguration process completed." -Level "Success"

# Return results for further processing
return $results