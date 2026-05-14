<#
.SYNOPSIS
    Enable OpenTelemetry metrics for VMs using Azure Portal pattern

.DESCRIPTION
    Creates per-VM Data Collection Rules following the exact Azure Portal approach.
    Each VM gets its own DCR named "MSVMOtel-{location}-{vmname}".

.PARAMETER AzureMonitorWorkspaceId
    Full resource ID of Azure Monitor Workspace

.PARAMETER ResourceGroupName
    Optional. Process VMs in specific resource group only

.PARAMETER ExcludeResourceGroups
    Optional. Array of resource group patterns to exclude

.PARAMETER WhatIf
    Show what would be done without making changes

.EXAMPLE
    .\Enable-OTel-Portal-Method.ps1 -AzureMonitorWorkspaceId "/subscriptions/.../bab-dev-vminsights-amw" -Verbose

.NOTES
    Version: 1.0
    Follows Azure Portal's per-VM DCR pattern
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [string]$AzureMonitorWorkspaceId,
    
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory=$false)]
    [string[]]$ExcludeResourceGroups = @("ARO-INFRA-*")
)

$ErrorActionPreference = 'Continue'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $colors = @{ 'INFO' = 'Cyan'; 'SUCCESS' = 'Green'; 'WARNING' = 'Yellow'; 'ERROR' = 'Red' }
    Write-Host "[$Level] $Message" -ForegroundColor $colors[$Level]
}

