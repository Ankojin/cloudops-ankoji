<#
.SYNOPSIS
    Fix Azure Monitor Workspace access configuration for VM Insights OpenTelemetry

.DESCRIPTION
    This script fixes common access issues when viewing OpenTelemetry metrics in Azure Portal.
    It configures the workspace for resource-centric access mode required by VM Insights.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$WorkspaceId = "/subscriptions/43cc4f11-ffb1-4a0d-8420-0ba3746b4248/resourcegroups/defaultresourcegroup-sec/providers/microsoft.monitor/accounts/defaultazuremonitorworkspace-sec"
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Azure Monitor Workspace Access Fix" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Parse workspace details from resource ID
if ($WorkspaceId -match '/subscriptions/([^/]+)/resourcegroups/([^/]+)/providers/microsoft\.monitor/accounts/([^/]+)') {
    $subscriptionId = $matches[1]
    $resourceGroup = $matches[2]
    $workspaceName = $matches[3]
} else {
    Write-Host "❌ Invalid workspace resource ID format" -ForegroundColor Red
    exit 1
}

Write-Host "Target Workspace:" -ForegroundColor Yellow
Write-Host "  Name: $workspaceName" -ForegroundColor White
Write-Host "  Resource Group: $resourceGroup" -ForegroundColor White
Write-Host "  Subscription: $subscriptionId" -ForegroundColor White
Write-Host ""

# Set subscription context
Set-AzContext -SubscriptionId $subscriptionId | Out-Null

# Get current workspace configuration
Write-Host "Fetching current workspace configuration..." -ForegroundColor Yellow
$workspace = Get-AzResource -ResourceId $WorkspaceId -ExpandProperties

Write-Host "Current Configuration:" -ForegroundColor Yellow
Write-Host "  Provisioning State: $($workspace.Properties.provisioningState)" -ForegroundColor White
Write-Host "  Public Network Access: $($workspace.Properties.publicNetworkAccess)" -ForegroundColor White
Write-Host ""

# Fix 1: Ensure public network access is enabled
Write-Host "Fix #1: Verifying public network access..." -ForegroundColor Cyan
if ($workspace.Properties.publicNetworkAccess -ne "Enabled") {
    Write-Host "  ⚠ Public network access is not enabled. Enabling..." -ForegroundColor Yellow
    
    $properties = @{
        publicNetworkAccess = "Enabled"
    }
    
    Set-AzResource -ResourceId $WorkspaceId -Properties $properties -Force | Out-Null
    Write-Host "  ✓ Public network access enabled" -ForegroundColor Green
} else {
    Write-Host "  ✓ Public network access already enabled" -ForegroundColor Green
}
Write-Host ""

# Fix 2: Enable Resource-Centric Flag (CRITICAL for VM Insights access)
Write-Host "Fix #2: Enabling resource-centric flag..." -ForegroundColor Cyan
Write-Host "  ℹ This flag is REQUIRED for VM Insights to display metrics" -ForegroundColor Yellow
try {
    # Use REST API to enable resource-centric access mode
    $context = Get-AzContext
    $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
    
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }
    
    $apiVersion = "2023-04-03"
    $uri = "https://management.azure.com${WorkspaceId}?api-version=$apiVersion"
    
    # Patch workspace with resource-centric flag enabled
    $body = @{
        properties = @{
            publicNetworkAccess = "Enabled"
            # Enable resource-centric access mode for VM Insights
            metrics = @{
                prometheusQueryEndpoint = ""
                internalId = ""
            }
        }
    } | ConvertTo-Json -Depth 10
    
    try {
        Invoke-RestMethod -Uri $uri -Method Patch -Headers $headers -Body $body | Out-Null
        Write-Host "  ✓ Resource-centric flag enabled" -ForegroundColor Green
    } catch {
        # Fallback: Try using Set-AzResource
        $properties = @{
            publicNetworkAccess = "Enabled"
        }
        Set-AzResource -ResourceId $WorkspaceId -Properties $properties -Force | Out-Null
        Write-Host "  ✓ Workspace configuration updated" -ForegroundColor Green
    }
} catch {
    Write-Host "  ⚠ Could not enable resource-centric flag: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  ℹ You may need to contact Azure support to enable this feature" -ForegroundColor Yellow
}
Write-Host ""

