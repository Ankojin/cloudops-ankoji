<#
.SYNOPSIS
    Exports Azure Migrate ASR (replication) disk information to CSV
.DESCRIPTION
    This script retrieves all replicating machines and their ASR managed disks information
    from Azure Site Recovery vaults using manually provided vault details.
    Does NOT stop replication or delete any disks.
.PARAMETER ASRVaultSubscriptionId
    Subscription ID where ASR Recovery Services Vault is located
.PARAMETER ASRVaultResourceGroup
    Resource Group containing the ASR Recovery Services Vault
.PARAMETER ASRVaultName
    Name of the ASR Recovery Services Vault
.PARAMETER TenantId
    (Optional) Azure Tenant ID for authentication
.PARAMETER OutputPath
    (Optional) Path to save the CSV file. Default is current directory.
.PARAMETER ExportSummary
    (Optional) Export summary. Default is $true
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ASRVaultSubscriptionId,
    
    [Parameter(Mandatory=$true)]
    [string]$ASRVaultResourceGroup,
    
    [Parameter(Mandatory=$true)]
    [string]$ASRVaultName,
    
    [Parameter(Mandatory=$false)]
    [string]$TenantId,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".",
    
    [Parameter(Mandatory=$false)]
    [bool]$ExportSummary = $true
)

$ErrorActionPreference = "Stop"

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

