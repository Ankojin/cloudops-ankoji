<#
.SYNOPSIS
    Rollback VM Insights OpenTelemetry migration

.DESCRIPTION
    Removes Azure Monitor Agent extensions and Data Collection Rule associations
    to rollback VMs from OpenTelemetry-based VM insights to previous state.
    
    WARNING: This will stop all OTel metric collection. Only use if migration
    caused issues or you need to revert to classic Log Analytics monitoring.

.PARAMETER SubscriptionId
    Target Azure subscription ID. If not provided, uses current context subscription.

.PARAMETER ResourceGroupName
    Optional. Rollback VMs in specific resource group only.

.PARAMETER RemoveAzureMonitorAgent
    Switch. Remove Azure Monitor Agent extension completely.
    Default: Only removes DCR associations (keeps AMA for future use)

.PARAMETER RemoveDataCollectionRule
    Switch. Delete the Data Collection Rule (if no other VMs are using it).
    WARNING: This is destructive and cannot be undone easily.

.PARAMETER WhatIf
    Dry-run mode. Shows what would be done without making changes.

.EXAMPLE
    # Remove DCR associations only (keeps AMA installed)
    .\Rollback-VMInsights-OTel.ps1 -Verbose

.EXAMPLE
    # Full rollback (remove AMA extensions)
    .\Rollback-VMInsights-OTel.ps1 -RemoveAzureMonitorAgent -Verbose

.EXAMPLE
    # Dry-run to preview changes
    .\Rollback-VMInsights-OTel.ps1 -RemoveAzureMonitorAgent -WhatIf

.NOTES
    Version: 1.0
    Author: BAB CloudOps Team
    Date: 2026-02-03
    
    Use Cases:
    - Migration caused performance issues
    - Need to revert to classic Log Analytics monitoring
    - Testing/validation in non-production environments
#>

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [Parameter(Mandatory=$false)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory=$false)]
    [switch]$RemoveAzureMonitorAgent,

    [Parameter(Mandatory=$false)]
    [switch]$RemoveDataCollectionRule
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Logging setup
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$logsDir = Join-Path $scriptPath "Logs"
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
$logFile = Join-Path $logsDir "VMInsights-OTel-Rollback-$timestamp.log"
$csvResultsFile = Join-Path $logsDir "VMInsights-OTel-Rollback-Results-$timestamp.csv"

$script:rollbackResults = [System.Collections.ArrayList]::new()

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "[$timestamp] [$Level] $Message"
    
    Add-Content -Path $logFile -Value $logMessage -ErrorAction SilentlyContinue
    
    switch ($Level) {
        'INFO'    { Write-Host $logMessage -ForegroundColor Cyan }
        'WARNING' { Write-Warning $logMessage }
        'ERROR'   { Write-Host $logMessage -ForegroundColor Red }
        'SUCCESS' { Write-Host $logMessage -ForegroundColor Green }
    }
}