try {
    Write-Log "========================================================" -Level INFO
    Write-Log "OpenTelemetry Metrics Enablement (Portal Method)" -Level INFO
    Write-Log "========================================================" -Level INFO
    
    # Parse workspace details
    $workspace = Get-AzResource -ResourceId $AzureMonitorWorkspaceId -ErrorAction Stop
    Write-Log "Workspace: $($workspace.Name)" -Level SUCCESS
    Write-Log "Location: $($workspace.Location)" -Level INFO
    
    # Get VMs
    Write-Log "Discovering VMs..." -Level INFO
    $allVMs = if ($ResourceGroupName) {
        Get-AzVM -ResourceGroupName $ResourceGroupName
    } else {
        Get-AzVM
    }
    
    # Filter excluded RGs
    $vms = $allVMs | Where-Object {
        $rgName = $_.ResourceGroupName
        $excluded = $false
        foreach ($pattern in $ExcludeResourceGroups) {
            if ($rgName -like $pattern) { $excluded = $true; break }
        }
        -not $excluded
    }
    
    Write-Log "VMs to process: $($vms.Count)" -Level INFO
    
    $results = @{ Total = 0; Success = 0; Failed = 0; Skipped = 0 }
    
    foreach ($vm in $vms) {
        $results.Total++
        $vmName = $vm.Name.ToLower()
        $vmRG = $vm.ResourceGroupName
        $vmLocation = $vm.Location
        
        Write-Log "[$($results.Total)/$($vms.Count)] Processing: $vmName" -Level INFO
        
        # Check AMA
        $osType = $vm.StorageProfile.OsDisk.OsType
        $amaName = if ($osType -eq 'Windows') { 'AzureMonitorWindowsAgent' } else { 'AzureMonitorLinuxAgent' }
        $ama = Get-AzVMExtension -ResourceGroupName $vmRG -VMName $vm.Name -Name $amaName -ErrorAction SilentlyContinue
        
        if (-not $ama -or $ama.ProvisioningState -ne 'Succeeded') {
            Write-Log "  ⊗ Skipping - AMA not installed" -Level WARNING
            $results.Skipped++
            continue
        }
        
        # DCR name following portal pattern
        $dcrName = "MSVMOtel-$vmLocation-$vmName"
        
        # Check if DCR already exists
        $existingDcr = Get-AzDataCollectionRule -ResourceGroupName $vmRG -Name $dcrName -ErrorAction SilentlyContinue
        
        if ($existingDcr) {
            Write-Log "  ✓ DCR already exists: $dcrName" -Level SUCCESS
            
            # Check association
            $assoc = Get-AzResource -ResourceId "$($vm.Id)/providers/Microsoft.Insights/dataCollectionRuleAssociations/VirtualMachineInsightsMetricsExtension" -ErrorAction SilentlyContinue
            
            if ($assoc) {
                Write-Log "  ✓ Already configured" -Level SUCCESS
                $results.Success++
                continue
            }
        }
        
        if ($PSCmdlet.ShouldProcess($vmName, "Create DCR and Association")) {
            try {
                # ARM template following portal pattern
                $template = @{
                    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
                    contentVersion = '1.0.0.0'
                    resources = @(
                        @{
                            type = 'Microsoft.Insights/dataCollectionRules'
                            apiVersion = '2024-03-11'
                            location = $vmLocation
                            name = $dcrName
                            properties = @{
                                dataSources = @{
                                    performanceCountersOTel = @(
                                        @{
                                            streams = @('Microsoft-OtelPerfMetrics')
                                            samplingFrequencyInSeconds = 60
                                            counterSpecifiers = @(
                                                'system.filesystem.usage'
                                                'system.disk.io'
                                                'system.disk.operation_time'
                                                'system.disk.operations'
                                                'system.memory.usage'
                                                'system.network.io'
                                                'system.cpu.time'
                                                'system.network.dropped'
                                                'system.network.errors'
                                                'system.uptime'
                                            )
                                            name = 'OtelDataSource'
                                        }
                                    )
                                }
                                destinations = @{
                                    monitoringAccounts = @(
                                        @{
                                            accountResourceId = $AzureMonitorWorkspaceId
                                            name = 'MonitoringAccountDestination'
                                        }
                                    )
                                }
                                dataFlows = @(
                                    @{
                                        streams = @('Microsoft-OtelPerfMetrics')
                                        destinations = @('MonitoringAccountDestination')
                                    }
                                )
                            }
                        }
                        @{
                            type = 'Microsoft.Insights/dataCollectionRuleAssociations'
                            apiVersion = '2022-06-01'
                            name = 'VirtualMachineInsightsMetricsExtension'
                            dependsOn = @("[resourceId('Microsoft.Insights/dataCollectionRules', '$dcrName')]")
                            scope = $vm.Id
                            properties = @{
                                description = 'Association of data collection rule. Deleting this association will break the metrics collection for this virtual machine.'
                                dataCollectionRuleId = "[resourceId('Microsoft.Insights/dataCollectionRules', '$dcrName')]"
                            }
                        }
                    )
                }
                
                # Deploy
                $deploymentName = "EnableOTel-$vmName-$(Get-Date -Format 'yyyyMMddHHmmss')"
                
                New-AzResourceGroupDeployment `
                    -ResourceGroupName $vmRG `
                    -Name $deploymentName `
                    -TemplateObject $template `
                    -ErrorAction Stop | Out-Null
                
                Write-Log "  ✓ Enabled OpenTelemetry metrics" -Level SUCCESS
                $results.Success++
            }
            catch {
                Write-Log "  ✗ Failed: $_" -Level ERROR
                $results.Failed++
            }
        }
        else {
            Write-Log "  [WhatIf] Would create DCR and association" -Level INFO
            $results.Success++
        }
    }
    
    Write-Log "========================================================" -Level INFO
    Write-Log "Summary" -Level INFO
    Write-Log "========================================================" -Level INFO
    Write-Log "Total: $($results.Total)" -Level INFO
    Write-Log "  ✓ Success: $($results.Success)" -Level SUCCESS
    Write-Log "  ⊗ Skipped: $($results.Skipped)" -Level WARNING
    Write-Log "  ✗ Failed: $($results.Failed)" -Level $(if($results.Failed -gt 0){'ERROR'}else{'INFO'})
    Write-Log "========================================================" -Level INFO
    
}
catch {
    Write-Log "FATAL ERROR: $_" -Level ERROR
    throw
}
