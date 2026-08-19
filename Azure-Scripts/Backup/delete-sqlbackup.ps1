#------------------------------------------------------------
# Connect to Azure
#------------------------------------------------------------
#Connect-AzAccount

# Uncomment if you need to select a subscription
# Set-AzContext -Subscription "<Subscription Name or ID>"
$SubscriptionId = "e48414cd-f96d-4414-ae9e-da7fec844f77"
Set-AzContext -SubscriptionId $SubscriptionId

#------------------------------------------------------------
# Variables
#------------------------------------------------------------
$VaultName      = "bab-sit-backup-vault-swec-01"
$ResourceGroup  = "bab-sit-backup-rsv-swec-rg-01"
$ContainerName  = "DADHBDBSQIWV1"

#------------------------------------------------------------
# Set Vault Context
#------------------------------------------------------------
$vault = Get-AzRecoveryServicesVault `
    -Name $VaultName `
    -ResourceGroupName $ResourceGroup

Set-AzRecoveryServicesVaultContext -Vault $vault

Write-Host "Connected to vault: $VaultName" -ForegroundColor Green

#------------------------------------------------------------
# Disable Soft Delete temporarily
# Soft delete retains deleted data for 14 days — must be OFF for permanent deletion.
# It will be re-enabled automatically at the end of this script.
#------------------------------------------------------------
Write-Host ""
Write-Host "Checking soft delete state on vault: $VaultName ..." -ForegroundColor Cyan

$vaultProps        = Get-AzRecoveryServicesVaultProperty -VaultId $vault.ID
$softDeleteEnabled = $vaultProps.SoftDeleteFeatureState -eq "Enabled"

#------------------------------------------------------------
# Diagnostics — show all security properties of the vault
#------------------------------------------------------------
Write-Host ""
Write-Host "Vault Security Properties:" -ForegroundColor Cyan
Write-Host "  SoftDeleteFeatureState   : $($vaultProps.SoftDeleteFeatureState)"
Write-Host "  EnhancedSecurityState    : $($vaultProps.EnhancedSecurityState)"
Write-Host "  ImmutabilityState        : $($vaultProps.ImmutabilityState)"
Write-Host "  ResourceGuardOperationRequests : $($vaultProps.ResourceGuardOperationRequests -join ', ')"
Write-Host ""

