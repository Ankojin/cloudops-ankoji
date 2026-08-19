<#
.SYNOPSIS
    Disables Azure Backup protection for ALL SQL Server databases in Azure VM
.DESCRIPTION
    This script disables backup protection for all databases on SQL Server instance: d1etl2019v2
    Server: d2dhbdbsqdwv1.albtests.com
    VM: dadhbdbsqdwv1
.NOTES
    Author: Cloud Operations Team
    Date: November 2, 2025
    WARNING: This will disable backup for ALL databases on the server
#>

# ============================================================================
# HARDCODED PARAMETERS - UPDATE BEFORE EXECUTION
# ============================================================================

$SubscriptionId = "e48414cd-f96d-4414-ae9e-da7fec844f77"
$VaultName = "bab-sit-backup-vault-swec-01"
$VaultResourceGroup = "bab-sit-backup-rsv-swec-rg-01"
$VMName = "DADHBDBSQIWV1"
$ServerName = "D2DHBDBSQIWV1.albtests.com"
$SQLInstanceName = "MSSQLSERVER"  # SQL Server instance name

# Set to $true to permanently delete recovery points, $false to retain (recommended)
$RemoveRecoveryPoints = $false

# Set to $false to skip confirmation prompt (use with caution)
$ConfirmBeforeExecute = $true

# Exclude system databases from disable operation
$ExcludeSystemDatabases = $true
$SystemDatabases = @("master", "model", "msdb")

# ============================================================================
# SCRIPT EXECUTION - DO NOT MODIFY BELOW THIS LINE
# ============================================================================

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "SQL Server Backup Bulk Disable Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Set subscription context
Write-Host "[1/5] Setting Azure subscription context..." -ForegroundColor Cyan
$context = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
Write-Host "      ✓ Connected to subscription: $($context.Subscription.Name)" -ForegroundColor Green

# Get Recovery Services Vault
Write-Host "[2/5] Connecting to Recovery Services vault..." -ForegroundColor Cyan
$vault = Get-AzRecoveryServicesVault -Name $VaultName -ResourceGroupName $VaultResourceGroup -ErrorAction Stop
Set-AzRecoveryServicesVaultContext -Vault $vault -ErrorAction Stop
Write-Host "      ✓ Connected to vault: $VaultName" -ForegroundColor Green

# Retrieve backup containers
Write-Host "[3/5] Retrieving backup containers..." -ForegroundColor Cyan
$containers = Get-AzRecoveryServicesBackupContainer `
    -ContainerType "AzureVMAppContainer" `
    -BackupManagementType "AzureWorkload" `
    -ErrorAction Stop

$containers = $containers | Where-Object { $_.FriendlyName -like "*$VMName*" }
Write-Host "      ✓ Found container for VM: $VMName" -ForegroundColor Green

# Retrieve all protected databases
Write-Host "[4/5] Locating protected SQL Server databases..." -ForegroundColor Cyan
$databases = $containers | ForEach-Object {
    Get-AzRecoveryServicesBackupItem -Container $_ -WorkloadType "MSSQL" -ErrorAction Stop
}

# Filter for the specific SQL instance and exclude system DBs if configured
$targetDatabases = $databases | Where-Object { 
    $_.Name -like "SQLDataBase;$SQLInstanceName;*" -and
    $_.ServerName -eq $ServerName -and
    $_.ProtectionState -eq "Protected"
}

if ($ExcludeSystemDatabases) {
    $targetDatabases = $targetDatabases | Where-Object {
        $dbName = ($_.Name -split ';')[2]
        $dbName -notin $SystemDatabases
    }
}

if (-not $targetDatabases) {
    Write-Host "      No protected databases found matching criteria." -ForegroundColor Yellow
    exit 0
}

Write-Host "      ✓ Found $($targetDatabases.Count) database(s) to disable" -ForegroundColor Green
Write-Host ""

# Display databases to be disabled
Write-Host "Databases that will have backup protection disabled:" -ForegroundColor Yellow
$targetDatabases | Select-Object @{n="Database";e={($_.Name -split ';')[2]}}, 
                                 ProtectionState, 
                                 @{n="LastBackup";e={$_.LastBackupTime}} | 
    Format-Table -AutoSize

# Confirmation
if ($ConfirmBeforeExecute) {
    Write-Host "⚠️  WARNING: You are about to disable backup protection for $($targetDatabases.Count) database(s)!" -ForegroundColor Red
    
    if ($RemoveRecoveryPoints) {
        Write-Host "⚠️  CRITICAL: All recovery points will be PERMANENTLY DELETED!" -ForegroundColor Red
    } else {
        Write-Host "ℹ️  Recovery points will be retained with soft-delete protection (14 days)" -ForegroundColor Yellow
    }
    
    Write-Host ""
    $confirmation = Read-Host "Type 'DISABLE-ALL' (case-sensitive) to proceed or any other key to cancel"
    
    if ($confirmation -ne 'DISABLE-ALL') {
        Write-Host "Operation cancelled by user." -ForegroundColor Yellow
        exit 0
    }
}

# Disable backup protection for each database
Write-Host ""
Write-Host "[5/5] Disabling backup protection..." -ForegroundColor Cyan
$successCount = 0
$failureCount = 0
$results = @()

foreach ($db in $targetDatabases) {
    $dbName = ($db.Name -split ';')[2]
    
    try {
        Write-Host "      Processing: $dbName..." -ForegroundColor Gray
        
        Disable-AzRecoveryServicesBackupProtection `
            -Item $db `
            -RemoveRecoveryPoints:$RemoveRecoveryPoints `
            -Force `
            -ErrorAction Stop
        
        $successCount++
        $results += [PSCustomObject]@{
            Database = $dbName
            Status = "Success"
            Message = "Backup protection disabled"
        }
        
        Write-Host "      ✓ $dbName - Disabled successfully" -ForegroundColor Green
        
    } catch {
        $failureCount++
        $results += [PSCustomObject]@{
            Database = $dbName
            Status = "Failed"
            Message = $_.Exception.Message
        }
        
        Write-Host "      ✗ $dbName - Failed: $_" -ForegroundColor Red
    }
}

# Summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Operation Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total Databases Processed: $($targetDatabases.Count)" -ForegroundColor White
Write-Host "Successful: $successCount" -ForegroundColor Green
Write-Host "Failed: $failureCount" -ForegroundColor Red
Write-Host ""

# Display detailed results
Write-Host "Detailed Results:" -ForegroundColor White
$results | Format-Table -AutoSize

Write-Host ""
Write-Host "Script completed at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host "Executed by: $env:USERNAME on $env:COMPUTERNAME" -ForegroundColor Gray