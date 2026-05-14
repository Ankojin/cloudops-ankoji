<#
.SYNOPSIS
    Bulk associate VMs with Azure Monitor Workspace Data Collection Rule

.DESCRIPTION
    Associates existing VMs that have AMA installed with the specified DCR
    for OpenTelemetry metrics collection. Skips VMs without AMA or already associated.

.PARAMETER AzureMonitorWorkspaceId
    Full resource ID of Azure Monitor Workspace

.PARAMETER ExcludeResourceGroups
    Optional. Array of resource group names to exclude (e.g., ARO clusters)

.PARAMETER IncludeResourceGroups
    Optional. Array of resource group names to include. If specified, only these RGs are processed.

.PARAMETER WhatIf
    Show what would be done without making changes

.EXAMPLE
    .\Associate-VMs-With-DCR.ps1 -AzureMonitorWorkspaceId "/subscriptions/.../bab-dev-vminsights-amw" -Verbose

.EXAMPLE
    .\Associate-VMs-With-DCR.ps1 -AzureMonitorWorkspaceId "/subscriptions/.../bab-dev-vminsights-amw" -ExcludeResourceGroups @("ARO-INFRA-*") -WhatIf

.NOTES
    Version: 1.0
    Requires: Az.Compute, Az.Monitor modules
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^/subscriptions/.+/resourcegroups/.+/providers/microsoft\.monitor/accounts/.+$')]
    [string]$AzureMonitorWorkspaceId,
    
    [Parameter(Mandatory=$false)]
    [string[]]$ExcludeResourceGroups = @("ARO-INFRA-*"),
    
    [Parameter(Mandatory=$false)]
    [string[]]$IncludeResourceGroups,
    
    [Parameter(Mandatory=$false)]
    [int]$BatchSize = 10
)

$ErrorActionPreference = 'Continue'

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string]$Level = 'INFO'
    )
    
    $colors = @{
        'INFO' = 'Cyan'
        'SUCCESS' = 'Green'
        'WARNING' = 'Yellow'
        'ERROR' = 'Red'
    }
    
    Write-Host "[$Level] $Message" -ForegroundColor $colors[$Level]
}

