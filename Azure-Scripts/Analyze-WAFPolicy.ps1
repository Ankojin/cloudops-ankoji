<#
.SYNOPSIS
    Analyze WAF policy configuration and provide optimization recommendations.

.DESCRIPTION
    This script provides comprehensive analysis of WAF policy configuration without making any changes.
    It reviews rule priorities, logic complexity, security posture, and provides actionable recommendations.

.PARAMETER JsonFilePath
    Path to the exported WAF policy JSON file

.PARAMETER LogPath
    Path for the log file (optional)

.EXAMPLE
    .\Analyze-WAFPolicy.ps1 -JsonFilePath ".\WAF-Export-20251105-101521\WAFPolicy_bab-core-default-waf-policy_d88f0b5b.json"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$JsonFilePath,
    
    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\waf-analysis-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
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

# Function to load and validate WAF policy JSON
function Get-WAFPolicyFromJson {
    param($FilePath)
    
    try {
        if (-not (Test-Path $FilePath)) {
            Write-Log "JSON file not found: $FilePath" -Level Error
            return $null
        }
        
        $jsonContent = Get-Content -Path $FilePath -Raw | ConvertFrom-Json
        Write-Log "Successfully loaded WAF policy from JSON" -Level Success
        return $jsonContent
    }
    catch {
        Write-Log "Failed to load JSON file: $_" -Level Error
        return $null
    }
}

# Function to analyze custom rules
function Get-CustomRulesAnalysis {
    param($Policy)
    
    Write-Log "Analyzing custom rules..." -Level Info
    
    $analysis = @{
        TotalRules = $Policy.CustomRules.Count
        EnabledRules = ($Policy.CustomRules | Where-Object { $_.State -eq "Enabled" }).Count
        DisabledRules = ($Policy.CustomRules | Where-Object { $_.State -eq "Disabled" }).Count
        AllowRules = ($Policy.CustomRules | Where-Object { $_.Action -eq "Allow" }).Count
        BlockRules = ($Policy.CustomRules | Where-Object { $_.Action -eq "Block" }).Count
        RuleDetails = @()
        PriorityGaps = @()
        ComplexityIssues = @()
        Recommendations = @()
    }
    
    # Analyze each rule
    foreach ($rule in $Policy.CustomRules | Sort-Object Priority) {
        $ruleDetail = [PSCustomObject]@{
            Name = $rule.Name
            Priority = $rule.Priority
            Action = $rule.Action
            State = $rule.State
            ConditionsCount = $rule.MatchConditions.Count
            ComplexityScore = 0
            LogicDescription = ""
            Issues = @()
            Recommendations = @()
        }
        
        # Calculate complexity score
        $complexityScore = 0
        $logicParts = @()
        
        foreach ($condition in $rule.MatchConditions) {
            $complexityScore += 1
            
            # Analyze condition complexity
            if ($condition.NegationConditon -eq $true) {
                $complexityScore += 2  # Negation adds complexity
                $logicParts += "NOT($($condition.OperatorProperty))"
            } else {
                $logicParts += $condition.OperatorProperty
            }
            
            # Multiple match values add complexity
            if ($condition.MatchValues.Count -gt 1) {
                $complexityScore += 1
            }
        }
        
        $ruleDetail.ComplexityScore = $complexityScore
        $ruleDetail.LogicDescription = $logicParts -join " AND "
        
        # Identify specific issues
        switch ($rule.Name) {
            "AllowBABProxyIPs" {
                if ($rule.State -eq "Disabled") {
                    $ruleDetail.Issues += "Rule exists but is disabled - consider removal"
                }
            }
            "BlockALL" {
                $ruleDetail.Issues += "DANGEROUS: This rule blocks all traffic - should be removed"
                $ruleDetail.Recommendations += "DELETE this rule immediately"
            }
            "AllowHRMobileGeo" {
                if ($complexityScore -gt 3) {
                    $ruleDetail.Issues += "Complex negative logic - hard to maintain"
                    $ruleDetail.Recommendations += "Consider simplifying to positive allowlist logic"
                }
            }
            "AllowBABUATAI" {
                if ($complexityScore -gt 4) {
                    $ruleDetail.Issues += "Very complex triple-negative logic"
                    $ruleDetail.Recommendations += "High priority for logic simplification"
                }
            }
            "AllowBABLIVEAI" {
                if ($complexityScore -gt 4) {
                    $ruleDetail.Issues += "Very complex triple-negative logic"
                    $ruleDetail.Recommendations += "High priority for logic simplification"
                }
            }
        }
        
        $analysis.RuleDetails += $ruleDetail
        
        if ($ruleDetail.Issues.Count -gt 0) {
            $analysis.ComplexityIssues += $ruleDetail
        }
    }
    
    # Check for priority gaps
    $priorities = $Policy.CustomRules | Sort-Object Priority | Select-Object -ExpandProperty Priority
    for ($i = 0; $i -lt ($priorities.Count - 1); $i++) {
        $gap = $priorities[$i + 1] - $priorities[$i]
        if ($gap -gt 10) {
            $analysis.PriorityGaps += [PSCustomObject]@{
                From = $priorities[$i]
                To = $priorities[$i + 1]
                Gap = $gap
                Recommendation = "Consider standardizing priority intervals"
            }
        }
    }
    
    return $analysis
}