function Get-ASRDiskDetailsFromVault {
    param(
        [Parameter(Mandatory=$true)]
        $ReplicatedItem,
        [Parameter(Mandatory=$true)]
        [string]$VaultName,
        [Parameter(Mandatory=$true)]
        [string]$VaultResourceGroup,
        [Parameter(Mandatory=$true)]
        [string]$VaultLocation,
        [Parameter(Mandatory=$true)]
        [string]$SubscriptionId,
        [Parameter(Mandatory=$true)]
        [string]$SubscriptionName,
        [Parameter(Mandatory=$true)]
        [string]$FabricName,
        [Parameter(Mandatory=$true)]
        [string]$ContainerName
    )
    
    $diskDetails = @()
    $item = $ReplicatedItem
    
    # Check for ProtectedDisks (VMware/Physical to Azure)
    if ($item.ProviderSpecificDetails.ProtectedDisks) {
        foreach ($disk in $item.ProviderSpecificDetails.ProtectedDisks) {
            $diskSizeGB = if ($disk.DiskCapacityInBytes) { 
                [math]::Round($disk.DiskCapacityInBytes / 1GB, 2) 
            } else { 0 }
            
            # Extract subscription IDs from resource IDs
            $storageAccountSub = ""
            $seedDiskSub = ""
            $targetDiskSub = ""
            
            if ($disk.RecoveryAzureStorageAccountId -match '/subscriptions/([^/]+)/') {
                $storageAccountSub = $matches[1]
            }
            if ($disk.SeedManagedDiskId -match '/subscriptions/([^/]+)/') {
                $seedDiskSub = $matches[1]
            }
            if ($disk.RecoveryTargetDiskId -match '/subscriptions/([^/]+)/') {
                $targetDiskSub = $matches[1]
            }
            
            $diskDetails += [PSCustomObject]@{
                SubscriptionId = $SubscriptionId
                SubscriptionName = $SubscriptionName
                VaultName = $VaultName
                VaultResourceGroup = $VaultResourceGroup
                VaultLocation = $VaultLocation
                FabricName = $FabricName
                ContainerName = $ContainerName
                MachineName = $item.FriendlyName
                ReplicationHealth = $item.ReplicationHealth
                ProtectionState = $item.ProtectionState
                ProtectionStateDescription = $item.ProtectionStateDescription
                ReplicationProvider = $item.ProviderSpecificDetails.GetType().Name
                StorageAccountSubId = $storageAccountSub
                SeedDiskSubId = $seedDiskSub
                TargetDiskSubId = $targetDiskSub
                DiskName = $disk.DiskName
                DiskId = $disk.DiskId
                DiskUri = $disk.DiskUri
                IsDiskEncrypted = $disk.IsDiskEncrypted
                IsDiskKeyEncrypted = $disk.IsDiskKeyEncrypted
                DiskSizeGB = $diskSizeGB
                RecoveryAzureStorageAccountId = $disk.RecoveryAzureStorageAccountId
                SeedManagedDiskId = $disk.SeedManagedDiskId
                RecoveryTargetDiskId = $disk.RecoveryTargetDiskId
                RecoveryDiskAccountType = $disk.RecoveryDiskAccountType
                LastRpoCalculatedTime = $item.LastRpoCalculatedTime
                RpoInSeconds = $item.RpoInSeconds
            }
        }
    }
    
    # Check for A2AProtectedManagedDisks (Azure to Azure)
    if ($item.ProviderSpecificDetails.A2AProtectedManagedDisks) {
        foreach ($disk in $item.ProviderSpecificDetails.A2AProtectedManagedDisks) {
            $diskSizeGB = if ($disk.DiskCapacityInBytes) { 
                [math]::Round($disk.DiskCapacityInBytes / 1GB, 2) 
            } else { 0 }
            
            # Extract subscription IDs
            $primaryDiskSub = ""
            $recoveryDiskSub = ""
            $replicaDiskSub = ""
            
            if ($disk.PrimaryDiskAzureStorageAccountId -match '/subscriptions/([^/]+)/') {
                $primaryDiskSub = $matches[1]
            }
            if ($disk.RecoveryTargetDiskId -match '/subscriptions/([^/]+)/') {
                $recoveryDiskSub = $matches[1]
            }
            if ($disk.RecoveryReplicaDiskId -match '/subscriptions/([^/]+)/') {
                $replicaDiskSub = $matches[1]
            }
            
            $diskDetails += [PSCustomObject]@{
                SubscriptionId = $SubscriptionId
                SubscriptionName = $SubscriptionName
                VaultName = $VaultName
                VaultResourceGroup = $VaultResourceGroup
                VaultLocation = $VaultLocation
                FabricName = $FabricName
                ContainerName = $ContainerName
                MachineName = $item.FriendlyName
                ReplicationHealth = $item.ReplicationHealth
                ProtectionState = $item.ProtectionState
                ProtectionStateDescription = $item.ProtectionStateDescription
                ReplicationProvider = $item.ProviderSpecificDetails.GetType().Name
                StorageAccountSubId = $primaryDiskSub
                SeedDiskSubId = $replicaDiskSub
                TargetDiskSubId = $recoveryDiskSub
                DiskName = $disk.DiskName
                DiskId = $disk.DiskId
                DiskUri = ""
                IsDiskEncrypted = $disk.IsDiskEncrypted
                IsDiskKeyEncrypted = $false
                DiskSizeGB = $diskSizeGB
                RecoveryAzureStorageAccountId = $disk.PrimaryDiskAzureStorageAccountId
                SeedManagedDiskId = $disk.RecoveryReplicaDiskId
                RecoveryTargetDiskId = $disk.RecoveryTargetDiskId
                RecoveryDiskAccountType = $disk.RecoveryReplicaDiskAccountType
                LastRpoCalculatedTime = $item.LastRpoCalculatedTime
                RpoInSeconds = $item.RpoInSeconds
            }
        }
    }
    
    # Check for ProtectedManagedDisks (HyperV to Azure)
    if ($item.ProviderSpecificDetails.ProtectedManagedDisks) {
        foreach ($disk in $item.ProviderSpecificDetails.ProtectedManagedDisks) {
            $diskSizeGB = if ($disk.DiskCapacityInBytes) { 
                [math]::Round($disk.DiskCapacityInBytes / 1GB, 2) 
            } else { 0 }
            
            $diskDetails += [PSCustomObject]@{
                SubscriptionId = $SubscriptionId
                SubscriptionName = $SubscriptionName
                VaultName = $VaultName
                VaultResourceGroup = $VaultResourceGroup
                VaultLocation = $VaultLocation
                FabricName = $FabricName
                ContainerName = $ContainerName
                MachineName = $item.FriendlyName
                ReplicationHealth = $item.ReplicationHealth
                ProtectionState = $item.ProtectionState
                ProtectionStateDescription = $item.ProtectionStateDescription
                ReplicationProvider = $item.ProviderSpecificDetails.GetType().Name
                StorageAccountSubId = ""
                SeedDiskSubId = ""
                TargetDiskSubId = ""
                DiskName = $disk.DiskName
                DiskId = $disk.DiskId
                DiskUri = ""
                IsDiskEncrypted = $false
                IsDiskKeyEncrypted = $false
                DiskSizeGB = $diskSizeGB
                RecoveryAzureStorageAccountId = ""
                SeedManagedDiskId = ""
                RecoveryTargetDiskId = ""
                RecoveryDiskAccountType = $disk.RecoveryDiskStorageAccountType
                LastRpoCalculatedTime = $item.LastRpoCalculatedTime
                RpoInSeconds = $item.RpoInSeconds
            }
        }
    }
    
    return $diskDetails
}

