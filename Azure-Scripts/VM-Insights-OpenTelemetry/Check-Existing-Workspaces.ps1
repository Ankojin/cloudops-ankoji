<#
.SYNOPSIS
    Check existing workspaces in your subscription

.DESCRIPTION
    Lists both Log Analytics workspaces (old) and Azure Monitor workspaces (new)
    to help decide whether to reuse or create new ones.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId
)

try {
    # Set subscription context
    if ($SubscriptionId) {
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    }
    
    $context = Get-AzContext
    Write-Host "`n✅ Current Subscription: $($context.Subscription.Name)" -ForegroundColor Green
    Write-Host "   ID: $($context.Subscription.Id)`n" -ForegroundColor Gray
    
    # Check Log Analytics Workspaces (OLD - classic VM insights)
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "📊 Log Analytics Workspaces (Classic VM Insights)" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    
    $lawWorkspaces = Get-AzOperationalInsightsWorkspace
    
    if ($lawWorkspaces) {
        foreach ($ws in $lawWorkspaces) {
            Write-Host "`n  Name: " -NoNewline -ForegroundColor White
            Write-Host "$($ws.Name)" -ForegroundColor Yellow
            Write-Host "  Resource Group: $($ws.ResourceGroupName)" -ForegroundColor Gray
            Write-Host "  Location: $($ws.Location)" -ForegroundColor Gray
            Write-Host "  Resource ID: $($ws.ResourceId)" -ForegroundColor DarkGray
            
            # Show how to use this workspace
            Write-Host "`n  💡 To keep classic metrics alongside OTel:" -ForegroundColor Cyan
            Write-Host "     -EnableClassicMetrics -LogAnalyticsWorkspaceId `"$($ws.ResourceId)`"" -ForegroundColor White
        }
        
        Write-Host "`n  Total: $($lawWorkspaces.Count) Log Analytics workspace(s)" -ForegroundColor Green
    }
    else {
        Write-Host "  ⚠️  No Log Analytics workspaces found" -ForegroundColor Yellow
    }
    
    # Check Azure Monitor Workspaces (NEW - OpenTelemetry)
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "🔥 Azure Monitor Workspaces (OpenTelemetry)" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    
    $amwWorkspaces = Get-AzResource -ResourceType "Microsoft.Monitor/accounts"
    
    if ($amwWorkspaces) {
        foreach ($ws in $amwWorkspaces) {
            Write-Host "`n  Name: " -NoNewline -ForegroundColor White
            Write-Host "$($ws.Name)" -ForegroundColor Yellow
            Write-Host "  Resource Group: $($ws.ResourceGroupName)" -ForegroundColor Gray
            Write-Host "  Location: $($ws.Location)" -ForegroundColor Gray
            Write-Host "  Resource ID: $($ws.ResourceId)" -ForegroundColor DarkGray
            
            # Show how to reuse this workspace
            Write-Host "`n  💡 To reuse this workspace:" -ForegroundColor Cyan
            Write-Host "     -AzureMonitorWorkspaceName `"$($ws.Name)`" -AzureMonitorWorkspaceRG `"$($ws.ResourceGroupName)`"" -ForegroundColor White
        }
        
        Write-Host "`n  Total: $($amwWorkspaces.Count) Azure Monitor workspace(s)" -ForegroundColor Green
    }
    else {
        Write-Host "  ℹ️  No Azure Monitor workspaces found (will be created automatically)" -ForegroundColor Yellow
    }
    
    # Recommendations
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "💡 Recommendations" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    
    if ($lawWorkspaces -and -not $amwWorkspaces) {
        Write-Host "`n  1️⃣  You have Log Analytics workspaces (classic)" -ForegroundColor White
        Write-Host "     You can either:" -ForegroundColor Gray
        Write-Host "     • Migrate to OTel only (creates new Azure Monitor Workspace)" -ForegroundColor Gray
        Write-Host "     • Keep both for transition period (use -EnableClassicMetrics)" -ForegroundColor Gray
        
        Write-Host "`n  📝 Recommended for production:" -ForegroundColor Green
        Write-Host "     # Keep both during transition (1-2 weeks validation)" -ForegroundColor White
        $firstWorkspace = $lawWorkspaces[0]
        Write-Host "     .\Migrate-VMInsights-OpenTelemetry.ps1 ``" -ForegroundColor Yellow
        Write-Host "         -EnableClassicMetrics ``" -ForegroundColor Yellow
        Write-Host "         -LogAnalyticsWorkspaceId `"$($firstWorkspace.ResourceId)`" ``" -ForegroundColor Yellow
        Write-Host "         -Verbose" -ForegroundColor Yellow
    }
    elseif ($amwWorkspaces) {
        Write-Host "`n  2️⃣  You already have Azure Monitor Workspace(s)" -ForegroundColor White
        Write-Host "     You can reuse existing workspace to centralize OTel metrics" -ForegroundColor Gray
        
        Write-Host "`n  📝 Recommended:" -ForegroundColor Green
        $firstAMW = $amwWorkspaces[0]
        Write-Host "     .\Migrate-VMInsights-OpenTelemetry.ps1 ``" -ForegroundColor Yellow
        Write-Host "         -AzureMonitorWorkspaceName `"$($firstAMW.Name)`" ``" -ForegroundColor Yellow
        Write-Host "         -AzureMonitorWorkspaceRG `"$($firstAMW.ResourceGroupName)`" ``" -ForegroundColor Yellow
        Write-Host "         -Verbose" -ForegroundColor Yellow
    }
    else {
        Write-Host "`n  3️⃣  No existing workspaces found" -ForegroundColor White
        Write-Host "     Script will create new Azure Monitor Workspace automatically" -ForegroundColor Gray
        
        Write-Host "`n  📝 Recommended for new setup:" -ForegroundColor Green
        Write-Host "     .\Migrate-VMInsights-OpenTelemetry.ps1 -Verbose" -ForegroundColor Yellow
    }
    
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor Cyan
}
catch {
    Write-Host "`n❌ Error: $_" -ForegroundColor Red
    Write-Host "`nMake sure you're logged in: Connect-AzAccount" -ForegroundColor Yellow
}
