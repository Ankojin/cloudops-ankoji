Param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$VaultName,

    [Parameter(Mandatory = $true)]
    [string]$VaultResourceGroup,

    [string]$VMName,

    [string]$ServerName,

    [string]$DatabaseName
)

Write-Verbose "Signing in and setting subscription context..."
Connect-AzAccount -ErrorAction Stop | Out-Null
Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null

Write-Verbose "Locating Recovery Services vault ${VaultName} in ${VaultResourceGroup}..."
$vault = Get-AzRecoveryServicesVault -Name $VaultName -ResourceGroupName $VaultResourceGroup -ErrorAction Stop
Set-AzRecoveryServicesVaultContext -Vault $vault -ErrorAction Stop

Write-Verbose "Retrieving all protected SQL Server databases in Azure VMs..."
$containers = Get-AzRecoveryServicesBackupContainer -ContainerType "AzureVMAppContainer" -BackupManagementType "AzureWorkload" -ErrorAction Stop

if ($VMName) {
    $containers = $containers | Where-Object { $_.FriendlyName -like "*$VMName*" }
}

$databases = $containers | ForEach-Object {
    Get-AzRecoveryServicesBackupItem -Container $_ -WorkloadType "MSSQL" -ErrorAction Stop
}

if (-not $databases) {
    throw "No protected SQL Server databases found in vault ${VaultName}."
}

$filtered = $databases
if ($ServerName) {
    $filtered = $filtered | Where-Object { $_.ServerName -like "*$ServerName*" }
}
if ($DatabaseName) {
    $filtered = $filtered | Where-Object { $_.Name -like "*$DatabaseName*" }
}

if (-not $filtered) {
    Write-Warning "No databases matched the provided filters."
    return
}

Write-Output "Current protected SQL Server databases in Azure VMs (vault: ${VaultName}):"
$filtered | Select-Object @{n = "VM"; e = { $_.ContainerName }},
                          @{n = "Server"; e = { $_.ServerName }},
                          @{n = "Database"; e = { $_.Name }},
                          @{n = "ProtectionState"; e = { $_.ProtectionState }},
                          @{n = "LastBackupTime"; e = { $_.LastBackupTime }}