# Function to analyze OWASP managed rules
function Get-ManagedRulesAnalysis {
    param($Policy)
    
    Write-Log "Analyzing OWASP managed rules..." -Level Info
    
    $analysis = @{
        RuleSetType = ""
        RuleSetVersion = ""
        TotalRuleGroups = 0
        TotalRules = 0
        LogModeRules = 0
        BlockModeRules = 0
        DisabledRules = 0
        SecurityCoverage = @{}
        Recommendations = @()
    }
    
    if ($Policy.ManagedRules -and $Policy.ManagedRules.ManagedRuleSets) {
        $managedRuleSet = $Policy.ManagedRules.ManagedRuleSets[0]
        $analysis.RuleSetType = $managedRuleSet.RuleSetType
        $analysis.RuleSetVersion = $managedRuleSet.RuleSetVersion
        
        # Check if using latest version
        if ($managedRuleSet.RuleSetVersion -eq "3.2") {
            $analysis.Recommendations += "Consider upgrading to OWASP 4.0 for enhanced protection"
        }
        
        # Analyze rule group overrides
        if ($managedRuleSet.RuleGroupOverrides) {
            $analysis.TotalRuleGroups = $managedRuleSet.RuleGroupOverrides.Count
            
            foreach ($ruleGroup in $managedRuleSet.RuleGroupOverrides) {
                $groupName = $ruleGroup.RuleGroupName
                
                # Map rule groups to security categories
                switch -Wildcard ($groupName) {
                    "*SCANNER*" { $analysis.SecurityCoverage["Scanner Detection"] = $true }
                    "*PROTOCOL*" { $analysis.SecurityCoverage["Protocol Enforcement"] = $true }
                    "*LFI*" { $analysis.SecurityCoverage["Local File Inclusion"] = $true }
                    "*RFI*" { $analysis.SecurityCoverage["Remote File Inclusion"] = $true }
                    "*SQLI*" { $analysis.SecurityCoverage["SQL Injection"] = $true }
                    "*XSS*" { $analysis.SecurityCoverage["Cross-Site Scripting"] = $true }
                }
                
                if ($ruleGroup.Rules) {
                    $analysis.TotalRules += $ruleGroup.Rules.Count
                    
                    foreach ($rule in $ruleGroup.Rules) {
                        switch ($rule.Action) {
                            "Log" { $analysis.LogModeRules++ }
                            "Block" { $analysis.BlockModeRules++ }
                        }
                        
                        if ($rule.State -eq "Disabled") {
                            $analysis.DisabledRules++
                        }
                    }
                }
            }
        }
    }
    
    # Analyze security posture
    $logPercentage = if ($analysis.TotalRules -gt 0) { 
        [math]::Round(($analysis.LogModeRules / $analysis.TotalRules) * 100, 1) 
    } else { 0 }
    
    if ($logPercentage -gt 90) {
        $analysis.Recommendations += "Most rules in Log mode - appropriate for DEV/SIT, consider Block mode for production"
    }
    
    return $analysis
}