try {
    Write-Log "========================================================" -Level INFO
    Write-Log "Bulk VM-DCR Association Tool" -Level INFO
    Write-Log "========================================================" -Level INFO
    
    # Get workspace details
    $workspace = Get-AzResource -ResourceId $AzureMonitorWorkspaceId -ErrorAction Stop
    Write-Log "Workspace: $($workspace.Name)" -Level SUCCESS
    
    # Find DCR associated with workspace
    Write-Log "Searching for Data Collection Rule..." -Level INFO
    $workspaceName = $workspace.Name
    $managedRG = "MA_" + $workspaceName + "_*_managed*"
    
    # Strategy 1: Look for DCR with same name as workspace (portal-created)
    Write-Log "Looking for DCR named: $workspaceName" -Level INFO
    $dcr = Get-AzDataCollectionRule | Where-Object { $_.Name -eq $workspaceName }
    
    if (-not $dcr) {
        # Strategy 2: Look in managed resource group
        Write-Log "Searching in managed resource group pattern: $managedRG" -Level INFO
        $dcr = Get-AzDataCollectionRule | Where-Object { 
            $_.ResourceGroupName -like $managedRG 
        } | Select-Object -First 1
    }
    
    if (-not $dcr) {
        # Strategy 3: Look in workspace resource group
        Write-Log "Searching in workspace resource group: $($workspace.ResourceGroupName)" -Level INFO
        $dcr = Get-AzDataCollectionRule -ResourceGroupName $workspace.ResourceGroupName | 
            Where-Object { $_.Name -like "*vminsights*" -or $_.Name -like "*otel*" } |
            Select-Object -First 1
    }
    
    if (-not $dcr) {
        # Strategy 4: Find any DCR that points to this workspace
        Write-Log "Searching all DCRs for workspace destination..." -Level INFO
        $allDcrs = Get-AzDataCollectionRule
        foreach ($testDcr in $allDcrs) {
            $dcrDetails = Get-AzResource -ResourceId $testDcr.Id -ExpandProperties
            $hasWorkspace = $dcrDetails.Properties.destinations.monitoringAccounts | 
                Where-Object { $_.accountResourceId -eq $AzureMonitorWorkspaceId }
            
            if ($hasWorkspace) {
                $dcr = $testDcr
                break
            }
        }
    }
    
    if (-not $dcr) {
        throw "No DCR found for workspace: $workspaceName. Create DCR via portal first."
    }
    
    Write-Log "Found DCR: $($dcr.Name)" -Level SUCCESS
    Write-Log "  Resource Group: $($dcr.ResourceGroupName)" -Level INFO
    Write-Log "  DCR ID: $($dcr.Id)" -Level INFO
    
    # Verify DCR has workspace destination
    Write-Log "Verifying DCR destination..." -Level INFO
    $dcrDetails = Get-AzResource -ResourceId $dcr.Id -ExpandProperties
    $hasWorkspace = $dcrDetails.Properties.destinations.monitoringAccounts | 
        Where-Object { $_.accountResourceId -eq $AzureMonitorWorkspaceId }
    
    if (-not $hasWorkspace) {
        Write-Log "WARNING: DCR '$($dcr.Name)' is not configured for workspace '$workspaceName'" -Level WARNING
        Write-Log "DCR destinations:" -Level WARNING
        $dcrDetails.Properties.destinations.monitoringAccounts | ForEach-Object {
            Write-Log "  - $($_.accountResourceId)" -Level WARNING
        }
        throw "DCR is not configured to send data to specified workspace"
    }
    Write-Log "✓ DCR is configured for workspace" -Level SUCCESS
    
    Write-Log "========================================================" -Level INFO
    Write-Log "Discovering VMs..." -Level INFO
    Write-Log "========================================================" -Level INFO
    
    # Get all VMs
    $allVMs = Get-AzVM
    Write-Log "Total VMs in subscription: $($allVMs.Count)" -Level INFO
    
    # Filter by include/exclude resource groups
    $vmsToProcess = $allVMs | Where-Object {
        $vm = $_
        $rgName = $vm.ResourceGroupName
        
        # Check exclude patterns
        $excluded = $false
        foreach ($pattern in $ExcludeResourceGroups) {
            if ($rgName -like $pattern) {
                $excluded = $true
                break
            }
        }
        
        if ($excluded) { return $false }
        
        # Check include patterns (if specified)
        if ($IncludeResourceGroups) {
            $included = $false
            foreach ($pattern in $IncludeResourceGroups) {
                if ($rgName -like $pattern) {
                    $included = $true
                    break
                }
            }
            return $included
        }
        
        return $true
    }
    
    Write-Log "VMs after filtering: $($vmsToProcess.Count)" -Level INFO
    
    if ($ExcludeResourceGroups) {
        Write-Log "Excluded RG patterns: $($ExcludeResourceGroups -join ', ')" -Level INFO
    }
    if ($IncludeResourceGroups) {
        Write-Log "Included RG patterns: $($IncludeResourceGroups -join ', ')" -Level INFO
    }
    
    Write-Log "========================================================" -Level INFO
    Write-Log "Processing VMs..." -Level INFO
    Write-Log "========================================================" -Level INFO
    
    $results = @{
        Total = 0
        AlreadyAssociated = 0
        NoAMA = 0
        Associated = 0
        Failed = 0
    }
    
    $failedVMs = [System.Collections.ArrayList]::new()
    
    foreach ($vm in $vmsToProcess) {
        $results.Total++
        $vmName = $vm.Name
        $vmRG = $vm.ResourceGroupName
        $osType = $vm.StorageProfile.OsDisk.OsType
        
        Write-Log "Processing [$results.Total/$($vmsToProcess.Count)]: $vmName" -Level INFO
        
        # Check if AMA is installed
        $amaExtensionName = if ($osType -eq 'Windows') { 
            'AzureMonitorWindowsAgent' 
        } else { 
            'AzureMonitorLinuxAgent' 
        }
        
        $amaExtension = Get-AzVMExtension -ResourceGroupName $vmRG `
            -VMName $vmName `
            -Name $amaExtensionName `
            -ErrorAction SilentlyContinue
        
        if (-not $amaExtension -or $amaExtension.ProvisioningState -ne 'Succeeded') {
            Write-Log "  ⊗ Skipping - AMA not installed or failed" -Level WARNING
            $results.NoAMA++
            continue
        }
        
        # Check if already associated with our DCR
        try {
            # Build the association resource ID pattern
            $associationResourceIdPattern = "$($vm.Id)/providers/Microsoft.Insights/dataCollectionRuleAssociations/*"
            
            # Get all associations for this VM
            $allResources = Get-AzResource -ResourceGroupName $vmRG -ErrorAction SilentlyContinue
            $existingAssociations = $allResources | Where-Object { 
                $_.ResourceType -eq "Microsoft.Insights/dataCollectionRuleAssociations" -and
                $_.ResourceId -like "*$($vm.Name)*"
            }
            
            if ($existingAssociations) {
                foreach ($assoc in $existingAssociations) {
                    $assocDetails = Get-AzResource -ResourceId $assoc.ResourceId -ExpandProperties -ErrorAction SilentlyContinue
                    if ($assocDetails.Properties.dataCollectionRuleId -eq $dcr.Id) {
                        Write-Log "  ✓ Already associated with DCR" -Level SUCCESS
                        $results.AlreadyAssociated++
                        continue
                    }
                }
            }
        }
        catch {
            # Ignore errors checking existing associations, proceed with association
            Write-Log "  ⚠ Could not check existing associations, will attempt association" -Level WARNING
        }
        
        # Associate with DCR
        $associationName = "vminsights-dcr-association-$(Get-Date -Format 'yyyyMMdd')"
        
        if ($PSCmdlet.ShouldProcess($vmName, "Associate with DCR")) {
            try {
                $association = New-AzResource `
                    -ResourceId "$($vm.Id)/providers/Microsoft.Insights/dataCollectionRuleAssociations/$associationName" `
                    -Properties @{ dataCollectionRuleId = $dcr.Id } `
                    -ApiVersion "2021-04-01" `
                    -Force `
                    -ErrorAction Stop
                
                Write-Log "  ✓ Associated with DCR successfully" -Level SUCCESS
                $results.Associated++
            }
            catch {
                Write-Log "  ✗ Failed: $_" -Level ERROR
                $results.Failed++
                [void]$failedVMs.Add([PSCustomObject]@{
                    VMName = $vmName
                    ResourceGroup = $vmRG
                    Error = $_.Exception.Message
                })
            }
        }
        else {
            Write-Log "  [WhatIf] Would associate with DCR" -Level INFO
            $results.Associated++
        }
    }
    
    Write-Log "========================================================" -Level INFO
    Write-Log "Summary" -Level INFO
    Write-Log "========================================================" -Level INFO
    Write-Log "Total VMs Processed: $($results.Total)" -Level INFO
    Write-Log "  ✓ Newly Associated: $($results.Associated)" -Level SUCCESS
    Write-Log "  ✓ Already Associated: $($results.AlreadyAssociated)" -Level SUCCESS
    Write-Log "  ⊗ Skipped (No AMA): $($results.NoAMA)" -Level WARNING
    Write-Log "  ✗ Failed: $($results.Failed)" -Level $(if($results.Failed -gt 0){'ERROR'}else{'INFO'})
    
    if ($results.Failed -gt 0) {
        Write-Log "`nFailed VMs:" -Level ERROR
        $failedVMs | Format-Table -AutoSize
    }
    
    if ($results.Associated -gt 0) {
        Write-Log "`n⏱ Metrics will start flowing in 10-15 minutes" -Level INFO
        Write-Log "Verify in Portal: VM → Monitoring → Insights" -Level INFO
    }
    
    Write-Log "========================================================" -Level INFO
    
}
catch {
    Write-Log "FATAL ERROR: $_" -Level ERROR
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level ERROR
    throw
}
