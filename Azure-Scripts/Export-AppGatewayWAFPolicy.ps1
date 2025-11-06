<#
.SYNOPSIS
    Export Application Gateway WAF policies across multiple Azure subscriptions.

.DESCRIPTION
    This script exports Application Gateway WAF policies from Azure subscriptions.
    It can export either standalone WAF policies or WAF configurations from Application Gateways.
    Supports multiple output formats including JSON, CSV, and detailed reports.

.PARAMETER SubscriptionId
    Specific Azure subscription ID to export from (optional, if not provided will scan all accessible subscriptions)

.PARAMETER CsvPath
    Path to CSV file containing subscription IDs to process (optional)

.PARAMETER OutputPath
    Path to save the exported WAF policies (default: current directory)

.PARAMETER ExportFormat
    Export format: JSON, CSV, or Both (default: Both)

.PARAMETER IncludeAppGatewayWAF
    Include WAF configurations from Application Gateways (default: true)

.PARAMETER IncludeStandaloneWAFPolicies
    Include standalone WAF policies (default: true)

.PARAMETER LogPath
    Path for the log file (optional)

.EXAMPLE
    .\Export-AppGatewayWAFPolicy.ps1 -OutputPath ".\WAF-Export"

.EXAMPLE
    .\Export-AppGatewayWAFPolicy.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012" -ExportFormat "JSON"

.EXAMPLE
    .\Export-AppGatewayWAFPolicy.ps1 -CsvPath ".\subscriptions.csv" -OutputPath ".\WAF-Policies"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $false)]
    [string]$CsvPath,
    
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\WAF-Export-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
    
    [Parameter(Mandatory = $false)]
    [ValidateSet('JSON', 'CSV', 'Both')]
    [string]$ExportFormat = 'Both',
    
    [Parameter(Mandatory = $false)]
    [bool]$IncludeAppGatewayWAF = $true,
    
    [Parameter(Mandatory = $false)]
    [bool]$IncludeStandaloneWAFPolicies = $true,
    
    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\waf-export-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
)

# Function to write log messages
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Console output with colors
    switch ($Level) {
        'Info'    { Write-Host $logMessage -ForegroundColor Cyan }
        'Warning' { Write-Host $logMessage -ForegroundColor Yellow }
        'Error'   { Write-Host $logMessage -ForegroundColor Red }
        'Success' { Write-Host $logMessage -ForegroundColor Green }
    }
    
    # Write to log file
    try {
        Add-Content -Path $LogPath -Value $logMessage -ErrorAction SilentlyContinue
    }
    catch {
        Write-Warning "Failed to write to log file: $_"
    }
}

# Function to validate prerequisites
function Test-Prerequisites {
    Write-Log "Checking prerequisites..." -Level Info
    
    # Check if Az PowerShell module is installed
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-Log "Az.Accounts module is not installed. Please install Azure PowerShell modules." -Level Error
        return $false
    }
    
    if (-not (Get-Module -ListAvailable -Name Az.Network)) {
        Write-Log "Az.Network module is not installed. Please install Azure PowerShell modules." -Level Error
        return $false
    }
    
    # Check if logged into Azure
    try {
        $context = Get-AzContext
        if (-not $context) {
            Write-Log "Not logged into Azure. Please run Connect-AzAccount first." -Level Error
            return $false
        }
        Write-Log "Connected to Azure as: $($context.Account.Id)" -Level Success
    }
    catch {
        Write-Log "Error checking Azure context: $_" -Level Error
        return $false
    }
    
    return $true
}

# Function to get subscriptions to process
function Get-SubscriptionsToProcess {
    $subscriptions = @()
    
    if ($SubscriptionId) {
        Write-Log "Processing specific subscription: $SubscriptionId" -Level Info
        $subscriptions += $SubscriptionId
    }
    elseif ($CsvPath) {
        Write-Log "Reading subscriptions from CSV: $CsvPath" -Level Info
        try {
            $csvData = Import-Csv -Path $CsvPath
            foreach ($row in $csvData) {
                if ($row.SubscriptionId) {
                    $subscriptions += $row.SubscriptionId
                }
            }
        }
        catch {
            Write-Log "Error reading CSV file: $_" -Level Error
            return @()
        }
    }
    else {
        Write-Log "Getting all accessible subscriptions..." -Level Info
        try {
            $allSubs = Get-AzSubscription
            $subscriptions = $allSubs | ForEach-Object { $_.Id }
        }
        catch {
            Write-Log "Error getting subscriptions: $_" -Level Error
            return @()
        }
    }
    
    Write-Log "Found $($subscriptions.Count) subscription(s) to process" -Level Info
    return $subscriptions
}

