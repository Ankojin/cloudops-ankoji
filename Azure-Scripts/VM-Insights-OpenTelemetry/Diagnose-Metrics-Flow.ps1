<#
.SYNOPSIS
    Diagnose why metrics are not appearing in Azure Monitor Workspace

.DESCRIPTION
    Checks Azure Monitor Agent status, DCR associations, and data flow
    to troubleshoot "Access Denied" or "No Data" issues in Portal.

.PARAMETER WorkspaceResourceId
    Full resource ID of the Azure Monitor Workspace

.PARAMETER ResourceGroupName
    Optional. Specific resource group to check VMs. If omitted, checks all VMs.

.EXAMPLE
    .\Diagnose-Metrics-Flow.ps1 -WorkspaceResourceId "/subscriptions/.../vminsights-bab-dev-awm-workspace" -Verbose

.NOTES
    Version: 1.0
    Requires: Az.Compute, Az.Monitor modules
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceResourceId,
    
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName
)

$ErrorActionPreference = 'Continue'

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $colors = @{
        'INFO' = 'Cyan'
        'SUCCESS' = 'Green'
        'WARNING' = 'Yellow'
        'ERROR' = 'Red'
    }
    
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $colors[$Level]
}

function Test-AMAExtension {
    param($VM)
    
    $osType = $VM.StorageProfile.OsDisk.OsType
    $extensionName = if ($osType -eq 'Windows') { 'AzureMonitorWindowsAgent' } else { 'AzureMonitorLinuxAgent' }
    
    $extension = Get-AzVMExtension -ResourceGroupName $VM.ResourceGroupName `
        -VMName $VM.Name `
        -Name $extensionName `
        -ErrorAction SilentlyContinue
    
    return @{
        Installed = $null -ne $extension
        ProvisioningState = $extension.ProvisioningState
        TypeHandlerVersion = $extension.TypeHandlerVersion
        Extension = $extension
    }
}

try {
    Write-Log "========================================================" -Level INFO
    Write-Log "Azure Monitor Workspace - Metrics Flow Diagnostics" -Level INFO
    Write-Log "========================================================" -Level INFO
    
    # Parse workspace details
    $workspace = Get-AzResource -ResourceId $WorkspaceResourceId -ExpandProperties -ErrorAction Stop
    Write-Log "Workspace: $($workspace.Name)" -Level SUCCESS
    Write-Log "Resource Group: $($workspace.ResourceGroupName)" -Level SUCCESS
    Write-Log "Location: $($workspace.Location)" -Level SUCCESS
    
    Write-Log "========================================================" -Level INFO
    Write-Log "Step 1: Check Workspace Configuration" -Level INFO
    Write-Log "========================================================" -Level INFO
    
    $props = $workspace.Properties
    Write-Log "Public Network Access: $($props.publicNetworkAccess ?? 'Enabled (default)')" -Level INFO
    Write-Log "Provisioning State: $($props.provisioningState)" -Level $(if($props.provisioningState -eq 'Succeeded'){'SUCCESS'}else{'WARNING'})
    
    # Check for resource-centric access mode
    Write-Log "Checking workspace access mode..." -Level INFO
    if ($props.PSObject.Properties.Name -contains 'defaultIngestionSettings') {
        Write-Log "  Ingestion Settings: Configured" -Level SUCCESS
    } else {
        Write-Log "  ⚠ Resource-centric mode may not be enabled" -Level WARNING
        Write-Log "  This can cause 'Access Denied' errors in portal" -Level WARNING
    }
    
    Write-Log "========================================================" -Level INFO
    Write-Log "Step 2: Find Data Collection Rules" -Level INFO
    Write-Log "========================================================" -Level INFO
    
    $dcrs = Get-AzDataCollectionRule -ResourceGroupName $workspace.ResourceGroupName | 
            Where-Object { $_.Name -like "MSVMOtel*" -or $_.Name -like "*otel*" }
    
    if (-not $dcrs) {
        Write-Log "✗ No OpenTelemetry DCRs found!" -Level ERROR
        Write-Log "  You need to create a DCR first" -Level ERROR
        return
    }
    
    foreach ($dcr in $dcrs) {
        Write-Log "Found DCR: $($dcr.Name)" -Level SUCCESS
        Write-Log "  ID: $($dcr.Id)" -Level INFO
        Write-Log "  Location: $($dcr.Location)" -Level INFO
        Write-Log "  Provisioning State: $($dcr.ProvisioningState)" -Level $(if($dcr.ProvisioningState -eq 'Succeeded'){'SUCCESS'}else{'WARNING'})
        
        # Check if DCR has workspace destination
        $dcrDetails = Get-AzResource -ResourceId $dcr.Id -ExpandProperties
        $destinations = $dcrDetails.Properties.destinations.monitoringAccounts
        
        if ($destinations) {
            $hasWorkspace = $destinations | Where-Object { $_.accountResourceId -eq $WorkspaceResourceId }
            if ($hasWorkspace) {
                Write-Log "  ✓ DCR is configured to send data to your workspace" -Level SUCCESS
            } else {
                Write-Log "  ✗ DCR is NOT sending data to your workspace!" -Level ERROR
                Write-Log "    Current destination: $($destinations[0].accountResourceId)" -Level ERROR
            }
        }
    }
    
    Write-Log "========================================================" -Level INFO
    Write-Log "Step 3: Check VM Configuration" -Level INFO
    Write-Log "========================================================" -Level INFO
    
    # Get VMs
    $vms = if ($ResourceGroupName) {
        Get-AzVM -ResourceGroupName $ResourceGroupName
    } else {
        # Check VMs in same RG as workspace
        Get-AzVM -ResourceGroupName $workspace.ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $?) {
            Write-Log "No VMs in workspace RG, checking all VMs in subscription..." -Level INFO
            Get-AzVM | Select-Object -First 10
        }
    }
    
    if (-not $vms) {
        Write-Log "✗ No VMs found to check" -Level ERROR
        return
    }
    
    Write-Log "Checking $($vms.Count) VMs..." -Level INFO
    Write-Log "" -Level INFO
    
    $summary = @{
        Total = $vms.Count
        AMAInstalled = 0
        AMANotInstalled = 0
        DCRAssociated = 0
        DCRNotAssociated = 0
        FullyConfigured = 0
    }
    
    foreach ($vm in $vms) {
        Write-Log "VM: $($vm.Name)" -Level INFO
        Write-Log "  Resource Group: $($vm.ResourceGroupName)" -Level INFO
        Write-Log "  OS Type: $($vm.StorageProfile.OsDisk.OsType)" -Level INFO
        
        # Check AMA extension
        $amaStatus = Test-AMAExtension -VM $vm
        
        if ($amaStatus.Installed) {
            Write-Log "  ✓ Azure Monitor Agent: Installed" -Level SUCCESS
            Write-Log "    State: $($amaStatus.ProvisioningState)" -Level $(if($amaStatus.ProvisioningState -eq 'Succeeded'){'SUCCESS'}else{'WARNING'})
            Write-Log "    Version: $($amaStatus.TypeHandlerVersion)" -Level INFO
            $summary.AMAInstalled++
        } else {
            Write-Log "  ✗ Azure Monitor Agent: NOT INSTALLED" -Level ERROR
            Write-Log "    Run migration script to install AMA" -Level ERROR
            $summary.AMANotInstalled++
        }
        
        # Check DCR associations
        $vmAssociations = Get-AzResource -ResourceType "Microsoft.Insights/dataCollectionRuleAssociations" `
            | Where-Object { $_.Id -like "*$($vm.Id)*" }
        
        if ($vmAssociations) {
            Write-Log "  ✓ DCR Associations: $($vmAssociations.Count)" -Level SUCCESS
            $summary.DCRAssociated++
            
            foreach ($assoc in $vmAssociations) {
                $assocDetails = Get-AzResource -ResourceId $assoc.Id -ExpandProperties
                $dcrId = $assocDetails.Properties.dataCollectionRuleId
                $dcrName = $dcrId.Split('/')[-1]
                Write-Log "    - Associated with: $dcrName" -Level INFO
                
                # Check if this DCR is one of ours
                if ($dcrId -in $dcrs.Id) {
                    Write-Log "      ✓ This is your OpenTelemetry DCR" -Level SUCCESS
                    if ($amaStatus.Installed -and $amaStatus.ProvisioningState -eq 'Succeeded') {
                        $summary.FullyConfigured++
                    }
                }
            }
        } else {
            Write-Log "  ✗ DCR Associations: NONE" -Level ERROR
            Write-Log "    VM is not associated with any DCR!" -Level ERROR
            $summary.DCRNotAssociated++
        }
        
        Write-Log "" -Level INFO
    }
    
    Write-Log "========================================================" -Level INFO
    Write-Log "Summary" -Level INFO
    Write-Log "========================================================" -Level INFO
    Write-Log "Total VMs Checked: $($summary.Total)" -Level INFO
    Write-Log "  ✓ AMA Installed: $($summary.AMAInstalled)" -Level $(if($summary.AMAInstalled -eq $summary.Total){'SUCCESS'}else{'WARNING'})
    Write-Log "  ✗ AMA Not Installed: $($summary.AMANotInstalled)" -Level $(if($summary.AMANotInstalled -gt 0){'ERROR'}else{'SUCCESS'})
    Write-Log "  ✓ DCR Associated: $($summary.DCRAssociated)" -Level $(if($summary.DCRAssociated -eq $summary.Total){'SUCCESS'}else{'WARNING'})
    Write-Log "  ✗ Not Associated: $($summary.DCRNotAssociated)" -Level $(if($summary.DCRNotAssociated -gt 0){'ERROR'}else{'SUCCESS'})
    Write-Log "  ✓ Fully Configured: $($summary.FullyConfigured)" -Level $(if($summary.FullyConfigured -eq $summary.Total){'SUCCESS'}else{'WARNING'})
    
    Write-Log "========================================================" -Level INFO
    Write-Log "Diagnosis & Recommendations" -Level INFO
    Write-Log "========================================================" -Level INFO
    
    if ($summary.FullyConfigured -eq 0) {
        Write-Log "⚠ ROOT CAUSE: No VMs are fully configured!" -Level ERROR
        Write-Log "" -Level INFO
        Write-Log "This explains the 'Access Denied' error - no data is flowing!" -Level ERROR
        Write-Log "" -Level INFO
        
        if ($summary.AMANotInstalled -gt 0) {
            Write-Log "ACTION REQUIRED: Install Azure Monitor Agent" -Level ERROR
            Write-Log "  Run this command:" -Level INFO
            Write-Log "  .\Migrate-VMInsights-OpenTelemetry.ps1 -AzureMonitorWorkspaceId '$WorkspaceResourceId' -Verbose" -Level INFO
        }
        
        if ($summary.DCRNotAssociated -gt 0) {
            Write-Log "ACTION REQUIRED: Associate VMs with DCR" -Level ERROR
            Write-Log "  The migration script will handle this automatically" -Level INFO
        }
    } else {
        Write-Log "✓ $($summary.FullyConfigured) VMs are fully configured" -Level SUCCESS
        Write-Log "" -Level INFO
        
        if ($summary.FullyConfigured -lt $summary.Total) {
            Write-Log "⚠ Some VMs still need configuration" -Level WARNING
            Write-Log "  Run migration script for remaining VMs" -Level INFO
        }
        
        Write-Log "If metrics still not visible after 10-15 minutes:" -Level INFO
        Write-Log "  1. Wait for metrics ingestion (can take 10-15 min)" -Level INFO
        Write-Log "  2. Check VM status - must be running" -Level INFO
        Write-Log "  3. Clear browser cache and log out/in to portal" -Level INFO
        Write-Log "  4. Check Azure Monitor Agent logs on VMs" -Level INFO
    }
    
    Write-Log "========================================================" -Level INFO
    
}
catch {
    Write-Log "ERROR: $_" -Level ERROR
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level ERROR
}
