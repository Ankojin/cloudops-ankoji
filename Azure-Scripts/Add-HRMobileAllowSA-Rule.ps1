#Requires -Modules Az.Accounts, Az.Network

<#
.SYNOPSIS
    Adds a WAF custom rule to allow Saudi Arabia users access to hrmobile.albtests.com

.DESCRIPTION
    This script adds a custom WAF rule with Priority 25 to allow users from Saudi Arabia (SA) 
    to access hrmobile.albtests.com. This rule will be evaluated before any blocking rules.

.PARAMETER SubscriptionId
    The Azure subscription ID containing the WAF policy

.PARAMETER ResourceGroupName
    The resource group name containing the WAF policy

.PARAMETER PolicyName
    The name of the WAF policy to modify

.PARAMETER WhatIf
    Shows what would happen if the script runs without making actual changes

.EXAMPLE
    .\Add-HRMobileAllowSA-Rule.ps1 -SubscriptionId "d88f0b5b-6660-4607-8c6a-395820400912" -ResourceGroupName "bab-core-appgw-weeu-rg-01" -PolicyName "bab-core-default-waf-policy"

.EXAMPLE
    .\Add-HRMobileAllowSA-Rule.ps1 -SubscriptionId "d88f0b5b-6660-4607-8c6a-395820400912" -ResourceGroupName "bab-core-appgw-weeu-rg-01" -PolicyName "bab-core-default-waf-policy" -WhatIf

.NOTES
    Author: GitHub Copilot
    Date: November 5, 2025
    Requires: Az.Accounts and Az.Network PowerShell modules
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$PolicyName,
    
    [switch]$WhatIf
)

# Function to write colored output
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    switch ($Level) {
        "Info"    { Write-Host "[$timestamp] [INFO] $Message" -ForegroundColor White }
        "Success" { Write-Host "[$timestamp] [SUCCESS] $Message" -ForegroundColor Green }
        "Warning" { Write-Host "[$timestamp] [WARNING] $Message" -ForegroundColor Yellow }
        "Error"   { Write-Host "[$timestamp] [ERROR] $Message" -ForegroundColor Red }
    }
}