# Function to export standalone WAF policies
function Export-StandaloneWAFPolicies {
    param(
        [string]$SubscriptionId,
        [ref]$AllWAFPolicies
    )
    
    Write-Log "Exporting standalone WAF policies from subscription: $SubscriptionId" -Level Info
    
    try {
        $wafPolicies = Get-AzApplicationGatewayFirewallPolicy
        
        foreach ($policy in $wafPolicies) {
            $wafPolicyDetails = [PSCustomObject]@{
                SubscriptionId = $SubscriptionId
                PolicyType = "Standalone"
                PolicyName = $policy.Name
                ResourceGroupName = $policy.ResourceGroupName
                Location = $policy.Location
                ProvisioningState = $policy.ProvisioningState
                PolicyMode = $policy.PolicySettings.Mode
                PolicyState = $policy.PolicySettings.State
                RequestBodyCheck = $policy.PolicySettings.RequestBodyCheck
                MaxRequestBodySizeInKb = $policy.PolicySettings.MaxRequestBodySizeInKb
                FileUploadLimitInMb = $policy.PolicySettings.FileUploadLimitInMb
                ManagedRuleSetType = if ($policy.ManagedRules.ManagedRuleSets) { 
                    ($policy.ManagedRules.ManagedRuleSets | ForEach-Object { "$($_.RuleSetType)_$($_.RuleSetVersion)" }) -join "; " 
                } else { "None" }
                CustomRulesCount = if ($policy.CustomRules) { $policy.CustomRules.Count } else { 0 }
                ExclusionCount = if ($policy.ManagedRules.Exclusions) { $policy.ManagedRules.Exclusions.Count } else { 0 }
                ResourceId = $policy.Id
                Tags = if ($policy.Tags) { ($policy.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "; " } else { "" }
                ExportTimestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            }
            
            $AllWAFPolicies.Value += $wafPolicyDetails
            
            # Export detailed JSON for each policy
            if ($ExportFormat -eq 'JSON' -or $ExportFormat -eq 'Both') {
                $jsonPath = Join-Path $OutputPath "WAFPolicy_$($policy.Name)_$($SubscriptionId.Substring(0,8)).json"
                $policy | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
                Write-Log "Exported detailed JSON for policy: $($policy.Name)" -Level Success
            }
        }
        
        Write-Log "Found $($wafPolicies.Count) standalone WAF policies in subscription $SubscriptionId" -Level Info
    }
    catch {
        Write-Log "Error exporting WAF policies from subscription $SubscriptionId : $_" -Level Error
    }
}

# Function to export Application Gateway WAF configurations
function Export-ApplicationGatewayWAF {
    param(
        [string]$SubscriptionId,
        [ref]$AllWAFPolicies
    )
    
    Write-Log "Exporting Application Gateway WAF configurations from subscription: $SubscriptionId" -Level Info
    
    try {
        $appGateways = Get-AzApplicationGateway
        
        foreach ($gateway in $appGateways) {
            if ($gateway.WebApplicationFirewallConfiguration -or $gateway.FirewallPolicy) {
                
                $wafConfig = $gateway.WebApplicationFirewallConfiguration
                $firewallPolicy = $gateway.FirewallPolicy
                
                $wafDetails = [PSCustomObject]@{
                    SubscriptionId = $SubscriptionId
                    PolicyType = "ApplicationGateway"
                    PolicyName = if ($firewallPolicy) { Split-Path $firewallPolicy.Id -Leaf } else { "$($gateway.Name)_WAFConfig" }
                    ResourceGroupName = $gateway.ResourceGroupName
                    ApplicationGatewayName = $gateway.Name
                    Location = $gateway.Location
                    ProvisioningState = $gateway.ProvisioningState
                    PolicyMode = if ($wafConfig) { $wafConfig.FirewallMode } else { "N/A" }
                    PolicyState = if ($wafConfig) { if ($wafConfig.Enabled) { "Enabled" } else { "Disabled" } } else { "N/A" }
                    RequestBodyCheck = if ($wafConfig) { $wafConfig.RequestBodyCheck } else { "N/A" }
                    MaxRequestBodySizeInKb = if ($wafConfig) { $wafConfig.MaxRequestBodySizeInKb } else { "N/A" }
                    FileUploadLimitInMb = if ($wafConfig) { $wafConfig.FileUploadLimitInMb } else { "N/A" }
                    ManagedRuleSetType = if ($wafConfig -and $wafConfig.RuleSetType) { 
                        "$($wafConfig.RuleSetType)_$($wafConfig.RuleSetVersion)" 
                    } else { "N/A" }
                    CustomRulesCount = "N/A"
                    ExclusionCount = if ($wafConfig -and $wafConfig.DisabledRuleGroups) { 
                        $wafConfig.DisabledRuleGroups.Count 
                    } else { 0 }
                    FirewallPolicyId = if ($firewallPolicy) { $firewallPolicy.Id } else { "None" }
                    ResourceId = $gateway.Id
                    Tags = if ($gateway.Tags) { ($gateway.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "; " } else { "" }
                    ExportTimestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                }
                
                $AllWAFPolicies.Value += $wafDetails
                
                # Export detailed JSON for each Application Gateway with WAF
                if ($ExportFormat -eq 'JSON' -or $ExportFormat -eq 'Both') {
                    $jsonPath = Join-Path $OutputPath "AppGateway_$($gateway.Name)_$($SubscriptionId.Substring(0,8)).json"
                    $gateway | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
                    Write-Log "Exported detailed JSON for Application Gateway: $($gateway.Name)" -Level Success
                }
            }
        }
        
        $wafEnabledGateways = $appGateways | Where-Object { $_.WebApplicationFirewallConfiguration -or $_.FirewallPolicy }
        Write-Log "Found $($wafEnabledGateways.Count) Application Gateways with WAF in subscription $SubscriptionId" -Level Info
    }
    catch {
        Write-Log "Error exporting Application Gateway WAF from subscription $SubscriptionId : $_" -Level Error
    }
}

# Main execution
try {
    Write-Log "Starting WAF Policy Export Script" -Level Info
    Write-Log "Parameters: OutputPath=$OutputPath, ExportFormat=$ExportFormat" -Level Info
    
    # Validate prerequisites
    if (-not (Test-Prerequisites)) {
        Write-Log "Prerequisites check failed. Exiting." -Level Error
        exit 1
    }
    
    # Create output directory
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        Write-Log "Created output directory: $OutputPath" -Level Success
    }
    
    # Get subscriptions to process
    $subscriptions = Get-SubscriptionsToProcess
    if ($subscriptions.Count -eq 0) {
        Write-Log "No subscriptions to process. Exiting." -Level Error
        exit 1
    }
    
    # Initialize collections
    $allWAFPolicies = @()
    $processedCount = 0
    $errorCount = 0
    
    # Process each subscription
    foreach ($subId in $subscriptions) {
        try {
            Write-Log "Processing subscription: $subId" -Level Info
            
            # Set subscription context
            Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
            Write-Log "Successfully set context to subscription: $subId" -Level Success
            
            # Export standalone WAF policies if requested
            if ($IncludeStandaloneWAFPolicies) {
                Export-StandaloneWAFPolicies -SubscriptionId $subId -AllWAFPolicies ([ref]$allWAFPolicies)
            }
            
            # Export Application Gateway WAF configurations if requested
            if ($IncludeAppGatewayWAF) {
                Export-ApplicationGatewayWAF -SubscriptionId $subId -AllWAFPolicies ([ref]$allWAFPolicies)
            }
            
            $processedCount++
        }
        catch {
            Write-Log "Error processing subscription $subId : $_" -Level Error
            $errorCount++
        }
    }
    
    # Export summary data
    if ($allWAFPolicies.Count -gt 0) {
        
        # Export CSV summary if requested
        if ($ExportFormat -eq 'CSV' -or $ExportFormat -eq 'Both') {
            $csvPath = Join-Path $OutputPath "WAF-Policies-Summary.csv"
            $allWAFPolicies | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
            Write-Log "Exported CSV summary to: $csvPath" -Level Success
        }
        
        # Export JSON summary if requested
        if ($ExportFormat -eq 'JSON' -or $ExportFormat -eq 'Both') {
            $jsonSummaryPath = Join-Path $OutputPath "WAF-Policies-Summary.json"
            $allWAFPolicies | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonSummaryPath -Encoding UTF8
            Write-Log "Exported JSON summary to: $jsonSummaryPath" -Level Success
        }
        
        # Generate statistics
        $standaloneCount = ($allWAFPolicies | Where-Object { $_.PolicyType -eq "Standalone" }).Count
        $appGatewayCount = ($allWAFPolicies | Where-Object { $_.PolicyType -eq "ApplicationGateway" }).Count
        
        Write-Log "Export completed successfully!" -Level Success
        Write-Log "Summary:" -Level Info
        Write-Log "  - Subscriptions processed: $processedCount" -Level Info
        Write-Log "  - Subscriptions with errors: $errorCount" -Level Info
        Write-Log "  - Total WAF policies/configurations found: $($allWAFPolicies.Count)" -Level Info
        Write-Log "  - Standalone WAF policies: $standaloneCount" -Level Info
        Write-Log "  - Application Gateway WAF configurations: $appGatewayCount" -Level Info
        Write-Log "  - Output directory: $OutputPath" -Level Info
        
        # Create summary report
        $summaryReport = @"
WAF Policy Export Summary Report
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

Subscriptions processed: $processedCount
Subscriptions with errors: $errorCount
Total WAF policies/configurations found: $($allWAFPolicies.Count)
Standalone WAF policies: $standaloneCount
Application Gateway WAF configurations: $appGatewayCount

Output files created:
- WAF-Policies-Summary.csv (if CSV export enabled)
- WAF-Policies-Summary.json (if JSON export enabled)
- Individual policy JSON files (if JSON export enabled)

Log file: $LogPath
"@
        
        $summaryPath = Join-Path $OutputPath "Export-Summary.txt"
        $summaryReport | Out-File -FilePath $summaryPath -Encoding UTF8
        Write-Log "Summary report saved to: $summaryPath" -Level Success
        
    }
    else {
        Write-Log "No WAF policies or configurations found in the specified subscriptions." -Level Warning
    }
}
catch {
    Write-Log "Critical error in main execution: $_" -Level Error
    exit 1
}

Write-Log "WAF Policy Export Script completed." -Level Info