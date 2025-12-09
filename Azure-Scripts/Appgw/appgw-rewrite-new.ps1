# ================================
# Variables
# ================================
$AppGwName = "bab-core-shared-appgw-weeu-01"
$ResourceGroup = "bab-core-appgw-weeu-rg-01"
$RewriteSetName = "rmb-preuat-remove-port"
$RewriteRuleName = "rmb-preuatRemovePort9580"
$RoutingRuleName = "bab-rmbpreuat-rt-01"
$PublicHost = "rmb-preuat.albtests.com"

# Location header rewrite target
$RewriteHeaderName = "Location"
$RewriteHeaderValue = "https://$PublicHost{var_uri_path}{var_query_string}"

Write-Host "Configuring Rewrite Rule Set: $RewriteSetName" -ForegroundColor Cyan

# ================================
# 1. Create or Update Rewrite Rule Set
# ================================
$set = az network application-gateway rewrite-rule set list `
    --gateway-name $AppGwName `
    --resource-group $ResourceGroup `
    --query "[?name=='$RewriteSetName']" | ConvertFrom-Json

if (-not $set) {
    Write-Host "Creating rewrite rule set..."
    az network application-gateway rewrite-rule set create `
        --gateway-name $AppGwName `
        --resource-group $ResourceGroup `
        --name $RewriteSetName | Out-Null
} else {
    Write-Host "Rewrite rule set exists."
}

# ================================
# 2. Create Rewrite Rule (must include ActionSet)
# ================================
$rule = az network application-gateway rewrite-rule list `
    --gateway-name $AppGwName `
    --resource-group $ResourceGroup `
    --rule-set-name $RewriteSetName `
    --query "[?name=='$RewriteRuleName']" | ConvertFrom-Json

if (-not $rule) {
    Write-Host "Creating rewrite rule..."
    az network application-gateway rewrite-rule create `
        --gateway-name $AppGwName `
        --resource-group $ResourceGroup `
        --rule-set-name $RewriteSetName `
        --name $RewriteRuleName `
        --sequence 1 `
        --response-header-name $RewriteHeaderName `
        --response-header-value $RewriteHeaderValue | Out-Null
} else {
    Write-Host "Rewrite rule exists."
}

# ================================
# 3. Add Condition (:9580 in Location header)
# ================================
Write-Host "Adding condition..."
az network application-gateway rewrite-rule condition add `
    --gateway-name $AppGwName `
    --resource-group $ResourceGroup `
    --rule-set-name $RewriteSetName `
    --rule-name $RewriteRuleName `
    --variable "http_resp_Location" `
    --pattern ":9580" `
    --ignore-case true | Out-Null

# ================================
# 4. Update the Action (set Location header)
# ================================
Write-Host "Updating action..."
az network application-gateway rewrite-rule update `
    --gateway-name $AppGwName `
    --resource-group $ResourceGroup `
    --rule-set-name $RewriteSetName `
    --name $RewriteRuleName `
    --response-header-name $RewriteHeaderName `
    --response-header-value $RewriteHeaderValue | Out-Null

# ================================
# 5. Attach Rewrite Set to Routing Rule
# ================================
Write-Host "Attaching rewrite rule set to routing rule..."
az network application-gateway rule update `
    --gateway-name $AppGwName `
    --resource-group $ResourceGroup `
    --name $RoutingRuleName `
    --rewrite-rule-set $RewriteSetName | Out-Null

Write-Host "`n✔ Completed successfully!" -ForegroundColor White -BackgroundColor DarkGreen