param(
    [string]$AppGwName = "bab-core-shared-appgw-weeu-01",
    [string]$ResourceGroup = "bab-core-appgw-weeu-rg-01"
)

Write-Host "`nLoading Application Gateway..." -ForegroundColor Cyan
$appgw = Get-AzApplicationGateway -Name $AppGwName -ResourceGroupName $ResourceGroup

# -------------------------------------------------------------------------
# STEP 1 — Remove Rewrite Rule Set References from Routing Rules
# -------------------------------------------------------------------------

Write-Host "Removing rewrite rule set references from ALL routing rules..." -ForegroundColor Yellow

foreach ($rule in $appgw.RequestRoutingRules) {
    if ($rule.RewriteRuleSet) {
        Write-Host " - Clearing rewrite set from routing rule: $($rule.Name)"
        $rule.RewriteRuleSet = $null
    }
}

# -------------------------------------------------------------------------
# STEP 2 — Delete ALL Rewrite Rule Sets
# -------------------------------------------------------------------------

if ($appgw.RewriteRuleSets.Count -gt 0) {
    Write-Host "`nDeleting all rewrite rule sets..." -ForegroundColor Yellow

    $toRemove = @($appgw.RewriteRuleSets)

    foreach ($rrs in $toRemove) {
        Write-Host " - Deleting rewrite rule set: $($rrs.Name)"
        
        # No -Force parameter in your module version
        Remove-AzApplicationGatewayRewriteRuleSet `
            -ApplicationGateway $appgw `
            -Name $rrs.Name
    }
}
else {
    Write-Host "No rewrite rule sets found." -ForegroundColor Gray
}

# -------------------------------------------------------------------------
# STEP 3 — Apply Updated App Gateway Config
# -------------------------------------------------------------------------

Write-Host "`nUpdating Application Gateway... (This takes 3–7 minutes)" -ForegroundColor Cyan
Set-AzApplicationGateway -ApplicationGateway $appgw

Write-Host "`n✔ Application Gateway Rewrite Configuration Reset Complete!" -ForegroundColor Green
