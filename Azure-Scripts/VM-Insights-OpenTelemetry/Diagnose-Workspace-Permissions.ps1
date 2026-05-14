<#
.SYNOPSIS
    Diagnose Azure Monitor Workspace permissions and configuration issues

.DESCRIPTION
    This script checks workspace configuration, role assignments, and identifies
    why "Access Denied" errors occur when viewing metrics in the portal.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$WorkspaceId = "/subscriptions/43cc4f11-ffb1-4a0d-8420-0ba3746b4248/resourcegroups/defaultresourcegroup-sec/providers/microsoft.monitor/accounts/defaultazuremonitorworkspace-sec"
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Azure Monitor Workspace Diagnostics" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Get current user context
$context = Get-AzContext
$currentUser = Get-AzADUser -UserPrincipalName $context.Account.Id -ErrorAction SilentlyContinue
if (-not $currentUser) {
    $currentUser = Get-AzADServicePrincipal -ApplicationId $context.Account.Id -ErrorAction SilentlyContinue
}

Write-Host "Current User:" -ForegroundColor Yellow
Write-Host "  Account: $($context.Account.Id)" -ForegroundColor White
Write-Host "  Object ID: $($currentUser.Id)" -ForegroundColor White
Write-Host ""

# Get workspace resource
Write-Host "Fetching workspace details..." -ForegroundColor Yellow
$workspace = Get-AzResource -ResourceId $WorkspaceId -ExpandProperties

Write-Host "Workspace Information:" -ForegroundColor Yellow
Write-Host "  Name: $($workspace.Name)" -ForegroundColor White
Write-Host "  Location: $($workspace.Location)" -ForegroundColor White
Write-Host "  Resource Group: $($workspace.ResourceGroupName)" -ForegroundColor White
Write-Host "  Provisioning State: $($workspace.Properties.provisioningState)" -ForegroundColor White
Write-Host ""

# Check workspace properties
Write-Host "Workspace Properties:" -ForegroundColor Yellow
if ($workspace.Properties.publicNetworkAccess) {
    Write-Host "  Public Network Access: $($workspace.Properties.publicNetworkAccess)" -ForegroundColor $(if($workspace.Properties.publicNetworkAccess -eq 'Enabled'){'Green'}else{'Red'})
} else {
    Write-Host "  Public Network Access: Not Set (defaults to Enabled)" -ForegroundColor Green
}

if ($workspace.Properties.PSObject.Properties['defaultIngestionSettings']) {
    Write-Host "  Default Ingestion Settings: Present" -ForegroundColor Green
} else {
    Write-Host "  Default Ingestion Settings: Not configured" -ForegroundColor Yellow
}
Write-Host ""

# Check role assignments on workspace
Write-Host "Role Assignments on Workspace:" -ForegroundColor Yellow
$roleAssignments = Get-AzRoleAssignment -Scope $WorkspaceId | Where-Object { $_.ObjectId -eq $currentUser.Id }

if ($roleAssignments.Count -eq 0) {
    Write-Host "  ❌ NO DIRECT ROLE ASSIGNMENTS FOUND!" -ForegroundColor Red
    Write-Host "  This is likely why you see 'Access Denied' errors" -ForegroundColor Red
} else {
    foreach ($role in $roleAssignments) {
        Write-Host "  ✓ $($role.RoleDefinitionName)" -ForegroundColor Green
    }
}
Write-Host ""

# Check inherited role assignments (subscription/RG level)
Write-Host "Checking inherited permissions..." -ForegroundColor Yellow
$subRoles = Get-AzRoleAssignment -Scope "/subscriptions/$($context.Subscription.Id)" | Where-Object { $_.ObjectId -eq $currentUser.Id }
$rgRoles = Get-AzRoleAssignment -Scope "/subscriptions/$($context.Subscription.Id)/resourceGroups/$($workspace.ResourceGroupName)" | Where-Object { $_.ObjectId -eq $currentUser.Id }

Write-Host "Subscription-level roles:" -ForegroundColor Yellow
foreach ($role in $subRoles) {
    Write-Host "  • $($role.RoleDefinitionName)" -ForegroundColor Cyan
}

