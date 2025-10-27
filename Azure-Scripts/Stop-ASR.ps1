<#
.SYNOPSIS
    Stops replication for Azure Site Recovery (ASR) Azure-to-Azure protected items and exports results to CSV
.DESCRIPTION
    This script disables replication and removes protection for Azure-to-Azure machines in Azure Site Recovery vaults.
    It works directly with Recovery Services Vaults and deletes ASR replica disks.
    Provides detailed cost analysis and reporting.
    NOTE: This script only supports Azure-to-Azure (A2A) replication scenarios.
.PARAMETER VaultSubscriptionId
    Subscription ID where the Recovery Services Vault is located
.PARAMETER VaultResourceGroup
    Resource Group containing the Recovery Services Vault
.PARAMETER VaultName
    Name of the Recovery Services Vault
.PARAMETER MachineName
    (Optional) Specific machine name to stop replication. If not provided, processes all machines.
.PARAMETER OutputPath
    (Optional) Path to save the CSV file. Default is current directory.
.PARAMETER TenantId
    (Optional) Azure Tenant ID for authentication
.PARAMETER AzureRegion
    (Optional) Azure region for cost calculation. Default is "East US".
.PARAMETER WhatIf
    (Optional) Show what would happen without making actual changes
.EXAMPLE
    .\Stop-ASR.ps1 -VaultSubscriptionId "xxx" -VaultResourceGroup "rg-asr" -VaultName "vault-asr-01"
.EXAMPLE
    .\Stop-ASR.ps1 -VaultSubscriptionId "xxx" -VaultResourceGroup "rg-asr" -VaultName "vault-asr-01" -MachineName "Server01"
.EXAMPLE
    .\Stop-ASR.ps1 -VaultSubscriptionId "xxx" -VaultResourceGroup "rg-asr" -VaultName "vault-asr-01" -WhatIf
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$VaultSubscriptionId,
    
    [Parameter(Mandatory=$true)]
    [string]$VaultResourceGroup,
    
    [Parameter(Mandatory=$true)]
    [string]$VaultName,
    
    [Parameter(Mandatory=$false)]
    [string]$MachineName,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".",
    
    [Parameter(Mandatory=$false)]
    [string]$TenantId,
    
    [Parameter(Mandatory=$false)]
    [string]$AzureRegion = "East US",
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

#region Helper Functions

# Set Azure context function
function Set-AzureContext {
    param(
        [Parameter(Mandatory=$true)]
        [string]$SubscriptionId,
        [Parameter(Mandatory=$false)]
        [string]$TenantId
    )
    
    try {
        if ($TenantId) {
            $context = Set-AzContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ErrorAction Stop
        }
        else {
            $context = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
        }
        
        Write-Verbose "Context set to subscription: $($context.Subscription.Name) ($SubscriptionId)"
        return $context
    }
    catch {
        Write-Warning "Failed to set context for subscription $SubscriptionId : $($_.Exception.Message)"
        return $null
    }
}

# Cost calculation function
function Get-ASRCostEstimate {
    param(
        [Parameter(Mandatory=$true)]
        [double]$DiskSizeGB,
        [Parameter(Mandatory=$true)]
        [string]$DiskType,
        [Parameter(Mandatory=$false)]
        [string]$Region = "East US"
    )
    
    # Azure pricing (approximate, as of 2024-2025)
    $pricing = @{
        # Managed Disk costs per GB per month
        "Standard_LRS" = 0.05      # Standard HDD LRS
        "StandardSSD_LRS" = 0.075  # Standard SSD LRS
        "Premium_LRS" = 0.135      # Premium SSD LRS
        "PremiumV2_LRS" = 0.12     # Premium SSD v2 LRS
        "UltraSSD_LRS" = 0.20      # Ultra SSD LRS
        
        # ASR specific costs
        "ASR_CacheStorage" = 0.05  # Cache storage per GB per month
    }
    
    # Normalize disk type
    $normalizedDiskType = $DiskType
    if (-not $pricing.ContainsKey($DiskType)) {
        $normalizedDiskType = "Standard_LRS"
    }
    
    # Calculate disk storage cost
    $diskStorageCost = $DiskSizeGB * $pricing[$normalizedDiskType]
    
    # Cache storage is typically 10-20% of source disk size
    $cacheStorageGB = $DiskSizeGB * 0.15
    $cacheStorageCost = $cacheStorageGB * $pricing["ASR_CacheStorage"]
    
    # Total monthly cost for this disk
    $totalMonthlyCost = $diskStorageCost + $cacheStorageCost
    
    return [PSCustomObject]@{
        DiskStorageCost = [math]::Round($diskStorageCost, 2)
        CacheStorageCost = [math]::Round($cacheStorageCost, 2)
        TotalMonthlyCost = [math]::Round($totalMonthlyCost, 2)
        CacheStorageGB = [math]::Round($cacheStorageGB, 2)
    }
}

