param(
    [ValidateSet("create","remove","show","validate")]
    [string]$Action = "create"
)

# ================= CONFIG =================
$ResourceGroup   = "bab-core-appgw-weeu-rg-01"
$AppGwName       = "bab-core-shared-appgw-weeu-01"
$RewriteSetName  = "rmb-preuat-remove-port"
$RewriteRuleName = "remove-9580"
$RoutingRuleName = "bab-rmbpreuat-rt-01"
$PublicHost      = "rmb-preuat.albtests.com"
$TestPath        = "/mfconsole"
# ==========================================

function Get-AppGw {
    Write-Host "Loading AppGW..." -ForegroundColor Cyan
    Get-AzApplicationGateway -Name $AppGwName -ResourceGroupName $ResourceGroup
}

function Create-Rewrite {
    $appgw = Get-AppGw

    # ---------- Rule condition ----------
    $condition = New-AzApplicationGatewayRewriteRuleCondition `
        -Variable "http_resp_Location" `
        -Pattern ":9580" `
        -IgnoreCase

    # ---------- Header action ----------
    $header = New-AzApplicationGatewayRewriteRuleHeaderConfiguration `
        -HeaderName "Location" `
        -HeaderValue "{http_resp_Location:regex_replace(':9580','')}"

    $action = New-AzApplicationGatewayRewriteRuleActionSet `
        -ResponseHeaderConfiguration $header

    # ---------- Rewrite rule ----------
    $rule = New-AzApplicationGatewayRewriteRule `
        -Name $RewriteRuleName `
        -RuleSequence 1 `
        -Condition $condition `
        -ActionSet $action

    # ---------- Rewrite rule set ----------
    $rewriteSet = New-AzApplicationGatewayRewriteRuleSet `
        -Name $RewriteSetName `
        -RewriteRule $rule

    # Remove existing rewrite set in-memory
    $appgw.RewriteRuleSets = $appgw.RewriteRuleSets | Where-Object { $_.Name -ne $RewriteSetName }
    $appgw.RewriteRuleSets += $rewriteSet

    Write-Host "Saving rewrite set to AppGW..." -ForegroundColor Yellow
    Set-AzApplicationGateway -ApplicationGateway $appgw

    # ---------- Reload AppGW ----------
    $appgw = Get-AppGw

    $rr = $appgw.RequestRoutingRules | Where-Object { $_.Name -eq $RoutingRuleName }
    if (-not $rr) { throw "Routing rule not found: $RoutingRuleName" }

    $rr.RewriteRuleSet = [Microsoft.Azure.Commands.Network.Models.PSResourceId]@{
        Id = "$($appgw.Id)/rewriteRuleSets/$RewriteSetName"
    }

    Write-Host "Attaching rewrite set to routing rule..." -ForegroundColor Yellow
    Set-AzApplicationGateway -ApplicationGateway $appgw

    Write-Host "✅ Rewrite rule deployed successfully" -ForegroundColor Green
}

function Remove-Rewrite {
    $appgw = Get-AppGw

    foreach ($rr in $appgw.RequestRoutingRules) {
        if ($rr.RewriteRuleSet -and $rr.RewriteRuleSet.Id -like "*$RewriteSetName") {
            $rr.RewriteRuleSet = $null
        }
    }

    $appgw.RewriteRuleSets = $appgw.RewriteRuleSets | Where-Object { $_.Name -ne $RewriteSetName }

    Set-AzApplicationGateway -ApplicationGateway $appgw
    Write-Host "✅ Rewrite rules removed" -ForegroundColor Green
}

function Show-Info {
    $appgw = Get-AppGw
    Write-Host "`nRewrite Rule Sets:" -ForegroundColor Cyan
    $appgw.RewriteRuleSets.Name

    Write-Host "`nRouting Rule Mapping:" -ForegroundColor Cyan
    foreach ($rr in $appgw.RequestRoutingRules) {
        $rs = if ($rr.RewriteRuleSet) { $rr.RewriteRuleSet.Id } else { "<none>" }
        Write-Host ("{0,-25} → {1}" -f $rr.Name, $rs)
    }
}

function Validate-Rewrite {
    $uri = "https://$PublicHost$TestPath"
    Write-Host "Requesting $uri (no redirects)..." -ForegroundColor Cyan

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = New-Object System.Net.Http.HttpClient($handler)

    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $uri)
    $req.Headers.Host = $PublicHost

    $resp = $client.SendAsync($req).Result

    Write-Host "Status: $($resp.StatusCode)"

    if ($resp.Headers.Location) {
        $loc = $resp.Headers.Location.ToString()
        Write-Host "Location: $loc"

        if ($loc -match ":9580") {
            Write-Host "❌ FAILED → :9580 still present" -ForegroundColor Red
        } else {
            Write-Host "✅ SUCCESS → port removed" -ForegroundColor Green
        }
    } else {
        Write-Host "No Location header returned"
    }

    $client.Dispose()
}

# ================= EXECUTION =================
switch ($Action) {
    "create"   { Create-Rewrite }
    "remove"   { Remove-Rewrite }
    "show"     { Show-Info }
    "validate" { Validate-Rewrite }
}