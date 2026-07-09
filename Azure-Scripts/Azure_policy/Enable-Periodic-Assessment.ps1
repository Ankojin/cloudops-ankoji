# ================================
# CONFIG
# ================================

$Subscriptions = @(
    "d88f0b5b-6660-4607-8c6a-395820400912",
    "e48414cd-f96d-4414-ae9e-da7fec844f77",
    "43cc4f11-ffb1-4a0d-8420-0ba3746b4248"
)

# CSV option:
# $Subscriptions = (Import-Csv "C:\temp\subs.csv").SubscriptionId

$PolicyDefinitionId = "/providers/Microsoft.Authorization/policyDefinitions/59efceea-0c96-497e-a4a1-4eb2290dac15"
$Location = "swedencentral"

# ================================
# LOGIN
# ================================

Connect-AzAccount

# ================================
# GET POLICY DEFINITION (IMPORTANT FIX)
# ================================

$PolicyDefinition = Get-AzPolicyDefinition -Id $PolicyDefinitionId

if (-not $PolicyDefinition) {
    throw "Policy definition not found."
}

Write-Host "Using Policy: $($PolicyDefinition.Properties.DisplayName)" -ForegroundColor Cyan

# ================================
# LOOP SUBSCRIPTIONS
# ================================

foreach ($Sub in $Subscriptions) {

    Write-Host "`n===============================" -ForegroundColor Cyan
    Write-Host "Processing Subscription: $Sub" -ForegroundColor Yellow

    Set-AzContext -SubscriptionId $Sub
    $Scope = "/subscriptions/$Sub"

    foreach ($os in @("Windows","Linux")) {

        $AssignmentName = "upd-assess-$($os.ToLower())"
        $DisplayName    = "Enable Periodic Assessment - $os"

        Write-Host "`nProcessing OS: $os" -ForegroundColor Magenta

        # Check if assignment exists
        $existing = Get-AzPolicyAssignment -Scope $Scope -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq $AssignmentName }

        if ($existing) {

            Write-Host "Assignment exists. Updating..." -ForegroundColor Yellow

            # Update parameters
            Set-AzPolicyAssignment `
                -Name $AssignmentName `
                -Scope $Scope `
                -PolicyParameterObject @{
                    assessmentMode = "AutomaticByPlatform"
                    osType         = $os
                }

            # Ensure identity exists
            if (-not $existing.Identity) {
                Write-Host "Adding managed identity..." -ForegroundColor Cyan

                Set-AzPolicyAssignment `
                    -Name $AssignmentName `
                    -Scope $Scope `
                    -IdentityType SystemAssigned
            }

            Write-Host "Updated: $AssignmentName" -ForegroundColor Green
        }
        else {

            Write-Host "Creating assignment..." -ForegroundColor Cyan

            New-AzPolicyAssignment `
                -Name $AssignmentName `
                -DisplayName $DisplayName `
                -Scope $Scope `
                -PolicyDefinition $PolicyDefinition `
                -Location $Location `
                -IdentityType SystemAssigned `
                -PolicyParameterObject @{
                    assessmentMode = "AutomaticByPlatform"
                    osType         = $os
                }

            Write-Host "Created: $AssignmentName" -ForegroundColor Green
        }
    }
}

Write-Host "`nAll subscriptions processed." -ForegroundColor Cyan