try {
    Write-Log "Starting WAF rule addition script..." -Level "Info"
    
    # Check if required modules are installed
    Write-Log "Checking required PowerShell modules..." -Level "Info"
    
    $requiredModules = @('Az.Accounts', 'Az.Network')
    foreach ($module in $requiredModules) {
        if (!(Get-Module -ListAvailable -Name $module)) {
            Write-Log "Required module '$module' not found. Please install it using: Install-Module $module" -Level "Error"
            exit 1
        }
    }
    
    # Connect to Azure (if not already connected)
    Write-Log "Checking Azure connection..." -Level "Info"
    $context = Get-AzContext
    if (!$context) {
        Write-Log "Not connected to Azure. Please run Connect-AzAccount first." -Level "Error"
        exit 1
    }
    
    # Set subscription context
    Write-Log "Setting subscription context to: $SubscriptionId" -Level "Info"
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    
    # Get the current WAF policy
    Write-Log "Retrieving WAF policy: $PolicyName" -Level "Info"
    $wafPolicy = Get-AzApplicationGatewayFirewallPolicy -ResourceGroupName $ResourceGroupName -Name $PolicyName
    
    if (!$wafPolicy) {
        Write-Log "WAF policy '$PolicyName' not found in resource group '$ResourceGroupName'" -Level "Error"
        exit 1
    }
    
    # Check if rule with same name already exists
    $existingRule = $wafPolicy.CustomRules | Where-Object { $_.Name -eq "AllowHRMobileFromSA" }
    if ($existingRule) {
        Write-Log "Rule 'AllowHRMobileFromSA' already exists with Priority $($existingRule.Priority)" -Level "Warning"
        Write-Log "Current rule action: $($existingRule.Action)" -Level "Info"
        
        if (!$WhatIf) {
            $confirm = Read-Host "Do you want to update the existing rule? (Y/N)"
            if ($confirm -ne 'Y' -and $confirm -ne 'y') {
                Write-Log "Operation cancelled by user." -Level "Warning"
                exit 0
            }
        }
    }
    
    # Check if Priority 25 is already used by another rule
    $existingPriority = $wafPolicy.CustomRules | Where-Object { $_.Priority -eq 25 -and $_.Name -ne "AllowHRMobileFromSA" }
    if ($existingPriority) {
        Write-Log "Priority 25 is already used by rule: $($existingPriority.Name)" -Level "Warning"
        Write-Log "You may need to adjust priorities manually after adding this rule." -Level "Warning"
    }
    
    # Create the geo match condition
    Write-Log "Creating geo match condition for Saudi Arabia..." -Level "Info"
    $geoMatchVariable = New-AzApplicationGatewayFirewallMatchVariable -VariableName "RemoteAddr"
    $geoMatchCondition = New-AzApplicationGatewayFirewallCondition -MatchVariable $geoMatchVariable -Operator "GeoMatch" -MatchValue @("SA") -NegationCondition $false
    
    # Create the host header match condition  
    Write-Log "Creating host header match condition for hrmobile.albtests.com..." -Level "Info"
    $hostMatchVariable = New-AzApplicationGatewayFirewallMatchVariable -VariableName "RequestHeaders" -Selector "Host"
    $hostMatchCondition = New-AzApplicationGatewayFirewallCondition -MatchVariable $hostMatchVariable -Operator "Equal" -MatchValue @("hrmobile.albtests.com") -NegationCondition $false
    
    # Create the custom rule
    Write-Log "Creating custom WAF rule 'AllowHRMobileFromSA' with Priority 25..." -Level "Info"
    $customRule = New-AzApplicationGatewayFirewallCustomRule -Name "AllowHRMobileFromSA" -Priority 25 -RuleType "MatchRule" -MatchCondition @($geoMatchCondition, $hostMatchCondition) -Action "Allow" -State "Enabled"
    
    if ($WhatIf) {
        Write-Log "WHAT-IF MODE: Would add the following rule:" -Level "Warning"
        Write-Log "  Rule Name: AllowHRMobileFromSA" -Level "Info"
        Write-Log "  Priority: 25" -Level "Info"
        Write-Log "  Action: Allow" -Level "Info"
        Write-Log "  Condition 1: RemoteAddr GeoMatch SA (not negated)" -Level "Info"
        Write-Log "  Condition 2: RequestHeaders[Host] Equal hrmobile.albtests.com (not negated)" -Level "Info"
        Write-Log "  Logic: Allow if (FROM SA) AND (accessing hrmobile.albtests.com)" -Level "Info"
        exit 0
    }
    
    # Remove existing rule if it exists
    if ($existingRule) {
        Write-Log "Removing existing rule before adding updated version..." -Level "Info"
        $wafPolicy.CustomRules = $wafPolicy.CustomRules | Where-Object { $_.Name -ne "AllowHRMobileFromSA" }
    }
    
    # Add the new rule to the policy
    Write-Log "Adding rule to WAF policy..." -Level "Info"
    $wafPolicy.CustomRules += $customRule
    
    # Update the WAF policy
    Write-Log "Updating WAF policy in Azure..." -Level "Info"
    $updatedPolicy = Set-AzApplicationGatewayFirewallPolicy -InputObject $wafPolicy
    
    if ($updatedPolicy) {
        Write-Log "Successfully added 'AllowHRMobileFromSA' rule to WAF policy!" -Level "Success"
        Write-Log "Rule Details:" -Level "Info"
        Write-Log "  Name: AllowHRMobileFromSA" -Level "Info"
        Write-Log "  Priority: 25" -Level "Info"
        Write-Log "  Action: Allow" -Level "Info"
        Write-Log "  Logic: Allow users from Saudi Arabia to access hrmobile.albtests.com" -Level "Info"
        Write-Log "" -Level "Info"
        Write-Log "Next Steps:" -Level "Warning"
        Write-Log "1. Test access to hrmobile.albtests.com from Saudi Arabia" -Level "Info"
        Write-Log "2. Consider adding Priority 26 rule for private network access" -Level "Info"
        Write-Log "3. Consider adding Priority 30 rule to block other countries" -Level "Info"
    } else {
        Write-Log "Failed to update WAF policy" -Level "Error"
        exit 1
    }
    
} catch {
    Write-Log "An error occurred: $($_.Exception.Message)" -Level "Error"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "Error"
    exit 1
}

Write-Log "Script completed successfully!" -Level "Success"