try {
    Write-Log "======================================================" -Level INFO
    Write-Log "VM Insights OpenTelemetry Rollback Script" -Level INFO
    Write-Log "======================================================" -Level INFO
    Write-Log "⚠️ WARNING: This will remove OTel monitoring from VMs" -Level WARNING
    Write-Log "Start Time: $(Get-Date)" -Level INFO
    Write-Log "Log File: $logFile" -Level INFO
    
    # Confirm action
    if (-not $WhatIfPreference) {
        $confirmation = Read-Host "Are you sure you want to rollback VM Insights OpenTelemetry? (yes/no)"
        if ($confirmation -ne 'yes') {
            Write-Log "Rollback cancelled by user" -Level WARNING
            return
        }
    }
    
    # Set subscription context
    if (-not $SubscriptionId) {
        $context = Get-AzContext
        $SubscriptionId = $context.Subscription.Id
        Write-Log "Using current subscription: $($context.Subscription.Name) ($SubscriptionId)" -Level INFO
    }
    else {
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
        Write-Log "Switched to subscription: $SubscriptionId" -Level SUCCESS
    }
    
    Write-Log "Configuration:" -Level INFO
    Write-Log "  Remove AMA Extension: $RemoveAzureMonitorAgent" -Level INFO
    Write-Log "  Remove DCR: $RemoveDataCollectionRule" -Level INFO
    Write-Log "  WhatIf Mode: $($WhatIfPreference)" -Level INFO
    
    # Get VMs
    Write-Log "Discovering VMs..." -Level INFO
    $vms = if ($ResourceGroupName) {
        Get-AzVM -ResourceGroupName $ResourceGroupName
    }
    else {
        Get-AzVM
    }
    
    Write-Log "Found $($vms.Count) VMs to process" -Level INFO
    
    if ($vms.Count -eq 0) {
        Write-Log "No VMs found. Exiting." -Level WARNING
        return
    }
    
    # Track DCRs for potential deletion
    $dcrReferences = @{}
    
    # Process each VM
    $currentVM = 0
    foreach ($vm in $vms) {
        $currentVM++
        $vmName = $vm.Name
        $vmRG = $vm.ResourceGroupName
        
        Write-Progress -Activity "Rolling back VMs" -Status "Processing $vmName" -PercentComplete (($currentVM / $vms.Count) * 100)
        Write-Log "====== Processing: $vmName ======" -Level INFO
        
        $result = @{
            VMName = $vmName
            ResourceGroup = $vmRG
            DCRRemoved = $false
            AMARemoved = $false
            Status = 'Failed'
            Details = ''
            Timestamp = (Get-Date).ToString('o')
        }
        
        try {
            # Step 1: Remove DCR Associations
            Write-Log "Checking DCR associations for $vmName..." -Level INFO
            
            $dcrAssociations = Get-AzResource -ResourceType "Microsoft.Insights/dataCollectionRuleAssociations" `
                -ResourceId "$($vm.Id)/providers/Microsoft.Insights/dataCollectionRuleAssociations" `
                -ErrorAction SilentlyContinue
            
            if ($dcrAssociations) {
                $otelDcrs = $dcrAssociations | Where-Object { 
                    $_.Name -like '*MSVMOtel*' -or $_.Properties.dataCollectionRuleId -like '*MSVMOtel*' 
                }
                
                foreach ($dcrAssoc in $otelDcrs) {
                    $dcrId = $dcrAssoc.Properties.dataCollectionRuleId
                    $dcrName = ($dcrId -split '/')[-1]
                    
                    # Track DCR for potential deletion
                    if (-not $dcrReferences.ContainsKey($dcrId)) {
                        $dcrReferences[$dcrId] = @{
                            Name = $dcrName
                            ResourceGroup = ($dcrId -split '/')[4]
                            VMCount = 0
                        }
                    }
                    $dcrReferences[$dcrId].VMCount++
                    
                    if ($PSCmdlet.ShouldProcess($vmName, "Remove DCR association: $dcrName")) {
                        Write-Log "Removing DCR association: $dcrName" -Level INFO
                        Remove-AzResource -ResourceId $dcrAssoc.ResourceId -Force | Out-Null
                        $result.DCRRemoved = $true
                        Write-Log "DCR association removed: $dcrName" -Level SUCCESS
                    }
                }
            }
            else {
                Write-Log "No OTel DCR associations found for $vmName" -Level INFO
            }
            
            # Step 2: Remove Azure Monitor Agent (if requested)
            if ($RemoveAzureMonitorAgent) {
                $osType = $vm.StorageProfile.OsDisk.OsType
                $amaExtensionName = if ($osType -eq 'Windows') { 
                    'AzureMonitorWindowsAgent' 
                } else { 
                    'AzureMonitorLinuxAgent' 
                }
                
                $amaExtension = Get-AzVMExtension -ResourceGroupName $vmRG `
                    -VMName $vmName `
                    -Name $amaExtensionName `
                    -ErrorAction SilentlyContinue
                
                if ($amaExtension) {
                    if ($PSCmdlet.ShouldProcess($vmName, "Remove Azure Monitor Agent extension")) {
                        Write-Log "Removing Azure Monitor Agent from $vmName..." -Level INFO
                        Remove-AzVMExtension -ResourceGroupName $vmRG `
                            -VMName $vmName `
                            -Name $amaExtensionName `
                            -Force | Out-Null
                        $result.AMARemoved = $true
                        Write-Log "Azure Monitor Agent removed from $vmName" -Level SUCCESS
                    }
                }
                else {
                    Write-Log "Azure Monitor Agent not found on $vmName" -Level INFO
                }
            }
            
            # Success
            $result.Status = 'Success'
            $result.Details = "Rollback completed successfully"
            Write-Log "====== Rollback completed for: $vmName ======" -Level SUCCESS
        }
        catch {
            $result.Status = 'Failed'
            $result.Details = "Exception: $_"
            Write-Log "Rollback failed for $vmName : $_" -Level ERROR
        }
        
        [void]$script:rollbackResults.Add([PSCustomObject]$result)
    }
    
    Write-Progress -Activity "Rolling back VMs" -Completed
    
    # Step 3: Remove Data Collection Rules (if requested and no VMs using them)
    if ($RemoveDataCollectionRule) {
        Write-Log "`n====== Data Collection Rule Cleanup ======" -Level INFO
        
        foreach ($dcrId in $dcrReferences.Keys) {
            $dcr = $dcrReferences[$dcrId]
            $dcrName = $dcr.Name
            $dcrRG = $dcr.ResourceGroup
            $vmCount = $dcr.VMCount
            
            Write-Log "DCR: $dcrName (used by $vmCount VMs)" -Level INFO
            
            # Check if DCR is still associated with any VMs
            try {
                $remainingAssociations = Get-AzResource -ResourceType "Microsoft.Insights/dataCollectionRuleAssociations" | 
                    Where-Object { $_.Properties.dataCollectionRuleId -eq $dcrId }
                
                if ($remainingAssociations.Count -eq 0) {
                    if ($PSCmdlet.ShouldProcess($dcrName, "Delete Data Collection Rule")) {
                        Write-Log "Removing DCR: $dcrName (no remaining associations)" -Level INFO
                        Remove-AzResource -ResourceType "Microsoft.Insights/dataCollectionRules" `
                            -ResourceGroupName $dcrRG `
                            -Name $dcrName `
                            -Force | Out-Null
                        Write-Log "DCR removed: $dcrName" -Level SUCCESS
                    }
                }
                else {
                    Write-Log "Skipping DCR: $dcrName (still has $($remainingAssociations.Count) associations)" -Level WARNING
                }
            }
            catch {
                Write-Log "Failed to remove DCR $dcrName : $_" -Level ERROR
            }
        }
    }
    
    # Export results
    $script:rollbackResults | Export-Csv -Path $csvResultsFile -NoTypeInformation
    Write-Log "Results exported to: $csvResultsFile" -Level SUCCESS
    
    # Summary
    $totalVMs = $script:rollbackResults.Count
    $successCount = ($script:rollbackResults | Where-Object { $_.Status -eq 'Success' }).Count
    $failedCount = ($script:rollbackResults | Where-Object { $_.Status -eq 'Failed' }).Count
    $dcrRemovedCount = ($script:rollbackResults | Where-Object { $_.DCRRemoved }).Count
    $amaRemovedCount = ($script:rollbackResults | Where-Object { $_.AMARemoved }).Count
    
    Write-Log "`n======================================================" -Level INFO
    Write-Log "Rollback Summary:" -Level INFO
    Write-Log "  Total VMs: $totalVMs" -Level INFO
    Write-Log "  Success: $successCount" -Level SUCCESS
    Write-Log "  Failed: $failedCount" -Level $(if($failedCount -gt 0){'ERROR'}else{'INFO'})
    Write-Log "  DCR Associations Removed: $dcrRemovedCount" -Level INFO
    Write-Log "  AMA Extensions Removed: $amaRemovedCount" -Level INFO
    Write-Log "======================================================" -Level INFO
    Write-Log "End Time: $(Get-Date)" -Level INFO
    Write-Log "Log File: $logFile" -Level INFO
    Write-Log "Results CSV: $csvResultsFile" -Level INFO
    
    if ($successCount -gt 0) {
        Write-Log "`n⚠️ IMPORTANT: VMs are no longer sending OTel metrics" -Level WARNING
        Write-Log "To restore monitoring, either:" -Level WARNING
        Write-Log "  1. Re-run Migrate-VMInsights-OpenTelemetry.ps1" -Level WARNING
        Write-Log "  2. Enable classic Log Analytics monitoring in Azure Portal" -Level WARNING
    }
}
catch {
    Write-Log "FATAL ERROR: $_" -Level ERROR
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level ERROR
    throw
}
finally {
    $ProgressPreference = 'Continue'
}