try {
    Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║     Azure Site Recovery Disk Export (Manual Vault Input)      ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    
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
        Write-Host "  Current subscription: $($currentContext.Subscription.Name)" -ForegroundColor Gray
    }
    catch {
        Write-Host "❌ Not connected to Azure. Please run 'Connect-AzAccount' first." -ForegroundColor Red
        return
    }
    
    $allASRDiskDetails = @()
    
    # Set context to ASR vault subscription
    Write-Host "`n📊 Setting context to ASR vault subscription..." -ForegroundColor Cyan
    $context = Set-AzureContext -SubscriptionId $ASRVaultSubscriptionId -TenantId $TenantId
    if (-not $context) {
        Write-Host "❌ Failed to set context to subscription: $ASRVaultSubscriptionId" -ForegroundColor Red
        return
    }
    
    $subName = $context.Subscription.Name
    Write-Host "✓ Context set to: $subName" -ForegroundColor Green
    
    # Get the ASR vault
    Write-Host "`n📊 Retrieving ASR Recovery Services Vault..." -ForegroundColor Cyan
    Write-Host "  Vault Name: $ASRVaultName" -ForegroundColor Gray
    Write-Host "  Resource Group: $ASRVaultResourceGroup" -ForegroundColor Gray
    
    try {
        $vault = Get-AzRecoveryServicesVault `
            -ResourceGroupName $ASRVaultResourceGroup `
            -Name $ASRVaultName `
            -ErrorAction Stop
        
        Write-Host "✓ Found vault: $($vault.Name) in $($vault.Location)" -ForegroundColor Green
    }
    catch {
        Write-Host "❌ Failed to retrieve vault: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "`n💡 Please verify:" -ForegroundColor Yellow
        Write-Host "  1. Vault name is correct: $ASRVaultName" -ForegroundColor Gray
        Write-Host "  2. Resource group is correct: $ASRVaultResourceGroup" -ForegroundColor Gray
        Write-Host "  3. Subscription is correct: $ASRVaultSubscriptionId" -ForegroundColor Gray
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
    
    $totalMachines = 0
    $totalDisks = 0
    
    foreach ($fabric in $fabrics) {
        Write-Host "`n  Processing fabric: $($fabric.FriendlyName)" -ForegroundColor Cyan
        
        # Get protection containers
        $containers = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric -ErrorAction SilentlyContinue
        
        if (-not $containers) {
            Write-Host "    No protection containers found" -ForegroundColor Gray
            continue
        }
        
        Write-Host "    Found $($containers.Count) container(s)" -ForegroundColor Gray
        
        foreach ($container in $containers) {
            Write-Host "      Container: $($container.FriendlyName)" -ForegroundColor Gray
            
            # Get replicated items
            $replicatedItems = Get-AzRecoveryServicesAsrReplicationProtectedItem `
                -ProtectionContainer $container `
                -ErrorAction SilentlyContinue
            
            if (-not $replicatedItems) {
                Write-Host "        No replicated items found" -ForegroundColor Gray
                continue
            }
            
            Write-Host "        Found $($replicatedItems.Count) replicated item(s)" -ForegroundColor Green
            
            foreach ($item in $replicatedItems) {
                $diskDetails = Get-ASRDiskDetailsFromVault `
                    -ReplicatedItem $item `
                    -VaultName $vault.Name `
                    -VaultResourceGroup $vault.ResourceGroupName `
                    -VaultLocation $vault.Location `
                    -SubscriptionId $ASRVaultSubscriptionId `
                    -SubscriptionName $subName `
                    -FabricName $fabric.FriendlyName `
                    -ContainerName $container.FriendlyName
                
                $allASRDiskDetails += $diskDetails
                $totalMachines++
                $totalDisks += $diskDetails.Count
                
                if ($diskDetails.Count -gt 0) {
                    $diskSize = ($diskDetails | Measure-Object -Property DiskSizeGB -Sum).Sum
                    Write-Host "          • $($item.FriendlyName): $($diskDetails.Count) disk(s), $([math]::Round($diskSize, 2)) GB" -ForegroundColor White
                }
                else {
                    Write-Host "          • $($item.FriendlyName): No disk details found" -ForegroundColor Yellow
                }
            }
        }
    }
    
    # Export results
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    
    if ($allASRDiskDetails.Count -gt 0) {
        # Export detailed disk information
        $detailsFile = Join-Path $OutputPath "ASR_Disks_Details_$($ASRVaultName)_$timestamp.csv"
        $allASRDiskDetails | Export-Csv -Path $detailsFile -NoTypeInformation
        Write-Host "`n✓ ASR disk details exported to: $detailsFile" -ForegroundColor Green
        
        # Create and export summary
        if ($ExportSummary) {
            $totalDiskSize = ($allASRDiskDetails | Measure-Object -Property DiskSizeGB -Sum).Sum
            $monthlyCostPerGB = 0.05
            $estimatedMonthlyCost = [math]::Round($totalDiskSize * $monthlyCostPerGB, 2)
            
            $summaryData = [PSCustomObject]@{
                VaultName = $vault.Name
                VaultResourceGroup = $vault.ResourceGroupName
                VaultLocation = $vault.Location
                SubscriptionId = $ASRVaultSubscriptionId
                SubscriptionName = $subName
                ReplicatingMachines = $totalMachines
                TotalASRDisks = $totalDisks
                TotalDiskSizeGB = [math]::Round($totalDiskSize, 2)
                EstimatedMonthlyCostUSD = $estimatedMonthlyCost
            }
            
            $summaryFile = Join-Path $OutputPath "ASR_Disks_Summary_$($ASRVaultName)_$timestamp.csv"
            $summaryData | Export-Csv -Path $summaryFile -NoTypeInformation
            Write-Host "✓ Summary exported to: $summaryFile" -ForegroundColor Green
        }
        
        # Display summary
        Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║                    EXPORT SUMMARY                              ║" -ForegroundColor Cyan
        Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
        
        $totalSize = ($allASRDiskDetails | Measure-Object -Property DiskSizeGB -Sum).Sum
        $monthlyCostPerGB = 0.05
        $totalCost = [math]::Round($totalSize * $monthlyCostPerGB, 2)
        
        Write-Host "Vault: $($vault.Name)" -ForegroundColor White
        Write-Host "Total replicating machines: $totalMachines" -ForegroundColor White
        Write-Host "Total ASR disks: $totalDisks" -ForegroundColor White
        Write-Host "Total disk size: $([math]::Round($totalSize, 2)) GB" -ForegroundColor White
        Write-Host "Estimated monthly cost: ~`$$totalCost USD" -ForegroundColor Yellow
        
        # Show replication provider breakdown
        Write-Host "`n📋 Breakdown by replication provider:" -ForegroundColor Cyan
        $allASRDiskDetails | Group-Object ReplicationProvider | ForEach-Object {
            $providerDisks = $_.Count
            $providerSize = ($_.Group | Measure-Object -Property DiskSizeGB -Sum).Sum
            Write-Host "  • $($_.Name): $providerDisks disk(s), $([math]::Round($providerSize, 2)) GB" -ForegroundColor White
        }
        
        # Show machine breakdown
        Write-Host "`n📋 Breakdown by machine:" -ForegroundColor Cyan
        $allASRDiskDetails | Group-Object MachineName | ForEach-Object {
            $machineDisks = $_.Count
            $machineSize = ($_.Group | Measure-Object -Property DiskSizeGB -Sum).Sum
            $machineHealth = ($_.Group | Select-Object -First 1).ReplicationHealth
            Write-Host "  • $($_.Name): $machineDisks disk(s), $([math]::Round($machineSize, 2)) GB [$machineHealth]" -ForegroundColor White
        }
    }
    else {
        Write-Host "`n⚠️  No ASR disk details found" -ForegroundColor Yellow
        Write-Host "`n💡 Possible reasons:" -ForegroundColor Cyan
        Write-Host "  1. No machines are currently being replicated" -ForegroundColor Gray
        Write-Host "  2. Replication has not been configured yet" -ForegroundColor Gray
        Write-Host "  3. The vault is empty or newly created" -ForegroundColor Gray
    }
}
catch {
    Write-Host "`n❌ Error occurred: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
}