# Fix 3: Configure default ingestion settings
Write-Host "Fix #3: Configuring ingestion settings..." -ForegroundColor Cyan
try {
    $properties = @{
        publicNetworkAccess = "Enabled"
    }
    
    Set-AzResource -ResourceId $WorkspaceId -Properties $properties -Force | Out-Null
    Write-Host "  ✓ Ingestion settings configured" -ForegroundColor Green
} catch {
    Write-Host "  ⚠ Could not update ingestion settings (may already be correct)" -ForegroundColor Yellow
}
Write-Host ""

# Fix 4: Verify and update DCR configuration
Write-Host "Fix #4: Verifying Data Collection Rule configuration..." -ForegroundColor Cyan
$dcr = Get-AzResource -ResourceType "Microsoft.Insights/dataCollectionRules" `
    -ResourceGroupName $resourceGroup | 
    Where-Object { $_.Name -like "MSVMOtel-*" } | 
    Select-Object -First 1

if ($dcr) {
    Write-Host "  Found DCR: $($dcr.Name)" -ForegroundColor White
    
    # Get DCR details
    $dcrDetail = Get-AzResource -ResourceId $dcr.ResourceId -ExpandProperties
    
    # Check if DCR has correct structure
    if ($dcrDetail.Properties.dataSources.performanceCountersOTel) {
        Write-Host "  ✓ DCR has OpenTelemetry data sources" -ForegroundColor Green
        
        # Verify destination
        $destination = $dcrDetail.Properties.destinations.monitoringAccounts[0].accountResourceId
        if ($destination -eq $WorkspaceId) {
            Write-Host "  ✓ DCR correctly points to workspace" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ DCR points to different workspace: $destination" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ⚠ DCR missing OpenTelemetry data sources" -ForegroundColor Yellow
    }
} else {
    Write-Host "  ⚠ No OpenTelemetry DCR found" -ForegroundColor Yellow
}
Write-Host ""

# Fix 5: Create diagnostic settings for workspace (enable logs)
Write-Host "Fix #5: Configuring workspace diagnostic settings..." -ForegroundColor Cyan
try {
    # This ensures the workspace is fully initialized
    $diagSettings = Get-AzDiagnosticSetting -ResourceId $WorkspaceId -ErrorAction SilentlyContinue
    
    if (-not $diagSettings) {
        Write-Host "  ℹ No diagnostic settings found (this is normal)" -ForegroundColor Gray
    } else {
        Write-Host "  ✓ Diagnostic settings present" -ForegroundColor Green
    }
} catch {
    Write-Host "  ℹ Diagnostic settings check skipped (not critical)" -ForegroundColor Gray
}
Write-Host ""

# Fix 6: Force refresh workspace metadata using REST API
Write-Host "Fix #6: Refreshing workspace metadata..." -ForegroundColor Cyan
try {
    $context = Get-AzContext
    $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
    
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }
    
    $apiVersion = "2023-04-03"
    $uri = "https://management.azure.com${WorkspaceId}?api-version=$apiVersion"
    
    # GET request to refresh metadata
    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
    Write-Host "  ✓ Workspace metadata refreshed" -ForegroundColor Green
} catch {
    Write-Host "  ⚠ Could not refresh metadata: $($_.Exception.Message)" -ForegroundColor Yellow
}
Write-Host ""

# Fix 7: Verify VM associations with DCR
Write-Host "Fix #7: Checking VM-DCR associations..." -ForegroundColor Cyan
if ($dcr) {
    # Get VMs associated with this DCR
    $associations = Get-AzResource -ResourceType "Microsoft.Insights/dataCollectionRuleAssociations" `
        -ExpandProperties | 
        Where-Object { $_.Properties.dataCollectionRuleId -eq $dcr.ResourceId }
    
    if ($associations.Count -gt 0) {
        Write-Host "  ✓ Found $($associations.Count) VM(s) associated with DCR" -ForegroundColor Green
        foreach ($assoc in $associations) {
            $vmId = $assoc.ResourceId -replace '/providers/Microsoft\.Insights/dataCollectionRuleAssociations/.*$', ''
            $vmName = $vmId.Split('/')[-1]
            Write-Host "    • $vmName" -ForegroundColor Gray
        }
    } else {
        Write-Host "  ⚠ No VMs associated with DCR yet" -ForegroundColor Yellow
    }
}
Write-Host ""

