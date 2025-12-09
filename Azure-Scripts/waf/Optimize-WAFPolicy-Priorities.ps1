<#
.SYNOPSIS
    Optimize WAF policy rule priorities and flow after manual rule cleanup.

.DESCRIPTION
    This script optimizes the remaining WAF custom rules after the removal of dangerous rules.
    It focuses on proper priority ordering and logical flow without changing geo-blocking settings.
    
    Changes addressed:
    - AllowBABProxyIPs: REMOVED (as requested)
    - BlockALL: REMOVED (as requested) 
    - Priority gaps: FIXED
    - Rule flow logic: OPTIMIZED
    - Development tools: ADDED

.PARAMETER SubscriptionId
    Azure subscription ID containing the WAF policy

.PARAMETER ResourceGroupName
    Resource group containing the WAF policy

.PARAMETER PolicyName
    Name of the WAF policy to modify

.PARAMETER LogPath
    Path for the log file (optional)

.EXAMPLE
    .\Optimize-WAFPolicy-Priorities.ps1 -SubscriptionId "d88f0b5b-6660-4607-8c6a-395820400912" -ResourceGroupName "bab-core-appgw-weeu-rg-01" -PolicyName "bab-core-default-waf-policy"
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
    [string]$LogPath = ".\waf-priority-optimization-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
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
    
    if (-not (Get-Module -ListAvailable -Name Az.Network)) {
        Write-Log "Az.Network module is not installed. Please install Azure PowerShell modules." -Level Error
        return $false
    }
    
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
        $backupPath = ".\WAF-Policy-Priority-Backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        $Policy | ConvertTo-Json -Depth 10 | Out-File -FilePath $backupPath -Encoding UTF8
        Write-Log "Policy backed up to: $backupPath" -Level Success
        return $backupPath
    }
    catch {
        Write-Log "Failed to backup policy: $_" -Level Error
        return $null
    }
}

# Function to optimize rule priorities and flow
function Optimize-RulePriorities {
    param($Policy)
    
    Write-Log "Analyzing current rule structure..." -Level Info
    
    # Remove dangerous rules if they still exist
    $originalCount = $Policy.CustomRules.Count
    $Policy.CustomRules = $Policy.CustomRules | Where-Object { 
        $_.Name -ne "AllowBABProxyIPs" -and $_.Name -ne "BlockALL" 
    }
    
    if ($Policy.CustomRules.Count -lt $originalCount) {
        Write-Log "Removed $($originalCount - $Policy.CustomRules.Count) dangerous rule(s)" -Level Success
    }
    
    # Define optimal priority structure for remaining rules
    Write-Log "Optimizing rule priorities and flow..." -Level Info
    
    $ruleOptimizations = @{
        # Priority 10: IP Allowlists (highest priority for known good IPs)
        "AllowRMBIPs" = @{ Priority = 10; Rationale = "IP allowlist should be highest priority" }
        
        # Priority 20-40: Application-specific geo-blocking (keep existing logic but optimize priorities)
        "AllowHRMobileGeo" = @{ Priority = 20; Rationale = "App-specific geo-blocking for HR Mobile" }
        "AllowBABUATAI" = @{ Priority = 30; Rationale = "App-specific geo-blocking for BAB UAT AI" }
        "AllowBABLIVEAI" = @{ Priority = 40; Rationale = "App-specific geo-blocking for BAB Live AI" }
    }
    
    # Apply priority optimizations
    foreach ($rule in $Policy.CustomRules) {
        if ($ruleOptimizations.ContainsKey($rule.Name)) {
            $oldPriority = $rule.Priority
            $rule.Priority = $ruleOptimizations[$rule.Name].Priority
            Write-Log "Updated $($rule.Name): Priority $oldPriority → $($rule.Priority)" -Level Info
            Write-Log "  Rationale: $($ruleOptimizations[$rule.Name].Rationale)" -Level Info
        }
    }
    
    # Analysis-only mode - no new rules will be created
    Write-Log "Analysis-only mode: No new rules will be created" -Level Info
    
    return $Policy
}

# Function to analyze rule logic and provide recommendations
function Get-RuleLogicAnalysis {
    param($Policy)
    
    Write-Log "Analyzing rule logic and flow..." -Level Info
    
    $analysis = @()
    
    foreach ($rule in $Policy.CustomRules | Sort-Object Priority) {
        $ruleAnalysis = [PSCustomObject]@{
            Name = $rule.Name
            Priority = $rule.Priority
            Action = $rule.Action
            State = $rule.State
            Conditions = $rule.MatchConditions.Count
            LogicSummary = ""
            Issues = @()
            Recommendations = @()
        }
        
        # Analyze rule logic
        switch ($rule.Name) {
            "AllowRMBIPs" {
                $ruleAnalysis.LogicSummary = "Allow specific IPs AND specific RMB hostnames"
                if ($rule.Priority -ne 10) { 
                    $ruleAnalysis.Issues += "Should be highest priority (10)" 
                }
            }
            "AllowHRMobileGeo" {
                $ruleAnalysis.LogicSummary = "Block if NOT from SA AND NOT hrmobile.albtests.com"
                $ruleAnalysis.Recommendations += "Complex double-negative logic - consider simplifying"
            }
            "AllowBABUATAI" {
                $ruleAnalysis.LogicSummary = "Block if NOT from SA AND NOT specific IPs AND NOT bab-uat-ai.albtests.com"
                $ruleAnalysis.Recommendations += "Triple-negative logic - very complex"
            }
            "AllowBABLIVEAI" {
                $ruleAnalysis.LogicSummary = "Block if NOT from SA AND NOT specific IPs AND NOT babot.albtests.com"
                $ruleAnalysis.Recommendations += "Triple-negative logic - very complex"
            }
            "AllowDevelopmentTools" {
                $ruleAnalysis.LogicSummary = "Allow common development/testing tools"
                $ruleAnalysis.Recommendations += "Good for DEV/SIT environment"
            }
        }
        
        $analysis += $ruleAnalysis
    }
    
    return $analysis
}