# Enhanced Security ON — soft delete cannot be disabled via API/script at all.
# Must be disabled from the Azure Portal first.
if ($vaultProps.EnhancedSecurityState -eq "Enabled")
{
    Write-Host "BLOCK: Enhanced Security is ON for this vault." -ForegroundColor Red
    Write-Host "       Soft delete CANNOT be disabled via PowerShell or REST API while Enhanced Security is enabled." -ForegroundColor Red
    Write-Host ""
    Write-Host "To fix, go to Azure Portal:" -ForegroundColor Yellow
    Write-Host "  Vault -> Properties -> Security Settings -> Enhanced Soft Delete -> Disable" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "If that option is greyed out, Enhanced Security was auto-applied by Azure Policy and cannot be removed." -ForegroundColor Yellow
    Write-Host "In that case your options are:" -ForegroundColor Yellow
    Write-Host "  1. Wait $($vaultProps.SoftDeleteRetentionPeriodInDays) days — soft-deleted items will be permanently purged automatically." -ForegroundColor Yellow
    Write-Host "  2. Raise an Azure Support ticket to request forced purge." -ForegroundColor Yellow
    Write-Host ""

    $proceed = Read-Host "Continue anyway? Items already in soft-delete will NOT be purged immediately. Type YES to proceed"
    if ($proceed -ne "YES")
    {
        Write-Host "Aborted." -ForegroundColor Red
        exit
    }

    # Cannot disable — mark so re-enable step is skipped
    $softDeleteEnabled = $false
}
elseif (-not $softDeleteEnabled)
{
    Write-Host "Soft delete is already DISABLED. Continuing..." -ForegroundColor Green
}
else
{
    Write-Host "Soft delete is ENABLED. Attempting to disable..." -ForegroundColor Yellow

    try
    {
        Set-AzRecoveryServicesVaultProperty `
            -VaultId $vault.ID `
            -SoftDeleteFeatureState Disable `
            -ErrorAction Stop

        Write-Host "Soft delete DISABLED successfully." -ForegroundColor Yellow
    }
    catch
    {
        Write-Host ""
        Write-Host "ERROR: Could not disable soft delete." -ForegroundColor Red
        Write-Host "Reason: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "Common causes and fixes:" -ForegroundColor Yellow
        Write-Host "  1. MUA/Resource Guard    -> Request approval from the Resource Guard admin to allow this operation" -ForegroundColor Yellow
        Write-Host "  2. Vault Immutability    -> Cannot be unlocked once Locked; raise an Azure support ticket" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "With soft delete still ON, deleted items will be soft-deleted (retained 14 days) not permanently purged." -ForegroundColor Yellow

        $proceed = Read-Host "Continue anyway (items will be soft-deleted only, NOT purged)? Type YES to proceed or any key to abort"
        if ($proceed -ne "YES")
        {
            Write-Host "Aborted." -ForegroundColor Red
            exit
        }

        # Mark so re-enable step is skipped (we never disabled it)
        $softDeleteEnabled = $false
    }
}

#------------------------------------------------------------
# Get SQL Backup Container
#------------------------------------------------------------
$container = Get-AzRecoveryServicesBackupContainer `
    -ContainerType AzureVMAppContainer `
    -BackupManagementType AzureWorkload |
    Where-Object {
        $_.FriendlyName -eq $ContainerName
    }

if (!$container)
{
    Write-Host "Container not found: $ContainerName" -ForegroundColor Red
    exit
}

Write-Host "Container found:" -ForegroundColor Green
$container | Select FriendlyName, Name | Format-Table


#------------------------------------------------------------
# Get SQL Databases
#------------------------------------------------------------
Write-Host ""
Write-Host "Getting SQL backup items..." -ForegroundColor Cyan

$items = Get-AzRecoveryServicesBackupItem `
    -Container $container `
    -WorkloadType MSSQL


if (!$items)
{
    Write-Host "No SQL databases found." -ForegroundColor Yellow
    exit
}


Write-Host ""
Write-Host "SQL Backup Items — Summary by State:" -ForegroundColor Green

$items |
Group-Object ProtectionState, DeleteState |
Select-Object Count, Name |
Format-Table -AutoSize

Write-Host "Total items found: $($items.Count)" -ForegroundColor Cyan


#------------------------------------------------------------
# Select ALL items for deletion (entire container is being retired)
# Handles: Protected, ProtectionStopped, IRPending
# Skips:   ToBeDeleted — already soft-deleted, will auto-purge after retention period
#------------------------------------------------------------
$skippedItems = $items | Where-Object { $_.DeleteState -eq "ToBeDeleted" }
$deleteItems  = $items | Where-Object { $_.DeleteState -ne "ToBeDeleted" }

if ($skippedItems)
{
    Write-Host ""
    Write-Host "SKIPPING $($skippedItems.Count) item(s) already marked for deletion (ToBeDeleted) — they will be auto-purged:" -ForegroundColor DarkYellow
    $skippedItems |
    Group-Object ProtectionState, DeleteState |
    Select-Object Count, Name |
    Format-Table -AutoSize
}

if (!$deleteItems)
{
    Write-Host ""
    Write-Host "No actionable backup items found in container (all are already ToBeDeleted)." -ForegroundColor Yellow
    exit
}

Write-Host ""
Write-Host "$($deleteItems.Count) item(s) in container '$ContainerName' will be permanently deleted:" -ForegroundColor Red

$deleteItems |
Group-Object ProtectionState, DeleteState |
Select-Object Count, Name |
Format-Table -AutoSize

Write-Host "NOTE: Actively Protected items will have protection disabled before recovery points are removed." -ForegroundColor Yellow
Write-Host ""

$confirm = Read-Host "Type YES to permanently delete $($deleteItems.Count) backup items and unregister the container"

if ($confirm -ne "YES")
{
    Write-Host "Deletion cancelled."
    exit
}


#------------------------------------------------------------
# Step 1: Delete recovery points for each item
#------------------------------------------------------------
$allSucceeded = $true
$total        = $deleteItems.Count
$index        = 0
$failedItems  = @()

foreach ($item in $deleteItems)
{
    $index++
    $pct = [int](($index / $total) * 100)
    Write-Progress -Activity "Deleting backup items" `
                   -Status "[$index/$total] $($item.FriendlyName) [State: $($item.ProtectionState)]" `
                   -PercentComplete $pct

    try
    {
        Disable-AzRecoveryServicesBackupProtection `
            -Item $item `
            -RemoveRecoveryPoints `
            -Force `
            -ErrorAction Stop

        Write-Host "  [$index/$total] Deleted: $($item.FriendlyName)" -ForegroundColor Green
    }
    catch
    {
        Write-Host "  [$index/$total] FAILED : $($item.FriendlyName) — $($_.Exception.Message)" -ForegroundColor Red
        $failedItems  += $item.FriendlyName
        $allSucceeded  = $false
    }
}

Write-Progress -Activity "Deleting backup items" -Completed

if ($failedItems)
{
    Write-Host ""
    Write-Host "Failed items ($($failedItems.Count)):" -ForegroundColor Red
    $failedItems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}

#------------------------------------------------------------
# Step 2: Unregister the container to remove the SQL instance
#         from the vault entirely (only if all items succeeded)
#------------------------------------------------------------
if ($allSucceeded)
{
    Write-Host ""
    Write-Host "All recovery points deleted. Unregistering SQL container: $ContainerName ..." -ForegroundColor Cyan

    try
    {
        Unregister-AzRecoveryServicesBackupContainer `
            -Container $container `
            -Force `
            -ErrorAction Stop

        Write-Host "Container unregistered successfully. SQL instance removed from vault." -ForegroundColor Green
    }
    catch
    {
        Write-Host "Failed to unregister container: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Check that all backup items have been fully deleted before retrying." -ForegroundColor Yellow
    }
}
else
{
    Write-Host ""
    Write-Host "One or more items failed. Container unregistration skipped." -ForegroundColor Yellow
    Write-Host "Fix the errors above and re-run before attempting to unregister." -ForegroundColor Yellow
}

#------------------------------------------------------------
# Re-enable Soft Delete (only if this script disabled it)
#------------------------------------------------------------
if ($softDeleteEnabled)
{
    Write-Host ""
    Write-Host "Re-enabling soft delete on vault: $VaultName ..." -ForegroundColor Yellow

    try
    {
        Set-AzRecoveryServicesVaultProperty `
            -VaultId $vault.ID `
            -SoftDeleteFeatureState Enable

        Write-Host "Soft delete RE-ENABLED." -ForegroundColor Green
    }
    catch
    {
        Write-Host "WARNING: Failed to re-enable soft delete: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "ACTION REQUIRED: Manually re-enable soft delete on vault '$VaultName' in the Azure Portal." -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Completed." -ForegroundColor Green