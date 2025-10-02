# ================================
# Variables
# ================================
$SubscriptionId   = "43cc4f11-ffb1-4a0d-8420-0ba3746b4248"
$ResourceGroup    = "bab-dev-backup-rsv-swec-rg-01"
$VaultName        = "bab-dev-backup-vault-swec-01"

# ================================
# Connect to Azure
# ================================
#Connect-AzAccount
Select-AzSubscription -SubscriptionId $SubscriptionId

# ================================
# Set Recovery Services Vault Context
# ================================
$vault = Get-AzRecoveryServicesVault -Name $VaultName -ResourceGroupName $ResourceGroup
Set-AzRecoveryServicesVaultContext -Vault $vault

# ================================
# Get all containers (SQL Servers registered in the vault)
# ================================
$containers = @(Get-AzRecoveryServicesBackupContainer -ContainerType "AzureSQL")
Write-Host "Total containers found: $($containers.Count)"
foreach ($c in $containers) {
    Write-Host "Container: $($c.FriendlyName), Type: $($c.ContainerType), Status: $($c.RegistrationStatus)"
}
$registeredContainers = $containers | Where-Object { $_.RegistrationStatus -eq "Registered" }

if (!$registeredContainers) {
    Write-Host "No registered Azure SQL containers found in the Recovery Services Vault." -ForegroundColor Red
} else {
    $dbChecked = 0
    $dbBackedUp = 0
    foreach ($container in $registeredContainers) {
        Write-Host "Checking protected items in container:" $container.FriendlyName -ForegroundColor Yellow

        $dbs = Get-AzRecoveryServicesBackupItem -WorkloadType "SQLDataBase" -Container $container

        foreach ($db in $dbs) {
            $dbChecked++
            if ($db.ProtectionStatus -eq "Warning" -and $db.ProtectionState -eq "IRPending") {
                Write-Host "⚠️ Initial backup pending → Triggering full backup for DB:" $db.FriendlyName -ForegroundColor Cyan
                Backup-AzRecoveryServicesBackupItem -Item $db -BackupType Full -Force
                $dbBackedUp++
            }
            else {
                Write-Host "Skipping DB (Already has backups or not pending):" $db.FriendlyName "Status: $($db.ProtectionStatus), State: $($db.ProtectionState)" -ForegroundColor Green
            }
        }
    }
    Write-Host "`nSummary:"
    Write-Host "Checked databases: $dbChecked"
    Write-Host "Triggered backups: $dbBackedUp"
}
