<#
.SYNOPSIS
    Fix hrmobile.albtests.com access by adding it to the AllowRMBIPs rule.

.DESCRIPTION
    This script adds hrmobile.albtests.com to the AllowRMBIPs rule hostname allowlist
    to fix access issues for users with IPs in the allowlist trying to access hrmobile.

.PARAMETER SubscriptionId
    Azure subscription ID containing the WAF policy

.PARAMETER ResourceGroupName
    Resource group containing the WAF policy (default: bab-core-appgw-weeu-rg-01)

.PARAMETER PolicyName
    Name of the WAF policy (default: bab-core-default-waf-policy)

.EXAMPLE
    .\Fix-HRMobile-Access.ps1 -SubscriptionId "d88f0b5b-6660-4607-8c6a-395820400912"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "bab-core-appgw-weeu-rg-01",
    
    [Parameter(Mandatory = $false)]
    [string]$PolicyName = "bab-core-default-waf-policy"
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
    
    switch ($Level) {
        'Info'    { Write-Host $logMessage -ForegroundColor Cyan }
        'Warning' { Write-Host $logMessage -ForegroundColor Yellow }
        'Error'   { Write-Host $logMessage -ForegroundColor Red }
        'Success' { Write-Host $logMessage -ForegroundColor Green }
    }
}

try {
    Write-Log "Starting HRMobile Access Fix" -Level Info
    
    # Connect to Azure and set context
    Write-Log "Setting Azure subscription context..." -Level Info
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    Write-Log "Successfully set context to subscription: $SubscriptionId" -Level Success
    
    # Get current WAF policy
    Write-Log "Retrieving WAF policy..." -Level Info
    $wafPolicy = Get-AzApplicationGatewayFirewallPolicy -ResourceGroupName $ResourceGroupName -Name $PolicyName
    Write-Log "Successfully retrieved WAF policy: $PolicyName" -Level Success
    
    # Find the AllowRMBIPs rule
    $allowRMBRule = $wafPolicy.CustomRules | Where-Object { $_.Name -eq "AllowRMBIPs" }
    if (-not $allowRMBRule) {
        Write-Log "AllowRMBIPs rule not found!" -Level Error
        exit 1
    }
    
    # Find the hostname condition
    $hostnameCondition = $allowRMBRule.MatchConditions | Where-Object { 
        $_.MatchVariables[0].VariableName -eq "RequestHeaders" -and 
        $_.MatchVariables[0].Selector -eq "Host" 
    }
    
    if (-not $hostnameCondition) {
        Write-Log "Hostname condition not found in AllowRMBIPs rule!" -Level Error
        exit 1
    }
    
    # Check if hrmobile.albtests.com is already in the list
    if ($hostnameCondition.MatchValues -contains "hrmobile.albtests.com") {
        Write-Log "hrmobile.albtests.com is already in the allowlist!" -Level Warning
        exit 0
    }
    
    # Add hrmobile.albtests.com to the hostname list
    Write-Log "Adding hrmobile.albtests.com to AllowRMBIPs hostname allowlist..." -Level Info
    $hostnameCondition.MatchValues += "hrmobile.albtests.com"
    
    # Apply the changes
    Write-Log "Applying changes to WAF policy..." -Level Info
    Set-AzApplicationGatewayFirewallPolicy -InputObject $wafPolicy | Out-Null
    Write-Log "Successfully updated WAF policy!" -Level Success
    
    # Verify the change
    $updatedPolicy = Get-AzApplicationGatewayFirewallPolicy -ResourceGroupName $ResourceGroupName -Name $PolicyName
    $updatedRule = $updatedPolicy.CustomRules | Where-Object { $_.Name -eq "AllowRMBIPs" }
    $updatedCondition = $updatedRule.MatchConditions | Where-Object { 
        $_.MatchVariables[0].VariableName -eq "RequestHeaders" -and 
        $_.MatchVariables[0].Selector -eq "Host" 
    }
    
    if ($updatedCondition.MatchValues -contains "hrmobile.albtests.com") {
        Write-Log "✅ Fix verified: hrmobile.albtests.com added successfully!" -Level Success
        
        Write-Host "`n=== HRMobile Access Fix Applied ===" -ForegroundColor Green
        Write-Host "✅ hrmobile.albtests.com added to AllowRMBIPs rule" -ForegroundColor Green
        Write-Host "✅ Users with allowlisted IPs can now access hrmobile" -ForegroundColor Green
        Write-Host "`n📋 Current hostname allowlist:" -ForegroundColor Cyan
        foreach ($hostname in $updatedCondition.MatchValues) {
            Write-Host "   • $hostname" -ForegroundColor White
        }
        
        Write-Host "`n🔍 Test your access now:" -ForegroundColor Yellow
        Write-Host "   URL: https://hrmobile.albtests.com" -ForegroundColor White
        Write-Host "   Expected: Should work for IPs in allowlist" -ForegroundColor White
        
    } else {
        Write-Log "❌ Verification failed: hrmobile.albtests.com not found in updated policy" -Level Error
        exit 1
    }
    
} catch {
    Write-Log "Error: $_" -Level Error
    exit 1
}

Write-Log "HRMobile Access Fix completed successfully!" -Level Success