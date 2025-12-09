param(
    [string]$AppGwName = "bab-core-shared-appgw-weeu-01",
    [string]$ResourceGroup = "bab-core-appgw-weeu-rg-01",
    [string]$RewriteSetName = "rmb-preuat-remove-port",
    [string]$RoutingRuleName = "bab-rmbpreuat-rt-01"
)

Write-Host "Loading Application Gateway..." -ForegroundColor Cyan
$appgw = Get-AzApplicationGateway -Name $AppGwName -ResourceGroupName $ResourceGroup
if (-not $appgw) { throw "Application Gateway not found: $AppGwName in RG $ResourceGroup" }

# ---------------------------
# Rule 1 - remove :9580 from Location header (absolute redirects)
# ---------------------------
$cond1 = New-AzApplicationGatewayRewriteRuleCondition `
    -Variable "http_resp_Location" `
    -Pattern ":9580"

$header1 = New-AzApplicationGatewayRewriteRuleHeaderConfiguration `
    -HeaderName "Location" `
    -HeaderValue "{http_resp_Location:regex_replace(':9580','')}"

$action1 = New-AzApplicationGatewayRewriteRuleActionSet `
    -ResponseHeaderConfiguration @($header1)

$rule1 = New-AzApplicationGatewayRewriteRule `
    -Name "remove-9580" `
    -RuleSequence 1 `
    -Condition @($cond1) `
    -ActionSet $action1

# ---------------------------
# Rule 2 - fix relative redirects (e.g., "mfconsole" or "authService/..." → "/mfconsole" etc.)
# ---------------------------
$cond2 = New-AzApplicationGatewayRewriteRuleCondition `
    -Variable "http_resp_Location" `
    -Pattern "^(?!https)(.*)"

$header2 = New-AzApplicationGatewayRewriteRuleHeaderConfiguration `
    -HeaderName "Location" `
    -HeaderValue "/{http_resp_Location}"

$action2 = New-AzApplicationGatewayRewriteRuleActionSet `
    -ResponseHeaderConfiguration @($header2)

$rule2 = New-AzApplicationGatewayRewriteRule `
    -Name "fix-relative-redirects" `
    -RuleSequence 2 `
    -Condition @($cond2) `
    -ActionSet $action2

# ---------------------------
# Create or update the rewrite rule set
# ---------------------------
$existingSet = Get-AzApplicationGatewayRewriteRuleSet -ApplicationGateway $appgw -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $RewriteSetName }

if ($existingSet) {
    Write-Host "Updating existing rewrite rule set: $RewriteSetName" -ForegroundColor Yellow
    # Clear and re-add rules
    $existingSet.RewriteRules.Clear()
    $existingSet.RewriteRules.Add($rule1)
    $existingSet.RewriteRules.Add($rule2)
    Set-AzApplicationGatewayRewriteRuleSet -ApplicationGateway $appgw -Name $RewriteSetName -RewriteRule $existingSet.RewriteRules
    $rewriteSet = $existingSet
} else {
    Write-Host "Creating new rewrite rule set: $RewriteSetName" -ForegroundColor Yellow
    Add-AzApplicationGatewayRewriteRuleSet -ApplicationGateway $appgw -Name $RewriteSetName -RewriteRule @($rule1, $rule2)
    # refresh object
    $appgw = Get-AzApplicationGateway -Name $AppGwName -ResourceGroupName $ResourceGroup
    $rewriteSet = ($appgw.RewriteRuleSets | Where-Object { $_.Name -eq $RewriteSetName })
}

# ---------------------------
# Attach rewrite set to routing rule
# ---------------------------
$rtRule = $appgw.RequestRoutingRules | Where-Object { $_.Name -eq $RoutingRuleName }
if (-not $rtRule) { throw "Routing rule not found: $RoutingRuleName" }

# set reference (PSResourceId object)
$psId = New-Object Microsoft.Azure.Commands.Network.Models.PSResourceId
$psId.Id = "$($appgw.Id)/rewriteRuleSets/$RewriteSetName"
$rtRule.RewriteRuleSet = $psId

# Ensure rewrite set present in top-level collection (some modules require it)
if (-not ($appgw.RewriteRuleSets | Where-Object { $_.Name -eq $RewriteSetName })) {
    $appgw.RewriteRuleSets.Add($rewriteSet)
}

Write-Host "Applying configuration to Application Gateway (this can take a few minutes)..." -ForegroundColor Cyan
Set-AzApplicationGateway -ApplicationGateway $appgw

Write-Host "Done. Rewrite set '$RewriteSetName' with rules 'remove-9580' and 'fix-relative-redirects' attached to routing rule '$RoutingRuleName'." -ForegroundColor Green