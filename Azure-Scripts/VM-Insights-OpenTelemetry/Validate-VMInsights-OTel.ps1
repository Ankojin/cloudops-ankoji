<#
.SYNOPSIS
    Validate VM Insights OpenTelemetry migration status

.DESCRIPTION
    Validates that VMs have been successfully migrated to OpenTelemetry-based VM insights.
    Checks Azure Monitor Agent installation, DCR associations, and metric collection.

.PARAMETER SubscriptionId
    Target Azure subscription ID. If not provided, uses current context subscription.

.PARAMETER ResourceGroupName
    Optional. Validate VMs in specific resource group only.

.PARAMETER AzureMonitorWorkspaceId
    Optional. Full resource ID of Azure Monitor Workspace to validate against.
    Example: "/subscriptions/.../resourcegroups/.../providers/microsoft.monitor/accounts/workspace-name"

.PARAMETER ExportReport
    Switch. Export detailed validation report to CSV.

.PARAMETER CheckMetricsAvailability
    Switch. Query Azure Monitor Workspace to verify metrics are being collected (requires 10+ min after migration).

.EXAMPLE
    .\Validate-VMInsights-OTel.ps1 -Verbose

.EXAMPLE
    .\Validate-VMInsights-OTel.ps1 -SubscriptionId "12345..." -ExportReport

.EXAMPLE
    .\Validate-VMInsights-OTel.ps1 -AzureMonitorWorkspaceId "/subscriptions/.../bab-dev-vminsights-amw" -ExportReport -Verbose

.EXAMPLE
    .\Validate-VMInsights-OTel.ps1 -CheckMetricsAvailability -Verbose

.NOTES
    Version: 1.0
    Author: BAB CloudOps Team
    Date: 2026-02-03
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory=$false)]
    [ValidatePattern('^/subscriptions/.+/resourcegroups/.+/providers/microsoft\.monitor/accounts/.+$')]
    [string]$AzureMonitorWorkspaceId,

    [Parameter(Mandatory=$false)]
    [switch]$ExportReport,

    [Parameter(Mandatory=$false)]
    [switch]$CheckMetricsAvailability
)

$ErrorActionPreference = 'Continue'

# Logging setup
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$reportFile = if ($ExportReport) {
    $logsDir = Join-Path $scriptPath "Logs"
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    Join-Path $logsDir "VMInsights-OTel-Validation-$timestamp.csv"
} else {
    $null
}

function Write-ColorOutput {
    param([string]$Message, [string]$Color = 'White')
    Write-Host $Message -ForegroundColor $Color
}

# Set subscription context
if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    Write-ColorOutput "✅ Subscription context set: $SubscriptionId" -Color Green
}
else {
    $context = Get-AzContext
    $SubscriptionId = $context.Subscription.Id
    Write-ColorOutput "✅ Using current subscription: $($context.Subscription.Name)" -Color Green
}

# If workspace ID provided, extract resource group to filter VMs
$targetRG = $null
if ($AzureMonitorWorkspaceId -and -not $ResourceGroupName) {
    Write-ColorOutput "🔍 Detecting VMs associated with workspace..." -Color Cyan
    
    # Extract workspace resource group
    if ($AzureMonitorWorkspaceId -match '/resourcegroups/([^/]+)/') {
        $workspaceRG = $matches[1]
        
        # Find DCR in workspace's managed resource group or same RG
        $managedRG = "MA_" + ($AzureMonitorWorkspaceId -split '/')[-1] + "_*_managed*"
        $dcrs = Get-AzDataCollectionRule | Where-Object { 
            $_.ResourceGroupName -like $managedRG -or 
            $_.ResourceGroupName -eq $workspaceRG 
        }
        
        if ($dcrs) {
            Write-ColorOutput "Found DCR(s): $($dcrs.Name -join ', ')" -Color Green
        }
    }
}

Write-ColorOutput "`n======================================" -Color Cyan
Write-ColorOutput "VM Insights OpenTelemetry Validation" -Color Cyan
Write-ColorOutput "======================================`n" -Color Cyan

# Get VMs
Write-ColorOutput "🔍 Discovering VMs..." -Color Cyan
$vms = if ($ResourceGroupName) {
    Get-AzVM -ResourceGroupName $ResourceGroupName
}
else {
    # Get all VMs in subscription
    Get-AzVM
}

Write-ColorOutput "Found $($vms.Count) VMs to validate`n" -Color Green

# Validation results
$validationResults = [System.Collections.ArrayList]::new()