Write-Host "Resource Group-level roles:" -ForegroundColor Yellow
foreach ($role in $rgRoles) {
    Write-Host "  • $($role.RoleDefinitionName)" -ForegroundColor Cyan
}
Write-Host ""

# Check DCR associations
Write-Host "Checking Data Collection Rules..." -ForegroundColor Yellow
$dcrs = Get-AzResource -ResourceType "Microsoft.Insights/dataCollectionRules" -ResourceGroupName $workspace.ResourceGroupName | 
    Where-Object { $_.Name -like "MSVMOtel-*" }

Write-Host "Found $($dcrs.Count) OpenTelemetry DCR(s):" -ForegroundColor White
foreach ($dcr in $dcrs) {
    Write-Host "  • $($dcr.Name)" -ForegroundColor White
    
    # Check DCR properties
    $dcrDetail = Get-AzResource -ResourceId $dcr.ResourceId -ExpandProperties
    if ($dcrDetail.Properties.destinations.monitoringAccounts) {
        $destWorkspace = $dcrDetail.Properties.destinations.monitoringAccounts[0].accountResourceId
        if ($destWorkspace -eq $WorkspaceId) {
            Write-Host "    ✓ Correctly configured to send to workspace" -ForegroundColor Green
        } else {
            Write-Host "    ⚠ Sending to different workspace: $destWorkspace" -ForegroundColor Yellow
        }
    }
}
Write-Host ""

# Recommendations
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "DIAGNOSIS & RECOMMENDATIONS" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$hasMonitoringReader = $roleAssignments | Where-Object { $_.RoleDefinitionName -eq "Monitoring Reader" }
$hasMonitoringDataReader = $roleAssignments | Where-Object { $_.RoleDefinitionName -eq "Monitoring Data Reader" }
$hasMonitoringContributor = $roleAssignments | Where-Object { $_.RoleDefinitionName -eq "Monitoring Contributor" }

if (-not $hasMonitoringReader -and -not $hasMonitoringDataReader) {
    Write-Host "❌ ISSUE FOUND: Missing required roles for viewing metrics" -ForegroundColor Red
    Write-Host ""
    Write-Host "You have: Monitoring Contributor" -ForegroundColor Yellow
    Write-Host "You need: Monitoring Reader + Monitoring Data Reader" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "FIX: Run these commands to grant the correct permissions:" -ForegroundColor Green
    Write-Host ""
    Write-Host "# Assign Monitoring Reader (view metrics in portal)" -ForegroundColor Cyan
    Write-Host "New-AzRoleAssignment -ObjectId $($currentUser.Id) ``" -ForegroundColor White
    Write-Host "    -RoleDefinitionName 'Monitoring Reader' ``" -ForegroundColor White
    Write-Host "    -Scope '$WorkspaceId'" -ForegroundColor White
    Write-Host ""
    Write-Host "# Assign Monitoring Data Reader (query metrics data)" -ForegroundColor Cyan
    Write-Host "New-AzRoleAssignment -ObjectId $($currentUser.Id) ``" -ForegroundColor White
    Write-Host "    -RoleDefinitionName 'Monitoring Data Reader' ``" -ForegroundColor White
    Write-Host "    -Scope '$WorkspaceId'" -ForegroundColor White
    Write-Host ""
} else {
    Write-Host "✓ You have the required roles for viewing metrics" -ForegroundColor Green
    Write-Host ""
}

# Additional checks
if ($workspace.Properties.publicNetworkAccess -eq "Disabled") {
    Write-Host "⚠ WARNING: Public network access is disabled" -ForegroundColor Yellow
    Write-Host "  This might prevent portal access. Enable with:" -ForegroundColor Yellow
    Write-Host "  Set-AzResource -ResourceId '$WorkspaceId' -Properties @{publicNetworkAccess='Enabled'} -Force" -ForegroundColor White
    Write-Host ""
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Additional Tips:" -ForegroundColor Yellow
Write-Host "  1. Role assignments can take 5-10 minutes to propagate" -ForegroundColor White
Write-Host "  2. Clear browser cache or use incognito mode after changes" -ForegroundColor White
Write-Host "  3. Try accessing: VM → Insights → Performance tab" -ForegroundColor White
Write-Host "  4. If still failing, wait for metrics data (10-15 min after migration)" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan
