<#
.SYNOPSIS
    Triggers on-demand backup for specific SQL Server databases in Azure VM (Hardcoded Parameters)
.DESCRIPTION
    This script initiates on-demand backups for SQL Server databases on:
    Server: d2dhbdbsqdwv1.albtests.com
    VM: dadhbdbsqdwv1
    SQL Instance: d1etl2019v2
.NOTES
    Author: Cloud Operations Team
    Date: November 2, 2025
    Prerequisites:
    - Az.RecoveryServices module installed
    - Backup Operator or Backup Contributor RBAC role
    - Database must be in Protected state
#>

# ============================================================================
# HARDCODED PARAMETERS - UPDATE BEFORE EXECUTION
# ============================================================================

$SubscriptionId = "43cc4f11-ffb1-4a0d-8420-0ba3746b4248"
$VaultName = "bab-dev-backup-vault-swec-01"
$VaultResourceGroup = "bab-dev-backup-rsv-swec-rg-01"
$VMName = "dadhbdbsqdwv1"
$ServerName = "d2dhbdbsqdwv1.albtests.com"
$SQLInstanceName = "d1etl2019v2"

# Database Configuration
# ----------------------
# Option 1: Backup SPECIFIC databases (Recommended)
# Uncomment and specify exact database names:
$SpecificDatabases = @(
    "db_info_rep_etl",
    "db_info_mrs",
    "db_info_dis_doc"
    # Add more database names as needed:
    # "db_info_mrs_ms",
    # "db_info_dis_wf",
    # "db_info_rep_mm",
    # "db_info_dis_sql_ds",
    # "db_info_mrs_ms_1052",
    # "db_info_exception_mgt",
    # "db_info_domain",
    # "db_info_mm",
    # "db_info_dis_profile"
)

# Option 2: Use WILDCARD pattern (Alternative approach)
# Comment out $SpecificDatabases above and uncomment below to use pattern:
# $DatabaseNamePattern = "db_info_*"     # All databases starting with db_info_
# $DatabaseNamePattern = "db_info_rep_*" # All replication databases
# $DatabaseNamePattern = "*"             # All databases (use with caution)

# Backup Configuration
$BackupType = "Full"          # Options: "Full" or "Log"
$RetentionDays = 7           # Backup retention period (1-9999 days)

# Execution Control
$ConfirmBeforeExecute = $true # Set to $false to skip confirmation
$ExcludeSystemDatabases = $true
$SystemDatabases = @("master", "model", "msdb")

# ============================================================================
# SCRIPT EXECUTION - DO NOT MODIFY BELOW THIS LINE
# ============================================================================

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "SQL Server On-Demand Backup Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Configuration:" -ForegroundColor White
Write-Host "  Subscription ID   : $SubscriptionId" -ForegroundColor Gray
Write-Host "  Vault Name        : $VaultName" -ForegroundColor Gray
Write-Host "  Resource Group    : $VaultResourceGroup" -ForegroundColor Gray
Write-Host "  VM Name           : $VMName" -ForegroundColor Gray
Write-Host "  Server            : $ServerName" -ForegroundColor Gray
Write-Host "  SQL Instance      : $SQLInstanceName" -ForegroundColor Gray

if ($SpecificDatabases) {
    Write-Host "  Target Databases  : $($SpecificDatabases.Count) specific database(s)" -ForegroundColor Gray
    $SpecificDatabases | ForEach-Object { Write-Host "                      - $_" -ForegroundColor DarkGray }
} else {
    Write-Host "  Database Pattern  : $DatabaseNamePattern" -ForegroundColor Gray
}

Write-Host "  Backup Type       : $BackupType" -ForegroundColor Gray
Write-Host "  Retention Days    : $RetentionDays" -ForegroundColor Gray
Write-Host ""

# Step 1: Set Azure subscription context
Write-Host "[1/6] Setting Azure subscription context..." -ForegroundColor Cyan
try {
    $context = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    Write-Host "      ✓ Connected to subscription: $($context.Subscription.Name)" -ForegroundColor Green
} catch {
    Write-Host "      ✗ Failed to set subscription context" -ForegroundColor Red
    Write-Host "      Run 'Connect-AzAccount' first to authenticate" -ForegroundColor Yellow
    exit 1
}

# Step 2: Connect to Recovery Services Vault
Write-Host "[2/6] Connecting to Recovery Services Vault..." -ForegroundColor Cyan
try {
    $vault = Get-AzRecoveryServicesVault `
        -Name $VaultName `
        -ResourceGroupName $VaultResourceGroup `
        -ErrorAction Stop
    
    Set-AzRecoveryServicesVaultContext -Vault $vault -ErrorAction Stop
    Write-Host "      ✓ Connected to vault: $VaultName" -ForegroundColor Green
} catch {
    Write-Host "      ✗ Failed to connect to vault" -ForegroundColor Red
    Write-Host "      Verify vault name and resource group" -ForegroundColor Yellow
    exit 1
}

# Step 3: Retrieve backup containers
Write-Host "[3/6] Retrieving backup containers..." -ForegroundColor Cyan
try {
    $containers = Get-AzRecoveryServicesBackupContainer `
        -ContainerType "AzureVMAppContainer" `
        -BackupManagementType "AzureWorkload" `
        -ErrorAction Stop
    
    $containers = $containers | Where-Object { $_.FriendlyName -like "*$VMName*" }
    
    if (-not $containers) {
        throw "No containers found for VM: $VMName"
    }
    
    Write-Host "      ✓ Found container for VM: $VMName" -ForegroundColor Green
} catch {
    Write-Host "      ✗ Failed to retrieve backup containers" -ForegroundColor Red
    Write-Host "      Error: $_" -ForegroundColor Yellow
    exit 1
}

# Step 4: Locate protected databases
Write-Host "[4/6] Locating protected SQL Server databases..." -ForegroundColor Cyan
try {
    $databases = $containers | ForEach-Object {
        Get-AzRecoveryServicesBackupItem `
            -Container $_ `
            -WorkloadType "MSSQL" `
            -ErrorAction Stop
    }
    
    if (-not $databases) {
        throw "No protected databases found in vault"
    }
    
    # Filter for specific SQL instance
    $targetDatabases = $databases | Where-Object { 
        $_.Name -like "SQLDataBase;$SQLInstanceName;*" -and
        $_.ServerName -eq $ServerName -and
        $_.ProtectionState -eq "Protected"
    }
    
    # Apply specific database filter or pattern
    if ($SpecificDatabases) {
        # Filter by specific database names
        $targetDatabases = $targetDatabases | Where-Object {
            $dbName = ($_.Name -split ';')[2]
            $dbName -in $SpecificDatabases
        }
    } elseif ($DatabaseNamePattern) {
        # Filter by wildcard pattern
        $targetDatabases = $targetDatabases | Where-Object {
            ($_.Name -split ';')[2] -like $DatabaseNamePattern
        }
    }
    
    # Exclude system databases if configured
    if ($ExcludeSystemDatabases) {
        $targetDatabases = $targetDatabases | Where-Object {
            $dbName = ($_.Name -split ';')[2]
            $dbName -notin $SystemDatabases
        }
    }
    
    if (-not $targetDatabases) {
        Write-Host "      No protected databases found matching criteria" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Available protected databases on this server:" -ForegroundColor Yellow
        $databases | Where-Object { 
            $_.Name -like "SQLDataBase;$SQLInstanceName;*" -and
            $_.ServerName -eq $ServerName -and
            $_.ProtectionState -eq "Protected"
        } | ForEach-Object {
            $dbName = ($_.Name -split ';')[2]
            Write-Host "  - $dbName" -ForegroundColor Gray
        }
        exit 0
    }
    
    Write-Host "      ✓ Found $($targetDatabases.Count) database(s) matching criteria" -ForegroundColor Green
} catch {
    Write-Host "      ✗ Failed to locate databases" -ForegroundColor Red
    Write-Host "      Error: $_" -ForegroundColor Yellow
    exit 1
}

# Step 5: Display target databases
Write-Host ""
Write-Host "[5/6] Target Database(s) for Backup:" -ForegroundColor Cyan
$targetDatabases | Select-Object `
    @{n="Database";e={($_.Name -split ';')[2]}}, `
    @{n="ProtectionState";e={$_.ProtectionState}}, `
    @{n="LastBackupTime";e={$_.LastBackupTime}}, `
    @{n="HealthStatus";e={$_.HealthStatus}} | 
    Format-Table -AutoSize

# Step 6: Confirmation and trigger backup
if ($ConfirmBeforeExecute) {
    Write-Host ""
    Write-Host "⚠️  Ready to trigger backup operation" -ForegroundColor Yellow
    Write-Host "   Backup Type       : $BackupType" -ForegroundColor White
    Write-Host "   Retention Period  : $RetentionDays days" -ForegroundColor White
    Write-Host "   Target Databases  : $($targetDatabases.Count)" -ForegroundColor White
    Write-Host ""
    
    $confirmation = Read-Host "Type 'BACKUP' (case-sensitive) to proceed or any other key to cancel"
    
    if ($confirmation -ne 'BACKUP') {
        Write-Host "Operation cancelled by user." -ForegroundColor Yellow
        exit 0
    }
}

# Calculate retention date
$retentionDate = (Get-Date).AddDays($RetentionDays).ToUniversalTime()

# Trigger backup operations
Write-Host ""
Write-Host "[6/6] Triggering backup operations..." -ForegroundColor Cyan
$successCount = 0
$failureCount = 0
$backupJobs = @()

foreach ($db in $targetDatabases) {
    $dbName = ($db.Name -split ';')[2]
    
    try {
        Write-Host "      Processing: $dbName..." -ForegroundColor Gray
        
        $backupJob = Backup-AzRecoveryServicesBackupItem `
            -Item $db `
            -BackupType $BackupType `
            -ExpiryDateTimeUTC $retentionDate `
            -ErrorAction Stop
        
        $successCount++
        $backupJobs += [PSCustomObject]@{
            Database = $dbName
            JobId = $backupJob.JobId
            Status = $backupJob.Status
            StartTime = $backupJob.StartTime
            BackupType = $BackupType
            RetentionDays = $RetentionDays
        }
        
        Write-Host "      ✓ $dbName - Backup job initiated" -ForegroundColor Green
        Write-Host "        Job ID: $($backupJob.JobId)" -ForegroundColor Gray
        
    } catch {
        $failureCount++
        $backupJobs += [PSCustomObject]@{
            Database = $dbName
            JobId = "N/A"
            Status = "Failed"
            StartTime = Get-Date
            BackupType = $BackupType
            RetentionDays = $RetentionDays
            ErrorMessage = $_.Exception.Message
        }
        
        Write-Host "      ✗ $dbName - Failed to initiate backup" -ForegroundColor Red
        Write-Host "        Error: $_" -ForegroundColor Yellow
    }
}

# Display operation summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Backup Operation Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total Databases   : $($targetDatabases.Count)" -ForegroundColor White
Write-Host "Successful        : $successCount" -ForegroundColor Green
Write-Host "Failed            : $failureCount" -ForegroundColor $(if ($failureCount -gt 0) { "Red" } else { "Green" })
Write-Host "Backup Type       : $BackupType" -ForegroundColor White
Write-Host "Retention Period  : $RetentionDays days" -ForegroundColor White
Write-Host ""

# Display backup job details
if ($backupJobs.Count -gt 0) {
    Write-Host "Backup Job Details:" -ForegroundColor White
    $backupJobs | Format-Table -AutoSize
    
    Write-Host ""
    Write-Host "Monitor backup job progress:" -ForegroundColor Cyan
    Write-Host "  Get-AzRecoveryServicesBackupJob -VaultId '$($vault.ID)'" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Check specific job status:" -ForegroundColor Cyan
    Write-Host "  Get-AzRecoveryServicesBackupJob -VaultId '$($vault.ID)' -JobId '<job-id>'" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Next Steps:" -ForegroundColor White
Write-Host "  1. Monitor backup job progress in Azure Portal or PowerShell" -ForegroundColor Gray
Write-Host "  2. Verify backup completion status after job finishes" -ForegroundColor Gray
Write-Host "  3. Document backup activity in change management system" -ForegroundColor Gray
Write-Host ""
Write-Host "Script completed at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host "Executed by: $env:USERNAME on $env:COMPUTERNAME" -ForegroundColor Gray
Write-Host ""