# Get ASR disk information function for Azure-to-Azure only
function Get-ASRDiskInformation {
    param(
        [Parameter(Mandatory=$true)]
        $ReplicatedItem
    )
    
    $diskInfo = @{
        DiskCount = 0
        TotalSizeGB = 0
        TotalMonthlyCost = 0
        TotalCacheStorageGB = 0
        DiskDetails = @()
    }
    
    # Check for Azure to Azure (A2A) protected disks
    if ($ReplicatedItem.ProviderSpecificDetails.A2AProtectedManagedDisks) {
        $disks = $ReplicatedItem.ProviderSpecificDetails.A2AProtectedManagedDisks
        
        if ($disks -and $disks.Count -gt 0) {
            foreach ($disk in $disks) {
                $diskSizeGB = if ($disk.DiskCapacityInBytes) { 
                    [math]::Round($disk.DiskCapacityInBytes / 1GB, 2) 
                } else { 0 }
                
                $diskType = if ($disk.RecoveryReplicaDiskAccountType) { 
                    $disk.RecoveryReplicaDiskAccountType 
                } else { "Standard_LRS" }
                
                $costEstimate = Get-ASRCostEstimate -DiskSizeGB $diskSizeGB -DiskType $diskType
                
                $diskInfo.DiskCount++
                $diskInfo.TotalSizeGB += $diskSizeGB
                $diskInfo.TotalMonthlyCost += $costEstimate.TotalMonthlyCost
                $diskInfo.TotalCacheStorageGB += $costEstimate.CacheStorageGB
                
                $diskName = if ($disk.DiskName) { $disk.DiskName } else { $disk.DiskId }
                $diskInfo.DiskDetails += "$diskName ($diskSizeGB GB, $diskType, `$$($costEstimate.TotalMonthlyCost)/mo)"
            }
        }
    }
    
    return $diskInfo
}

# Get replication provider type
function Get-ReplicationProviderType {
    param($ProviderSpecificDetails)
    
    $typeName = $ProviderSpecificDetails.GetType().Name
    
    if ($typeName -like "*A2A*" -or $typeName -eq "ASRAzureToAzureSpecificRPIDetails") {
        return "Azure-to-Azure"
    }
    else {
        return "$typeName (Not Supported)"
    }
}

#endregion

