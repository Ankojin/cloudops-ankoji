# --- Configuration ---
$ResourceGroupName = "DEV-DevOps-RG-01"
$VaultName = "Dev-DevOps-BakUp-Vault-01"
$SubscriptionId = "2a908090-d056-438c-bcf3-00ce359a72b5" # Optional, if not logged in to the correct context

# --- Target VMs (leave empty to disable ALL protected VMs) ---
# Add VM names exactly as they appear in Azure (case-insensitive match is used)
$TargetVMNames = @(
    "dtazrdevappdbwv01",
    "dtazrdevappdbwv02"
    # Add more VM names here...
)

# --- Authentication ---
# If not already logged in, uncomment the line below and run it manually
#Connect-AzAccount -SubscriptionId $SubscriptionId

# Select the subscription
Select-AzSubscription -SubscriptionId $SubscriptionId

# Get the Recovery Services Vault
$Vault = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroupName -Name $VaultName

if (-not $Vault) {
    Write-Error "Vault '$VaultName' not found in resource group '$ResourceGroupName'."
    exit
}

Write-Host "Found Vault: $($Vault.Name)"

# Set vault context so subsequent cmdlets target the correct vault
Set-AzRecoveryServicesVaultContext -Vault $Vault

# Get all backup containers (AzureVM workload; extend loop for other types if needed)
$Containers = Get-AzRecoveryServicesBackupContainer -ContainerType "AzureVM" -VaultId $Vault.ID

# Get all protected items across all containers
$ProtectedItems = foreach ($Container in $Containers) {
    Get-AzRecoveryServicesBackupItem -Container $Container -WorkloadType "AzureVM" -VaultId $Vault.ID
}

if (-not $ProtectedItems -or @($ProtectedItems).Count -eq 0) {
    Write-Host "No protected items found in this vault."
    exit
}

Write-Host "Found $(@($ProtectedItems).Count) protected items. Starting process..."

foreach ($Item in $ProtectedItems) {
    $ItemName = $Item.Name
    $ItemType = $Item.WorkloadType

    # Filter: skip if a target list is defined and this VM is not in it
    if ($TargetVMNames.Count -gt 0) {
        $VMNameFromItem = ($ItemName -split ";")[-1]  # Extract VM name from the item name format
        $isTarget = $TargetVMNames | Where-Object { $_ -ieq $VMNameFromItem }
        if (-not $isTarget) {
            Write-Host "  Skipping: ${VMNameFromItem} (not in target list)" -ForegroundColor DarkGray
            continue
        }
    }

    Write-Host "Processing: $ItemName ($ItemType)" -ForegroundColor Yellow

    try {
        # Stop protection AND delete all backup data in one operation
        Disable-AzRecoveryServicesBackupProtection -Item $Item -RemoveRecoveryPoints -Force -VaultId $Vault.ID

        Write-Host "  -> Backup protection disabled and data deleted for ${ItemName}." -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to process ${ItemName}: $_"
    }
}

Write-Host "Process completed."