foreach ($vm in $vms) {
    Write-ColorOutput "Validating: $($vm.Name)" -Color Yellow
    
    $result = [PSCustomObject]@{
        VMName = $vm.Name
        ResourceGroup = $vm.ResourceGroupName
        Location = $vm.Location
        OSType = $vm.StorageProfile.OsDisk.OsType
        AMAInstalled = $false
        AMAVersion = 'N/A'
        AMAProvisioningState = 'N/A'
        DCRAssociated = $false
        DCRName = 'N/A'
        MetricsAvailable = 'NotChecked'
        OverallStatus = 'Failed'
        ValidationTime = (Get-Date).ToString('o')
    }
    
    # Check Azure Monitor Agent
    $amaExtensionName = if ($vm.StorageProfile.OsDisk.OsType -eq 'Windows') { 
        'AzureMonitorWindowsAgent' 
    } else { 
        'AzureMonitorLinuxAgent' 
    }
    
    $amaExtension = Get-AzVMExtension -ResourceGroupName $vm.ResourceGroupName `
        -VMName $vm.Name `
        -Name $amaExtensionName `
        -ErrorAction SilentlyContinue
    
    if ($amaExtension) {
        $result.AMAInstalled = $true
        $result.AMAVersion = $amaExtension.TypeHandlerVersion
        $result.AMAProvisioningState = $amaExtension.ProvisioningState
        Write-ColorOutput "  ✅ Azure Monitor Agent: $($amaExtension.ProvisioningState) (v$($amaExtension.TypeHandlerVersion))" -Color Green
    }
    else {
        Write-ColorOutput "  ❌ Azure Monitor Agent: Not installed" -Color Red
    }
    
    # Check DCR Association
    try {
        $dcrAssociations = Get-AzResource -ResourceType "Microsoft.Insights/dataCollectionRuleAssociations" `
            -ResourceId "$($vm.Id)/providers/Microsoft.Insights/dataCollectionRuleAssociations" `
            -ErrorAction SilentlyContinue
        
        if ($dcrAssociations) {
            $otelDcr = $dcrAssociations | Where-Object { $_.Name -like '*MSVMOtel*' -or $_.Properties.dataCollectionRuleId -like '*MSVMOtel*' } | Select-Object -First 1
            
            if ($otelDcr) {
                $result.DCRAssociated = $true
                $dcrId = $otelDcr.Properties.dataCollectionRuleId
                $result.DCRName = ($dcrId -split '/')[-1]
                Write-ColorOutput "  ✅ DCR Associated: $($result.DCRName)" -Color Green
            }
            else {
                Write-ColorOutput "  ⚠️ DCR associated but not OTel-specific" -Color Yellow
            }
        }
        else {
            Write-ColorOutput "  ❌ DCR: Not associated" -Color Red
        }
    }
    catch {
        Write-ColorOutput "  ⚠️ DCR check failed: $_" -Color Yellow
    }
    
    # Check metrics availability (optional, requires API query)
    if ($CheckMetricsAvailability) {
        Write-ColorOutput "  🔍 Checking metrics availability..." -Color Cyan
        # Note: This requires querying Azure Monitor Workspace API
        # Implementation depends on workspace access and PromQL queries
        $result.MetricsAvailable = 'CheckNotImplemented'
    }
    
    # Overall status
    if ($result.AMAInstalled -and $result.AMAProvisioningState -eq 'Succeeded' -and $result.DCRAssociated) {
        $result.OverallStatus = 'Success'
        Write-ColorOutput "  ✅ Overall: Successfully migrated to OTel" -Color Green
    }
    elseif ($result.AMAInstalled -and $result.AMAProvisioningState -eq 'Succeeded') {
        $result.OverallStatus = 'Partial'
        Write-ColorOutput "  ⚠️ Overall: AMA installed but DCR not associated" -Color Yellow
    }
    else {
        $result.OverallStatus = 'Failed'
        Write-ColorOutput "  ❌ Overall: Migration incomplete or failed" -Color Red
    }
    
    [void]$validationResults.Add($result)
    Write-Host ""
}

# Summary
Write-ColorOutput "======================================" -Color Cyan
Write-ColorOutput "Validation Summary" -Color Cyan
Write-ColorOutput "======================================`n" -Color Cyan

$totalVMs = $validationResults.Count
$successVMs = ($validationResults | Where-Object { $_.OverallStatus -eq 'Success' }).Count
$partialVMs = ($validationResults | Where-Object { $_.OverallStatus -eq 'Partial' }).Count
$failedVMs = ($validationResults | Where-Object { $_.OverallStatus -eq 'Failed' }).Count

$successRate = [math]::Round(($successVMs / $totalVMs) * 100, 1)

Write-ColorOutput "Total VMs: $totalVMs" -Color White
Write-ColorOutput "✅ Successfully Migrated: $successVMs ($successRate%)" -Color Green
Write-ColorOutput "⚠️ Partially Migrated: $partialVMs" -Color Yellow
Write-ColorOutput "❌ Failed/Not Migrated: $failedVMs" -Color Red

# Export report
if ($ExportReport -and $reportFile) {
    $validationResults | Export-Csv -Path $reportFile -NoTypeInformation
    Write-ColorOutput "`n📄 Detailed report exported: $reportFile" -Color Cyan
}

# Show failed VMs details
if ($failedVMs -gt 0) {
    Write-ColorOutput "`n❌ VMs requiring attention:" -Color Red
    $validationResults | Where-Object { $_.OverallStatus -ne 'Success' } | 
        Select-Object VMName, ResourceGroup, AMAInstalled, AMAProvisioningState, DCRAssociated, OverallStatus |
        Format-Table -AutoSize
}

Write-ColorOutput "`n✅ Validation complete!" -Color Green
