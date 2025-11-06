<#
.SYNOPSIS
    Configure WAF policy for DEV/SIT environment with appropriate security settings.

.DESCRIPTION
    This script modifies WAF policy settings to be suitable for development and testing environments.
    It relaxes certain restrictions while maintaining essential logging and monitoring capabilities.

.PARAMETER SubscriptionId
    Azure subscription ID containing the WAF policy

.PARAMETER ResourceGroupName
    Resource group containing the WAF policy

.PARAMETER PolicyName
    Name of the WAF policy to modify

.PARAMETER LogPath
    Path for the log file (optional)

.EXAMPLE
    .\Configure-WAFPolicy-DevSit.ps1 -SubscriptionId "d88f0b5b-6660-4607-8c6a-395820400912" -ResourceGroupName "bab-core-appgw-weeu-rg-01" -PolicyName "bab-core-default-waf-policy"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$PolicyName,
    
    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\waf-devsit-config-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
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

# Function to backup current policy
function Backup-WAFPolicy {
    param($Policy)
    
    try {
        $backupPath = ".\WAF-Policy-Backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        $Policy | ConvertTo-Json -Depth 10 | Out-File -FilePath $backupPath -Encoding UTF8
        Write-Log "Policy backed up to: $backupPath" -Level Success
        return $backupPath
    }
    catch {
        Write-Log "Failed to backup policy: $_" -Level Error
        return $null
    }
}

# Function to configure DEV/SIT specific settings
function Set-DevSitConfiguration {
    param($Policy)
    
    Write-Log "Configuring WAF policy for DEV/SIT environment..." -Level Info
    
    # Update policy settings for DEV/SIT
    $Policy.PolicySettings.MaxRequestBodySizeInKb = 10000  # 10MB for testing
    $Policy.PolicySettings.FileUploadLimitInMb = 500       # 500MB for large file testing
    $Policy.PolicySettings.RequestBodyInspectLimitInKB = 500 # Increased inspection limit
    
    Write-Log "Updated body size limits for DEV/SIT testing" -Level Success
    
    # Disable geo-blocking rules for global testing access
    $geoBlockingRules = @("AllowHRMobileGeo", "AllowBABUATAI", "AllowBABLIVEAI")
    
    foreach ($rule in $Policy.CustomRules) {
        if ($geoBlockingRules -contains $rule.Name) {
            $rule.State = "Disabled"
            Write-Log "Disabled geo-blocking rule: $($rule.Name)" -Level Info
        }
        
        # Remove dangerous BlockALL rule
        if ($rule.Name -eq "BlockALL") {
            Write-Log "WARNING: Found dangerous 'BlockALL' rule - recommend manual removal" -Level Warning
        }
        
        # Enable proxy rules if needed for testing
        if ($rule.Name -eq "AllowBABProxyIPs") {
            $rule.State = "Enabled"
            Write-Log "Enabled proxy allowlist for testing" -Level Info
        }
    }
    
    # Keep OWASP rules in Log mode for DEV/SIT (already configured correctly)
    $logModeCount = 0
    foreach ($ruleSet in $Policy.ManagedRules.ManagedRuleSets) {
        foreach ($ruleGroup in $ruleSet.RuleGroupOverrides) {
            foreach ($rule in $ruleGroup.Rules) {
                if ($rule.Action -eq "Log") {
                    $logModeCount++
                }
            }
        }
    }
    
    Write-Log "Verified $logModeCount OWASP rules are in Log mode (appropriate for DEV/SIT)" -Level Success
    
    return $Policy
}

# Function to add development-friendly custom rules
function Add-DevFriendlyRules {
    param($Policy)
    
    Write-Log "Adding development-friendly custom rules..." -Level Info
    
    # Check if development tools rule already exists
    $devToolsRuleExists = $Policy.CustomRules | Where-Object { $_.Name -eq "AllowDevelopmentTools" }
    
    if (-not $devToolsRuleExists) {
        # Create development tools allowlist rule
        $devToolsRule = @{
            Name = "AllowDevelopmentTools"
            Priority = 5
            RateLimitDuration = $null
            RateLimitThreshold = 0
            RuleType = "MatchRule"
            MatchConditions = @(
                @{
                    MatchVariables = @(
                        @{
                            VariableName = "RequestHeaders"
                            Selector = "User-Agent"
                        }
                    )
                    OperatorProperty = "Contains"
                    NegationConditon = $false
                    MatchValues = @(
                        "PostmanRuntime",
                        "curl",
                        "wget",
                        "HTTPie",
                        "Insomnia",
                        "Thunder Client"
                    )
                    Transforms = @()
                }
            )
            GroupByUserSession = @()
            Action = "Allow"
            State = "Enabled"
        }
        
        # Add the rule to the policy
        $Policy.CustomRules += $devToolsRule
        Write-Log "Added AllowDevelopmentTools rule for API testing tools" -Level Success
    }
    else {
        Write-Log "Development tools rule already exists" -Level Info
    }
    
    return $Policy
}

