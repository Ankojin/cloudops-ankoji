[CmdletBinding()]
param()

# =========================
# Dry-Run Toggle
# =========================
$DryRun = $false   # SET TO $true FOR DRY RUN

# =========================
# Paths
# =========================
$CsvPath = "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\Azure-Scripts\Backup\vms-backup.csv"
$LogPath = Join-Path $PSScriptRoot ("Backup-Enable-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

# =========================
# Azure Settings
# =========================
$SubscriptionId = "43cc4f11-ffb1-4a0d-8420-0ba3746b4248"
$VaultName      = "bab-dev-backup-vault-swec-01"
$PolicyName     = "Daily-Backup-policy-Ret-7days"

# =========================
# Logging
# =========================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","SUCCESS","WARN","ERROR","DRYRUN")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp [$Level] $Message"
    Add-Content -Path $LogPath -Value $line

    switch ($Level) {
        "ERROR"   { Write-Host $line -ForegroundColor Red }
        "WARN"    { Write-Host $line -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $line -ForegroundColor Green }
        "DRYRUN"  { Write-Host $line -ForegroundColor Magenta }
        default   { Write-Host $line }
    }
}

Write-Log "Script started. DryRun=$DryRun"

# =========================
# Azure Context
# =========================
Set-AzContext -SubscriptionId $SubscriptionId
Write-Log "Connected to subscription $SubscriptionId"

$vault = Get-AzRecoveryServicesVault -Name $VaultName -ErrorAction Stop
Set-AzRecoveryServicesVaultContext -Vault $vault
Write-Log "Vault context set to $VaultName"

$policy = Get-AzRecoveryServicesBackupProtectionPolicy -Name $PolicyName -ErrorAction Stop
Write-Log "Using backup policy '$PolicyName'"

# =========================
# CSV Validation
# =========================
$vms = Import-Csv -Path $CsvPath
$requiredHeaders = @("ResourceGroup", "VMName")

foreach ($header in $requiredHeaders) {
    if (-not $vms[0].PSObject.Properties.Name -contains $header) {
        Write-Log "CSV missing required column: $header" "ERROR"
        throw "Invalid CSV"
    }
}

# =========================
# Process VMs
# =========================
foreach ($entry in $vms) {
    $rg     = $entry.ResourceGroup
    $vmName = $entry.VMName

    # Skip empty rows
    if ([string]::IsNullOrWhiteSpace($rg) -or [string]::IsNullOrWhiteSpace($vmName)) {
        Write-Log "Skipping empty or invalid CSV row" "WARN"
        continue
    }

    Write-Log "Processing VM '$vmName' in RG '$rg'"

    try {
        # Validate VM exists
        Get-AzVM -ResourceGroupName $rg -Name $vmName -ErrorAction Stop | Out-Null
        Write-Log "VM found"

        # Get container (vault-scoped)
        $container = Get-AzRecoveryServicesBackupContainer `
            -ContainerType AzureVM `
            -FriendlyName $vmName `
            -ErrorAction SilentlyContinue

        # Try to get existing backup item
        $item = $null
        if ($container) {
            $item = Get-AzRecoveryServicesBackupItem `
                -Container $container `
                -WorkloadType AzureVM `
                -ErrorAction SilentlyContinue
        }

        if ($DryRun) {
            if ($item) {
                Write-Log "Would trigger manual backup for already protected VM" "DRYRUN"
            } else {
                Write-Log "Would enable backup (policy: $PolicyName)" "DRYRUN"
                Write-Log "Would trigger initial backup" "DRYRUN"
            }
            continue
        }

        if ($item) {
            Write-Log "Backup already enabled — triggering manual backup" "SUCCESS"
            Backup-AzRecoveryServicesBackupItem -Item $item | Out-Null
            Write-Log "Manual backup triggered for already protected VM" "SUCCESS"
            continue
        }

        # FIRST-TIME ENABLE (Name + ResourceGroupName REQUIRED)
        Write-Log "Enabling backup protection"
        Enable-AzRecoveryServicesBackupProtection `
            -Policy $policy `
            -Name $vmName `
            -ResourceGroupName $rg `
            -ErrorAction Stop

        Write-Log "Backup protection enabled" "SUCCESS"

        # Get container & item again after enable
        $container = Get-AzRecoveryServicesBackupContainer `
            -ContainerType AzureVM `
            -FriendlyName $vmName `
            -ErrorAction Stop

        $item = Get-AzRecoveryServicesBackupItem `
            -Container $container `
            -WorkloadType AzureVM `
            -ErrorAction Stop

        Backup-AzRecoveryServicesBackupItem -Item $item | Out-Null
        Write-Log "Initial backup triggered" "SUCCESS"
    }
    catch {
        Write-Log "Failed processing VM '$vmName' : $_" "ERROR"
    }
}

Write-Log "Script completed."