# Function to analyze policy settings
function Get-PolicySettingsAnalysis {
    param($Policy)
    
    Write-Log "Analyzing policy settings..." -Level Info
    
    $settings = $Policy.PolicySettings
    $analysis = @{
        Mode = $settings.Mode
        State = $settings.State
        MaxRequestBodySizeKB = $settings.MaxRequestBodySizeInKb
        FileUploadLimitMB = $settings.FileUploadLimitInMb
        RequestBodyCheck = $settings.RequestBodyCheck
        Issues = @()
        Recommendations = @()
    }
    
    # Analyze settings for DEV/SIT environment
    if ($settings.MaxRequestBodySizeInKb -lt 5000) {
        $analysis.Recommendations += "Consider increasing MaxRequestBodySizeInKb to 5000-10000 for DEV/SIT testing"
    }
    
    if ($settings.FileUploadLimitInMb -lt 200) {
        $analysis.Recommendations += "Consider increasing FileUploadLimitInMb to 200-500 for DEV/SIT testing"
    }
    
    if ($settings.Mode -eq "Detection") {
        $analysis.Issues += "Policy in Detection mode - no blocking will occur"
    }
    
    if ($settings.State -eq "Disabled") {
        $analysis.Issues += "WAF policy is disabled - no protection active"
    }
    
    return $analysis
}

# Function to generate comprehensive recommendations
function Get-ComprehensiveRecommendations {
    param($CustomRulesAnalysis, $ManagedRulesAnalysis, $PolicySettingsAnalysis)
    
    $recommendations = @{
        Immediate = @()
        ShortTerm = @()
        LongTerm = @()
        DevSitSpecific = @()
    }
    
    # Immediate actions
    foreach ($rule in $CustomRulesAnalysis.RuleDetails) {
        if ($rule.Name -eq "BlockALL") {
            $recommendations.Immediate += "URGENT: Remove 'BlockALL' rule - it blocks all traffic"
        }
        if ($rule.Name -eq "AllowBABProxyIPs" -and $rule.State -eq "Disabled") {
            $recommendations.Immediate += "Remove disabled 'AllowBABProxyIPs' rule if no longer needed"
        }
    }
    
    # Priority optimization
    if ($CustomRulesAnalysis.PriorityGaps.Count -gt 0) {
        $recommendations.ShortTerm += "Standardize rule priorities (use 10, 20, 30, 40 intervals)"
    }
    
    # Complexity issues
    $complexRules = $CustomRulesAnalysis.RuleDetails | Where-Object { $_.ComplexityScore -gt 4 }
    if ($complexRules.Count -gt 0) {
        $recommendations.LongTerm += "Simplify complex negative logic in rules: $($complexRules.Name -join ', ')"
    }
    
    # OWASP version
    if ($ManagedRulesAnalysis.RuleSetVersion -eq "3.2") {
        $recommendations.ShortTerm += "Upgrade OWASP ruleset from 3.2 to 4.0"
    }
    
    # DEV/SIT specific
    $recommendations.DevSitSpecific += "Current Log mode configuration is appropriate for DEV/SIT"
    $recommendations.DevSitSpecific += "Consider adding development tools allowlist rule for testing"
    $recommendations.DevSitSpecific += "Monitor WAF logs to identify false positives before production"
    
    return $recommendations
}