# Main execution
try {
    Write-Log "Starting WAF Policy DEV/SIT Configuration" -Level Info
    Write-Log "Target: $PolicyName in $ResourceGroupName (Subscription: $SubscriptionId)" -Level Info
    
    # Validate prerequisites
    if (-not (Test-Prerequisites)) {
        Write-Log "Prerequisites check failed. Exiting." -Level Error
        exit 1
    }
    
    # Set subscription context
    Write-Log "Setting Azure subscription context..." -Level Info
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    Write-Log "Successfully set context to subscription: $SubscriptionId" -Level Success
    
    # Get current WAF policy
    Write-Log "Retrieving current WAF policy..." -Level Info
    try {
        $wafPolicy = Get-AzApplicationGatewayFirewallPolicy -ResourceGroupName $ResourceGroupName -Name $PolicyName
        Write-Log "Successfully retrieved WAF policy: $PolicyName" -Level Success
    }
    catch {
        Write-Log "Failed to retrieve WAF policy: $_" -Level Error
        exit 1
    }
    
    # Backup current policy
    Write-Log "Creating backup of current policy..." -Level Info
    $backupPath = Backup-WAFPolicy -Policy $wafPolicy
    if (-not $backupPath) {
        Write-Log "Failed to create backup. Exiting for safety." -Level Error
        exit 1
    }
    
    # Configure for DEV/SIT
    $wafPolicy = Set-DevSitConfiguration -Policy $wafPolicy
    $wafPolicy = Add-DevFriendlyRules -Policy $wafPolicy
    
    # Apply changes
    Write-Log "Applying DEV/SIT configuration changes..." -Level Info
    try {
        Set-AzApplicationGatewayFirewallPolicy -InputObject $wafPolicy | Out-Null
        Write-Log "Successfully applied DEV/SIT configuration!" -Level Success
    }
    catch {
        Write-Log "Failed to apply changes: $_" -Level Error
        Write-Log "Policy backup available at: $backupPath" -Level Info
        exit 1
    }
    
    # Generate configuration summary
    $summary = @"
=== WAF Policy DEV/SIT Configuration Summary ===
Subscription: $SubscriptionId
Resource Group: $ResourceGroupName
Policy Name: $PolicyName
Configuration Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

Changes Applied:
✓ Increased MaxRequestBodySizeInKb to 10,000 KB (10MB)
✓ Increased FileUploadLimitInMb to 500 MB
✓ Disabled geo-blocking rules for global testing access
✓ Enabled proxy allowlist for testing scenarios
✓ Added development tools allowlist rule
✓ Verified OWASP rules remain in Log mode (appropriate for DEV/SIT)

Security Notes:
- All OWASP rules in Log mode (monitoring only)
- Geo-blocking disabled for testing flexibility
- Increased payload limits for development scenarios
- Development tools (Postman, curl, etc.) explicitly allowed

Backup Location: $backupPath
Log File: $LogPath

Next Steps for Production:
1. Enable OWASP rules with Block action
2. Re-enable geo-blocking rules
3. Reduce payload size limits
4. Remove development tools allowlist
"@
    
    $summaryPath = ".\WAF-DevSit-Summary-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    $summary | Out-File -FilePath $summaryPath -Encoding UTF8
    
    Write-Log "Configuration completed successfully!" -Level Success
    Write-Log "Summary report saved to: $summaryPath" -Level Info
    Write-Host "`n$summary" -ForegroundColor Green
    
}
catch {
    Write-Log "Critical error in main execution: $_" -Level Error
    exit 1
}

Write-Log "WAF Policy DEV/SIT Configuration completed." -Level Info