try {
    Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║   Azure Site Recovery - Stop A2A Replication Script (ASR)     ║" -ForegroundColor Cyan
    Write-Host "║              Azure-to-Azure (A2A) Only                         ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    
    if ($WhatIf) {
        Write-Host "⚠️  Running in WhatIf mode - no changes will be made" -ForegroundColor Yellow
        Write-Host ""
    }
    
    # Verify Azure connection
    Write-Host "Verifying Azure connection..." -ForegroundColor Cyan
    try {
        $currentContext = Get-AzContext -ErrorAction Stop
        if ($null -eq $currentContext) {
            Write-Host "❌ Not connected to Azure. Please run 'Connect-AzAccount' first." -ForegroundColor Red
            if ($TenantId) {
                Write-Host "   Example: Connect-AzAccount -TenantId '$TenantId'" -ForegroundColor Gray
            }
            return
        }
        Write-Host "✓ Connected to Azure as: $($currentContext.Account.Id)" -ForegroundColor Green
    }
    catch {
        Write-Host "❌ Not connected to Azure. Please run 'Connect-AzAccount' first." -ForegroundColor Red
        return
    }
    
    # Set context to vault subscription
    Write-Host "`n📊 Setting context to ASR vault subscription..." -ForegroundColor Cyan
    $context = Set-AzureContext -SubscriptionId $VaultSubscriptionId -TenantId $TenantId
    if (-not $context) {
        Write-Host "❌ Failed to set context to subscription: $VaultSubscriptionId" -ForegroundColor Red
        return
    }
    
    $subName = $context.Subscription.Name
    Write-Host "✓ Context set to: $subName" -ForegroundColor Green
    
    # Get the Recovery Services Vault
    Write-Host "`n📊 Retrieving ASR Recovery Services Vault..." -ForegroundColor Cyan
    Write-Host "  Vault Name: $VaultName" -ForegroundColor Gray
    Write-Host "  Resource Group: $VaultResourceGroup" -ForegroundColor Gray
    
    try {
        $vault = Get-AzRecoveryServicesVault `
            -ResourceGroupName $VaultResourceGroup `
            -Name $VaultName `
            -ErrorAction Stop
        
        Write-Host "✓ Found vault: $($vault.Name) in $($vault.Location)" -ForegroundColor Green
    }
    catch {
        Write-Host "❌ Failed to retrieve vault: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "`n💡 Please verify:" -ForegroundColor Yellow
        Write-Host "  1. Vault name is correct: $VaultName" -ForegroundColor Gray
        Write-Host "  2. Resource group is correct: $VaultResourceGroup" -ForegroundColor Gray
        Write-Host "  3. Subscription is correct: $VaultSubscriptionId" -ForegroundColor Gray
        Write-Host "  4. You have appropriate permissions on the vault" -ForegroundColor Gray
        return
    }
    
    # Set vault context
    Write-Host "`n📊 Setting vault context..." -ForegroundColor Cyan
    Set-AzRecoveryServicesAsrVaultContext -Vault $vault | Out-Null
    Write-Host "✓ Vault context set" -ForegroundColor Green
    
    # Get replication fabrics
    Write-Host "`n📊 Retrieving replication fabrics..." -ForegroundColor Cyan
    $fabrics = Get-AzRecoveryServicesAsrFabric -ErrorAction SilentlyContinue
    
    if (-not $fabrics -or $fabrics.Count -eq 0) {
        Write-Host "⚠️  No replication fabrics found in vault" -ForegroundColor Yellow
        return
    }
    
    Write-Host "✓ Found $($fabrics.Count) fabric(s)" -ForegroundColor Green
    
    # Collect all replicated items (Azure-to-Azure only)
    $allReplicatedItems = @()
    $skippedNonA2AItems = 0
    
    foreach ($fabric in $fabrics) {
        Write-Host "  Processing fabric: $($fabric.FriendlyName)" -ForegroundColor Gray
        
        $containers = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric -ErrorAction SilentlyContinue
        
        if (-not $containers) {
            Write-Host "    No protection containers found" -ForegroundColor Gray
            continue
        }
        
        foreach ($container in $containers) {
            Write-Host "    Container: $($container.FriendlyName)" -ForegroundColor Gray
            
            $replicatedItems = Get-AzRecoveryServicesAsrReplicationProtectedItem `
                -ProtectionContainer $container `
                -ErrorAction SilentlyContinue
            
            if ($replicatedItems) {
                foreach ($item in $replicatedItems) {
                    # Check if this is Azure-to-Azure replication
                    $providerType = $item.ProviderSpecificDetails.GetType().Name
                    
                    if ($providerType -like "*A2A*" -or $providerType -eq "ASRAzureToAzureSpecificRPIDetails") {
                        if (-not $MachineName -or $item.FriendlyName -eq $MachineName) {
                            $allReplicatedItems += [PSCustomObject]@{
                                Item = $item
                                Fabric = $fabric
                                Container = $container
                            }
                        }
                    }
                    else {
                        $skippedNonA2AItems++
                    }
                }
            }
        }
    }
    
    if ($skippedNonA2AItems -gt 0) {
        Write-Host "`n⚠️  Skipped $skippedNonA2AItems non-Azure-to-Azure item(s)" -ForegroundColor Yellow
        Write-Host "   This script only supports Azure-to-Azure (A2A) replication" -ForegroundColor Gray
    }
    
    if ($allReplicatedItems.Count -eq 0) {
        if ($MachineName) {
            Write-Host "`n❌ No Azure-to-Azure replicated machine found with name: $MachineName" -ForegroundColor Red
        }
        else {
            Write-Host "`n⚠️  No Azure-to-Azure replicated items found in vault" -ForegroundColor Yellow
        }
        return
    }
    
    Write-Host "`n✓ Found $($allReplicatedItems.Count) Azure-to-Azure replicated item(s) to process" -ForegroundColor Green
    
    # Calculate totals
    $totalDisksToRemove = 0
    $totalSizeToFree = 0
    $totalMonthlyCostSavings = 0
    $totalCacheStorageGB = 0
    $ASRProtectedInstanceCost = 25.00  # Per instance per month
    
    foreach ($replicatedItem in $allReplicatedItems) {
        $item = $replicatedItem.Item
        $diskInfo = Get-ASRDiskInformation -ReplicatedItem $item
        
        $machineMonthlyCost = $diskInfo.TotalMonthlyCost + $ASRProtectedInstanceCost
        
        $totalDisksToRemove += $diskInfo.DiskCount
        $totalSizeToFree += $diskInfo.TotalSizeGB
        $totalMonthlyCostSavings += $machineMonthlyCost
        $totalCacheStorageGB += $diskInfo.TotalCacheStorageGB
    }
    
    # Display summary
    $totalASRInstanceCost = $allReplicatedItems.Count * $ASRProtectedInstanceCost
    
    Write-Host "`n📊 Summary:" -ForegroundColor Cyan
    Write-Host "  Total machines: $($allReplicatedItems.Count)" -ForegroundColor White
    Write-Host "  Total disks: $totalDisksToRemove" -ForegroundColor White
    Write-Host "  Total disk size: $([math]::Round($totalSizeToFree, 2)) GB" -ForegroundColor White
    Write-Host "  Total cache storage: $([math]::Round($totalCacheStorageGB, 2)) GB" -ForegroundColor White
    Write-Host ""
    Write-Host "💰 Cost Breakdown:" -ForegroundColor Cyan
    Write-Host "  ASR Protected Instances: `$$([math]::Round($totalASRInstanceCost, 2))/month" -ForegroundColor Yellow
    Write-Host "  Disk & Cache Storage: `$$([math]::Round($totalMonthlyCostSavings - $totalASRInstanceCost, 2))/month" -ForegroundColor Yellow
    Write-Host "  ═══════════════════════════════════════" -ForegroundColor Gray
    Write-Host "  Total Monthly Savings: `$$([math]::Round($totalMonthlyCostSavings, 2))" -ForegroundColor Green
    Write-Host "  Annual Savings: `$$([math]::Round($totalMonthlyCostSavings * 12, 2))" -ForegroundColor Green
    
    # Confirmation
    if (-not $WhatIf) {
        Write-Host "`n⚠️  WARNING: This will stop replication and delete ASR replica disks!" -ForegroundColor Yellow
        Write-Host "   - Azure-to-Azure replication will be stopped" -ForegroundColor Gray
        Write-Host "   - ASR replica/cache managed disks will be deleted" -ForegroundColor Gray
        Write-Host "   - Protection configuration will be removed" -ForegroundColor Gray
        Write-Host "   - Source VMs will NOT be affected" -ForegroundColor Gray
        Write-Host "   - This action cannot be easily undone" -ForegroundColor Gray
        
        $confirmation = Read-Host "`nDo you want to proceed? Type 'yes' to continue"
        if ($confirmation -ne 'yes') {
            Write-Host "❌ Operation cancelled by user." -ForegroundColor Yellow
            return
        }
    }
    
    # Process each replicated item
    Write-Host "`n📊 Processing replication items..." -ForegroundColor Cyan
    $results = @()
    $progressCount = 0
    
    foreach ($replicatedItem in $allReplicatedItems) {
        $progressCount++
        $item = $replicatedItem.Item
        $container = $replicatedItem.Container
        
        Write-Host "`n[$progressCount/$($allReplicatedItems.Count)] Processing: $($item.FriendlyName)..." -ForegroundColor Cyan
        
        # Capture disk information before removal
        $diskInfo = Get-ASRDiskInformation -ReplicatedItem $item
        $providerType = Get-ReplicationProviderType -ProviderSpecificDetails $item.ProviderSpecificDetails
        $machineMonthlyCost = $diskInfo.TotalMonthlyCost + $ASRProtectedInstanceCost
        
        try {
            if (-not $WhatIf) {
                # Stop replication
                Write-Host "  Stopping ASR replication..." -ForegroundColor Gray
                
                Remove-AzRecoveryServicesAsrReplicationProtectedItem `
                    -InputObject $item `
                    -Force `
                    -ErrorAction Stop | Out-Null
                
                Write-Host "  ✓ Successfully stopped replication" -ForegroundColor Green
                $status = "Success"
                $message = "ASR replication stopped and replica disks deleted successfully"
            }
            else {
                Write-Host "  [WhatIf] Would stop replication" -ForegroundColor Yellow
                $status = "WhatIf"
                $message = "Simulation - no changes made"
            }
            
            # Record result
            $results += [PSCustomObject]@{
                SubscriptionId = $VaultSubscriptionId
                SubscriptionName = $subName
                VaultName = $vault.Name
                VaultResourceGroup = $vault.ResourceGroupName
                VaultLocation = $vault.Location
                MachineName = $item.FriendlyName
                ReplicationHealth = $item.ReplicationHealth
                ProtectionState = $item.ProtectionState
                ProtectionStateDescription = $item.ProtectionStateDescription
                ReplicationProvider = $providerType
                FabricName = $replicatedItem.Fabric.FriendlyName
                ContainerName = $container.FriendlyName
                DiskCount = $diskInfo.DiskCount
                TotalDiskSizeGB = $diskInfo.TotalSizeGB
                CacheStorageGB = $diskInfo.TotalCacheStorageGB
                DiskDetails = ($diskInfo.DiskDetails -join "; ")
                MonthlyCostSavings = [math]::Round($machineMonthlyCost, 2)
                AnnualCostSavings = [math]::Round($machineMonthlyCost * 12, 2)
                ASRInstanceCost = $ASRProtectedInstanceCost
                DiskStorageCost = [math]::Round($diskInfo.TotalMonthlyCost, 2)
                LastRpoCalculatedTime = $item.LastRpoCalculatedTime
                RpoInSeconds = $item.RpoInSeconds
                Status = $status
                Message = $message
                Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        }
        catch {
            Write-Host "  ❌ Failed to stop replication" -ForegroundColor Red
            Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
            
            $results += [PSCustomObject]@{
                SubscriptionId = $VaultSubscriptionId
                SubscriptionName = $subName
                VaultName = $vault.Name
                VaultResourceGroup = $vault.ResourceGroupName
                VaultLocation = $vault.Location
                MachineName = $item.FriendlyName
                ReplicationHealth = $item.ReplicationHealth
                ProtectionState = $item.ProtectionState
                ProtectionStateDescription = $item.ProtectionStateDescription
                ReplicationProvider = $providerType
                FabricName = $replicatedItem.Fabric.FriendlyName
                ContainerName = $container.FriendlyName
                DiskCount = $diskInfo.DiskCount
                TotalDiskSizeGB = $diskInfo.TotalSizeGB
                CacheStorageGB = $diskInfo.TotalCacheStorageGB
                DiskDetails = ($diskInfo.DiskDetails -join "; ")
                MonthlyCostSavings = 0
                AnnualCostSavings = 0
                ASRInstanceCost = 0
                DiskStorageCost = 0
                LastRpoCalculatedTime = $item.LastRpoCalculatedTime
                RpoInSeconds = $item.RpoInSeconds
                Status = "Failed"
                Message = $_.Exception.Message
                Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        }
    }
    
    # Export results to CSV
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $outputFile = Join-Path $OutputPath "Stop_ASR_A2A_Replication_Results_$timestamp.csv"
    $results | Export-Csv -Path $outputFile -NoTypeInformation
    
    # Calculate summary metrics
    $successResults = $results | Where-Object { $_.Status -eq "Success" }
    $failedResults = $results | Where-Object { $_.Status -eq "Failed" }
    $whatIfResults = $results | Where-Object { $_.Status -eq "WhatIf" }
    
    $successCount = $successResults.Count
    $failedCount = $failedResults.Count
    $whatIfCount = $whatIfResults.Count
    
    # Display final summary
    Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                         SUMMARY                                ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    
    if ($WhatIf) {
        Write-Host "📊 Simulation Results (WhatIf Mode):" -ForegroundColor Yellow
        Write-Host "  Items processed: $whatIfCount" -ForegroundColor White
        Write-Host "  Estimated monthly savings: `$$([math]::Round($totalMonthlyCostSavings, 2))" -ForegroundColor Green
        Write-Host "`n✓ No actual changes were made" -ForegroundColor Green
    }
    else {
        Write-Host "📊 Processing Results:" -ForegroundColor Cyan
        Write-Host "  Total processed: $($results.Count)" -ForegroundColor White
        Write-Host "  Successfully stopped: $successCount" -ForegroundColor Green
        Write-Host "  Failed: $failedCount" -ForegroundColor $(if ($failedCount -gt 0) { "Red" } else { "White" })
        
        if ($successCount -gt 0) {
            $actualSavings = ($successResults | Measure-Object -Property MonthlyCostSavings -Sum).Sum
            Write-Host "`n💰 Achieved monthly savings: `$$([math]::Round($actualSavings, 2))" -ForegroundColor Green
            Write-Host "   Annual savings: `$$([math]::Round($actualSavings * 12, 2))" -ForegroundColor Green
        }
    }
    
    Write-Host "`n✓ Results exported to: $outputFile" -ForegroundColor Green
}
catch {
    Write-Host "`n❌ Error occurred: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
}