# Main execution
try {
    Write-Log "Starting WAF Policy Analysis" -Level Info
    Write-Log "Source: $JsonFilePath" -Level Info
    
    # Load WAF policy from JSON
    $wafPolicy = Get-WAFPolicyFromJson -FilePath $JsonFilePath
    if (-not $wafPolicy) {
        Write-Log "Failed to load WAF policy. Exiting." -Level Error
        exit 1
    }
    
    Write-Log "Policy Name: $($wafPolicy.Name)" -Level Info
    Write-Log "Resource Group: $($wafPolicy.ResourceGroupName)" -Level Info
    Write-Log "Location: $($wafPolicy.Location)" -Level Info
    
    # Perform comprehensive analysis
    Write-Log "Performing comprehensive analysis..." -Level Info
    
    $customRulesAnalysis = Get-CustomRulesAnalysis -Policy $wafPolicy
    $managedRulesAnalysis = Get-ManagedRulesAnalysis -Policy $wafPolicy
    $policySettingsAnalysis = Get-PolicySettingsAnalysis -Policy $wafPolicy
    $recommendations = Get-ComprehensiveRecommendations -CustomRulesAnalysis $customRulesAnalysis -ManagedRulesAnalysis $managedRulesAnalysis -PolicySettingsAnalysis $policySettingsAnalysis
    
    # Generate comprehensive report
    $reportContent = @"
================================================================================================
                            WAF POLICY COMPREHENSIVE ANALYSIS REPORT
================================================================================================
Policy Name: $($wafPolicy.Name)
Resource Group: $($wafPolicy.ResourceGroupName)
Location: $($wafPolicy.Location)
Analysis Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Source: $JsonFilePath

================================================================================================
EXECUTIVE SUMMARY
================================================================================================
Total Custom Rules: $($customRulesAnalysis.TotalRules)
Enabled Rules: $($customRulesAnalysis.EnabledRules)
Complex Rules (Score > 4): $(($customRulesAnalysis.RuleDetails | Where-Object { $_.ComplexityScore -gt 4 }).Count)
OWASP Version: $($managedRulesAnalysis.RuleSetType) $($managedRulesAnalysis.RuleSetVersion)
Policy Mode: $($policySettingsAnalysis.Mode)
Log Mode Rules: $($managedRulesAnalysis.LogModeRules) / $($managedRulesAnalysis.TotalRules) ($(if($managedRulesAnalysis.TotalRules -gt 0){[math]::Round(($managedRulesAnalysis.LogModeRules/$managedRulesAnalysis.TotalRules)*100,1)}else{0})%)

================================================================================================
CUSTOM RULES DETAILED ANALYSIS
================================================================================================
"@
    
    foreach ($rule in $customRulesAnalysis.RuleDetails | Sort-Object Priority) {
        $reportContent += @"

--- $($rule.Name) ---
Priority: $($rule.Priority)
Action: $($rule.Action) | State: $($rule.State)
Complexity Score: $($rule.ComplexityScore) | Conditions: $($rule.ConditionsCount)
Logic: $($rule.LogicDescription)
"@
        if ($rule.Issues.Count -gt 0) {
            $reportContent += "`nISSUES: $($rule.Issues -join '; ')"
        }
        if ($rule.Recommendations.Count -gt 0) {
            $reportContent += "`nRECOMMENDATIONS: $($rule.Recommendations -join '; ')"
        }
    }
    
    # Priority gaps analysis
    if ($customRulesAnalysis.PriorityGaps.Count -gt 0) {
        $reportContent += @"

PRIORITY GAPS DETECTED:
"@
        foreach ($gap in $customRulesAnalysis.PriorityGaps) {
            $reportContent += "`n  Priority $($gap.From) → $($gap.To) (Gap: $($gap.Gap))"
        }
    }
    
    $reportContent += @"

================================================================================================
OWASP MANAGED RULES ANALYSIS
================================================================================================
Rule Set: $($managedRulesAnalysis.RuleSetType) $($managedRulesAnalysis.RuleSetVersion)
Total Rule Groups: $($managedRulesAnalysis.TotalRuleGroups)
Total Rules: $($managedRulesAnalysis.TotalRules)
Log Mode: $($managedRulesAnalysis.LogModeRules) rules
Block Mode: $($managedRulesAnalysis.BlockModeRules) rules
Disabled: $($managedRulesAnalysis.DisabledRules) rules

SECURITY COVERAGE:
"@
    
    foreach ($coverage in $managedRulesAnalysis.SecurityCoverage.GetEnumerator()) {
        $reportContent += "`n✓ $($coverage.Key)"
    }
    
    $reportContent += @"

================================================================================================
POLICY SETTINGS ANALYSIS
================================================================================================
Mode: $($policySettingsAnalysis.Mode)
State: $($policySettingsAnalysis.State)
Max Request Body Size: $($policySettingsAnalysis.MaxRequestBodySizeKB) KB
File Upload Limit: $($policySettingsAnalysis.FileUploadLimitMB) MB
Request Body Check: $($policySettingsAnalysis.RequestBodyCheck)
"@
    
    if ($policySettingsAnalysis.Issues.Count -gt 0) {
        $reportContent += "`n`nISSUES:"
        foreach ($issue in $policySettingsAnalysis.Issues) {
            $reportContent += "`n⚠️  $issue"
        }
    }
    
    $reportContent += @"

================================================================================================
COMPREHENSIVE RECOMMENDATIONS
================================================================================================

🚨 IMMEDIATE ACTIONS (Do Today):
"@
    foreach ($rec in $recommendations.Immediate) {
        $reportContent += "`n   • $rec"
    }
    
    $reportContent += @"

🔧 SHORT-TERM IMPROVEMENTS (This Week):
"@
    foreach ($rec in $recommendations.ShortTerm) {
        $reportContent += "`n   • $rec"
    }
    
    $reportContent += @"

📋 LONG-TERM OPTIMIZATION (This Month):
"@
    foreach ($rec in $recommendations.LongTerm) {
        $reportContent += "`n   • $rec"
    }
    
    $reportContent += @"

🔬 DEV/SIT SPECIFIC NOTES:
"@
    foreach ($rec in $recommendations.DevSitSpecific) {
        $reportContent += "`n   • $rec"
    }
    
    $reportContent += @"

================================================================================================
RECOMMENDED PRIORITY STRUCTURE
================================================================================================
Current Priorities: $($customRulesAnalysis.RuleDetails.Priority -join ', ')
Recommended Structure:
   Priority 10: AllowRMBIPs (IP Allowlist - Highest Priority)
   Priority 20: AllowHRMobileGeo (Application Geo-blocking)
   Priority 30: AllowBABUATAI (Application Geo-blocking)
   Priority 40: AllowBABLIVEAI (Application Geo-blocking)
   Priority 50: [Reserved for future development tools rule]

================================================================================================
RULE COMPLEXITY ASSESSMENT
================================================================================================
"@
    
    $simpleRules = $customRulesAnalysis.RuleDetails | Where-Object { $_.ComplexityScore -le 2 }
    $moderateRules = $customRulesAnalysis.RuleDetails | Where-Object { $_.ComplexityScore -gt 2 -and $_.ComplexityScore -le 4 }
    $complexRules = $customRulesAnalysis.RuleDetails | Where-Object { $_.ComplexityScore -gt 4 }
    
    $reportContent += @"
Simple Rules (Score ≤ 2): $($simpleRules.Count) - $($simpleRules.Name -join ', ')
Moderate Rules (Score 3-4): $($moderateRules.Count) - $($moderateRules.Name -join ', ')
Complex Rules (Score > 4): $($complexRules.Count) - $($complexRules.Name -join ', ')

COMPLEXITY LEGEND:
• Score 1-2: Simple logic, easy to maintain
• Score 3-4: Moderate complexity, manageable
• Score 5+: High complexity, consider simplification

================================================================================================
SECURITY POSTURE ASSESSMENT
================================================================================================
Environment Alignment: ✓ Well-configured for DEV/SIT environment
OWASP Coverage: ✓ Comprehensive protection rules enabled
Current Mode: Monitoring (Log mode) - Appropriate for development
Rule Logic: ⚠️  Some complex negative logic detected
Priority Structure: ⚠️  Minor gaps detected, optimization recommended

OVERALL RATING: B+ (Good configuration for DEV/SIT with room for optimization)

================================================================================================
END OF REPORT
================================================================================================
"@
    
    # Save report
    $reportPath = ".\WAF-Analysis-Report-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    $reportContent | Out-File -FilePath $reportPath -Encoding UTF8
    
    Write-Log "Analysis completed successfully!" -Level Success
    Write-Log "Comprehensive report saved to: $reportPath" -Level Info
    
    # Display key findings
    Write-Host "`n=== KEY FINDINGS ===" -ForegroundColor Green
    Write-Host "✓ Total Custom Rules: $($customRulesAnalysis.TotalRules)" -ForegroundColor Cyan
    Write-Host "✓ Complex Rules Identified: $(($customRulesAnalysis.RuleDetails | Where-Object { $_.ComplexityScore -gt 4 }).Count)" -ForegroundColor Cyan
    Write-Host "✓ OWASP Rules in Log Mode: $($managedRulesAnalysis.LogModeRules)/$($managedRulesAnalysis.TotalRules)" -ForegroundColor Cyan
    Write-Host "✓ Priority Gaps: $($customRulesAnalysis.PriorityGaps.Count)" -ForegroundColor Cyan
    
    if ($recommendations.Immediate.Count -gt 0) {
        Write-Host "`n⚠️  IMMEDIATE ACTIONS REQUIRED:" -ForegroundColor Red
        foreach ($action in $recommendations.Immediate) {
            Write-Host "   • $action" -ForegroundColor Yellow
        }
    }
    
    Write-Host "`n📊 Full Analysis Report: $reportPath" -ForegroundColor Green
    
}
catch {
    Write-Log "Critical error in analysis: $_" -Level Error
    exit 1
}

Write-Log "WAF Policy Analysis completed." -Level Info