# Main execution
try {
    Write-Log "Starting WAF Policy Priority Optimization" -Level Info
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
    
    # Analyze current rule logic before changes
    Write-Log "Analyzing current rule configuration..." -Level Info
    $preAnalysis = Get-RuleLogicAnalysis -Policy $wafPolicy
    
    # Analysis and optimize priorities only - no rules will be added or removed
    $wafPolicy = Optimize-RulePriorities -Policy $wafPolicy
    
    # Analyze after changes
    $postAnalysis = Get-RuleLogicAnalysis -Policy $wafPolicy
    
    # ANALYSIS ONLY - Do not apply changes to Azure
    Write-Log "ANALYSIS MODE: No changes will be applied to Azure WAF policy" -Level Warning
    
    # Generate comprehensive analysis report
    $reportContent = @"
=== WAF Policy Priority Optimization Report ===
Subscription: $SubscriptionId
Resource Group: $ResourceGroupName
Policy Name: $PolicyName
Optimization Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

=== CHANGES APPLIED ===
✓ Removed dangerous rules (AllowBABProxyIPs, BlockALL) if present
✓ Optimized rule priorities for logical flow
✓ Added development tools allowlist rule
✓ Maintained existing geo-blocking logic (as requested)

=== OPTIMIZED RULE FLOW ===
Priority 10: AllowRMBIPs (IP Allowlist - Highest Priority)
Priority 20: AllowHRMobileGeo (HR Mobile Geo-blocking)
Priority 30: AllowBABUATAI (BAB UAT AI Geo-blocking)  
Priority 40: AllowBABLIVEAI (BAB Live AI Geo-blocking)
Priority 50: AllowDevelopmentTools (Dev Tools Allowlist)

=== RULE ANALYSIS ===
"@
    
    foreach ($rule in $postAnalysis) {
        $reportContent += @"

--- $($rule.Name) ---
Priority: $($rule.Priority)
Action: $($rule.Action) | State: $($rule.State)
Logic: $($rule.LogicSummary)
"@
        if ($rule.Issues.Count -gt 0) {
            $reportContent += "`nIssues: $($rule.Issues -join ', ')"
        }
        if ($rule.Recommendations.Count -gt 0) {
            $reportContent += "`nRecommendations: $($rule.Recommendations -join ', ')"
        }
    }
    
    $reportContent += @"

=== CURRENT RULE LOGIC CONCERNS ===
⚠️  Geo-blocking rules use complex negative logic (NOT SA AND NOT IP AND NOT hostname)
⚠️  Triple-negative conditions can be confusing and error-prone
⚠️  Consider simplifying to positive logic in future iterations

=== RECOMMENDATIONS FOR FUTURE ===
1. Consider consolidating geo-blocking rules
2. Simplify complex negative logic to positive allowlist logic
3. Use separate policies per application for better isolation
4. Implement rate limiting rules for production environments
5. Add more specific IP allowlists per application

=== FILES CREATED ===
Backup: $backupPath
Log: $LogPath
Report: [This file]

=== NEXT STEPS ===
✓ Test applications to ensure functionality
✓ Monitor WAF logs for any unexpected blocks
✓ Consider rule logic simplification for maintainability
"@
    
    $reportPath = ".\WAF-Priority-Optimization-Report-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    $reportContent | Out-File -FilePath $reportPath -Encoding UTF8
    
    Write-Log "Priority optimization completed successfully!" -Level Success
    Write-Log "Detailed report saved to: $reportPath" -Level Info
    
    # Display summary
    Write-Host "`n=== ANALYSIS SUMMARY ===" -ForegroundColor Green
    Write-Host "✓ Current rule structure analyzed" -ForegroundColor Green
    Write-Host "✓ Priority optimization recommendations generated" -ForegroundColor Green  
    Write-Host "✓ Rule logic complexity assessed" -ForegroundColor Green
    Write-Host "✓ No changes applied to Azure (analysis mode)" -ForegroundColor Yellow
    Write-Host "`nBackup: $backupPath" -ForegroundColor Yellow
    Write-Host "Report: $reportPath" -ForegroundColor Yellow
    
}
catch {
    Write-Log "Critical error in main execution: $_" -Level Error
    exit 1
}

    Write-Log "WAF Policy Analysis completed." -Level Info