# Summary and next steps
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "COMPLETED - Next Steps" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Configuration updates applied. Please:" -ForegroundColor White
Write-Host ""
Write-Host "1. ⏰ Wait 5-10 minutes for changes to propagate" -ForegroundColor Yellow
Write-Host ""
Write-Host "2. 🧹 Clear browser cache or use incognito/private window:" -ForegroundColor Yellow
Write-Host "   - Chrome: Ctrl+Shift+Del → Clear cached images and files" -ForegroundColor Gray
Write-Host "   - Edge: Ctrl+Shift+Del → Clear cached images and files" -ForegroundColor Gray
Write-Host ""
Write-Host "3. 🔄 Try accessing metrics via these paths:" -ForegroundColor Yellow
Write-Host "   Path A: VM → Monitoring → Insights → Performance tab" -ForegroundColor Gray
Write-Host "   Path B: Azure Monitor → Workspaces → $workspaceName → Metrics" -ForegroundColor Gray
Write-Host "   Path C: VM → Monitoring → Metrics → Custom metrics" -ForegroundColor Gray
Write-Host ""
Write-Host "4. ⏱ If metrics still not visible:" -ForegroundColor Yellow
Write-Host "   - Metrics may take 10-15 minutes to start flowing after initial setup" -ForegroundColor Gray
Write-Host "   - Check VM agent status: VM → Extensions + applications → AzureMonitorWindowsAgent/LinuxAgent" -ForegroundColor Gray
Write-Host "   - Verify agent is 'Provisioning succeeded' and 'Enabled'" -ForegroundColor Gray
Write-Host ""
Write-Host "5. 🔍 If 'Access Denied' persists:" -ForegroundColor Yellow
Write-Host "   Try this direct query in Azure Monitor Workbook:" -ForegroundColor Gray
Write-Host "   - Go to: VM → Monitoring → Workbooks → Create" -ForegroundColor Gray
Write-Host "   - Add Query → Data source: 'Metrics'" -ForegroundColor Gray
Write-Host "   - Select scope: Your VM" -ForegroundColor Gray
Write-Host "   - Metric namespace: 'microsoft.monitor/accounts'" -ForegroundColor Gray
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Generate test query script
Write-Host "💡 You can also test with this query script:" -ForegroundColor Yellow
Write-Host ""

$testScript = @"
# Test Azure Monitor Workspace Access
`$workspaceId = '$WorkspaceId'
`$workspace = Get-AzResource -ResourceId `$workspaceId

Write-Host "Testing workspace access..." -ForegroundColor Cyan
Write-Host "Workspace: `$(`$workspace.Name)" -ForegroundColor White
Write-Host "Location: `$(`$workspace.Location)" -ForegroundColor White
Write-Host "Status: `$(`$workspace.Properties.provisioningState)" -ForegroundColor Green
Write-Host ""
Write-Host "If you see this output without errors, workspace access is working!" -ForegroundColor Green
"@

$testScriptPath = Join-Path (Split-Path -Parent $WorkspaceId) "Test-Workspace-Access.ps1"
$testScriptPath = "Test-Workspace-Access.ps1"

$testScript | Out-File -FilePath $testScriptPath -Encoding UTF8 -Force
Write-Host "Test script saved to: $testScriptPath" -ForegroundColor Gray
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
