<#
.SYNOPSIS
    Enables Soft Delete and Purge Protection on Azure Key Vaults.

.DESCRIPTION
    Iterates over one or more Key Vaults (by name, resource group, or subscription)
    and ensures that both Soft Delete (prerequisite) and Purge Protection are enabled.
    Soft delete is irreversible once enabled; purge protection is also irreversible.
    Use -WhatIf to preview changes without applying them.

.PARAMETER SubscriptionId
    Required. One or more Azure subscription IDs to target.

.PARAMETER ResourceGroupName
    Limit scope to a specific resource group (optional).

.PARAMETER KeyVaultName
    Required. Name of the Key Vault to enable purge protection on.

.PARAMETER SoftDeleteRetentionDays
    Retention period in days for soft-deleted objects (7–90). Default: 90.

.PARAMETER LogPath
    Path to the output log file. Defaults to a timestamped file in the script directory.

.EXAMPLE
    # Preview changes across the current subscription
    .\Enable-KeyVaultPurgeProtection.ps1 -WhatIf

.EXAMPLE
    # Enable on a single vault
    .\Enable-KeyVaultPurgeProtection.ps1 -KeyVaultName "my-keyvault" -ResourceGroupName "rg-security"

.EXAMPLE
    # Enable across multiple subscriptions
    .\Enable-KeyVaultPurgeProtection.ps1 -SubscriptionId "sub-id-1","sub-id-2"

.NOTES
    Requirements : Az.KeyVault module (Az 9+)
    Permissions  : Key Vault Contributor or Owner on each vault
    WARNING      : Purge Protection is IRREVERSIBLE once enabled.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param (
    [Parameter(Mandatory = $true, HelpMessage = 'One or more Azure subscription IDs to target.')]
    [string[]]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false, HelpMessage = 'Target a single vault by name. If omitted, ALL vaults in scope are processed.')]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $false)]
    [ValidateRange(7, 90)]
    [int]$SoftDeleteRetentionDays = 30,

    [Parameter(Mandatory = $false)]
    [string]$LogPath
)

#region --- Logging -------------------------------------------------------
$ScriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)
$Timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'

if (-not $LogPath) {
    $LogPath = Join-Path $PSScriptRoot "$($ScriptName)_$Timestamp.log"
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','ACTION','SUCCESS','WHATIF')]
        [string]$Level = 'INFO'
    )
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogPath -Value $entry -Encoding UTF8 -WhatIf:$false

    $color = switch ($Level) {
        'WARN'    { 'Yellow'  }
        'ERROR'   { 'Red'     }
        'ACTION'  { 'Cyan'    }
        'SUCCESS' { 'Green'   }
        'WHATIF'  { 'Magenta' }
        default   { 'White'   }
    }
    Write-Host $entry -ForegroundColor $color
}
#endregion

#region --- Prerequisites -------------------------------------------------
Write-Log "=== Enable-KeyVaultPurgeProtection started ===" -Level INFO
Write-Log "Log file: $LogPath" -Level INFO

if (-not (Get-Module -ListAvailable -Name Az.KeyVault)) {
    Write-Log "Az.KeyVault module not found. Install with: Install-Module Az.KeyVault" -Level ERROR
    exit 1
}

try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context) { throw "Not logged in" }
    Write-Log "Current Az context: $($context.Account) / $($context.Subscription.Name)" -Level INFO
}
catch {
    Write-Log "Not authenticated. Run Connect-AzAccount first. $_" -Level ERROR
    exit 1
}
#endregion

#region --- Subscription scope -------------------------------------------
$subscriptions = @()
if ($SubscriptionId) {
    foreach ($sid in $SubscriptionId) {
        $sub = Get-AzSubscription -SubscriptionId $sid -ErrorAction SilentlyContinue
        if ($sub) { $subscriptions += $sub }
        else       { Write-Log "Subscription not found or not accessible: $sid" -Level WARN }
    }
}
else {
    $subscriptions += $context.Subscription
}

if ($subscriptions.Count -eq 0) {
    Write-Log "No accessible subscriptions found. Exiting." -Level ERROR
    exit 1
}
Write-Log "Subscriptions in scope: $($subscriptions.Count)" -Level INFO
#endregion

#region --- Counters ------------------------------------------------------
$stats = @{ Total = 0; AlreadyProtected = 0; Updated = 0; Failed = 0; Skipped = 0 }
#endregion

foreach ($sub in $subscriptions) {
    Write-Log "--- Processing subscription: $($sub.Name) ($($sub.Id)) ---" -Level INFO
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    # Collect vaults
    $vaultParams = @{}
    if ($ResourceGroupName) { $vaultParams['ResourceGroupName'] = $ResourceGroupName }
    if ($KeyVaultName)       { $vaultParams['VaultName']         = $KeyVaultName       }

    try {
        $vaults = Get-AzKeyVault @vaultParams -ErrorAction Stop
    }
    catch {
        Write-Log "Failed to retrieve Key Vaults in subscription $($sub.Name): $_" -Level ERROR
        $stats.Failed++
        continue
    }

    if (-not $vaults) {
        Write-Log "No Key Vaults found with the given scope in subscription $($sub.Name)." -Level WARN
        continue
    }

    foreach ($vaultRef in $vaults) {
        $stats.Total++
        $vaultName = $vaultRef.VaultName
        $rgName    = $vaultRef.ResourceGroupName

        Write-Log "Inspecting vault: $vaultName (RG: $rgName)" -Level INFO

        # Get full vault object for property detail
        try {
            $vault = Get-AzKeyVault -VaultName $vaultName -ResourceGroupName $rgName -ErrorAction Stop
        }
        catch {
            Write-Log "Cannot read vault '$vaultName': $_" -Level ERROR
            $stats.Failed++
            continue
        }

        $softDeleteEnabled   = $vault.EnableSoftDelete
        $purgeProtEnabled    = $vault.EnablePurgeProtection

        Write-Log "  SoftDelete=$softDeleteEnabled  PurgeProtection=$purgeProtEnabled  RetentionDays=$($vault.SoftDeleteRetentionInDays)" -Level INFO

        # Already fully protected?
        if ($softDeleteEnabled -and $purgeProtEnabled) {
            Write-Log "  Vault '$vaultName' already has Soft Delete + Purge Protection enabled. No action needed." -Level SUCCESS
            $stats.AlreadyProtected++
            continue
        }

        # Build update parameters
        $updateParams = @{
            VaultName         = $vaultName
            ResourceGroupName = $rgName
            EnablePurgeProtection = $true   # implicitly enables soft delete
        }

        # Warn about retention days change only if soft delete not yet active
        if (-not $softDeleteEnabled) {
            Write-Log "  Soft Delete not enabled. Will enable with retention = $SoftDeleteRetentionDays days." -Level ACTION
            $updateParams['SoftDeleteRetentionInDays'] = $SoftDeleteRetentionDays
        }
        else {
            Write-Log "  Soft Delete already enabled (retention=$($vault.SoftDeleteRetentionInDays) days). Enabling Purge Protection only." -Level ACTION
        }

        Write-Log "  ACTION: Enabling Purge Protection on '$vaultName'" -Level ACTION

        if ($PSCmdlet.ShouldProcess("Key Vault '$vaultName' in '$rgName'", "Enable Soft Delete + Purge Protection")) {
            try {
                Update-AzKeyVault @updateParams -ErrorAction Stop | Out-Null

                # Verify
                $verify = Get-AzKeyVault -VaultName $vaultName -ResourceGroupName $rgName -ErrorAction Stop
                if ($verify.EnablePurgeProtection) {
                    Write-Log "  SUCCESS: Purge Protection enabled on '$vaultName'." -Level SUCCESS
                    $stats.Updated++
                }
                else {
                    Write-Log "  Purge Protection still not active on '$vaultName' after update. Manual check required." -Level WARN
                    $stats.Failed++
                }
            }
            catch {
                Write-Log "  FAILED to update vault '$vaultName': $_" -Level ERROR
                $stats.Failed++
            }
        }
        else {
            Write-Log "  WHATIF: Would enable Purge Protection (and Soft Delete if needed) on '$vaultName'." -Level WHATIF
            $stats.Skipped++
        }
    }
}

#region --- Summary -------------------------------------------------------
Write-Log "------------------------------" -Level INFO
Write-Log "========== SUMMARY ==========" -Level INFO
Write-Log "  Total vaults evaluated : $($stats.Total)"            -Level INFO
Write-Log "  Already protected      : $($stats.AlreadyProtected)" -Level SUCCESS
Write-Log "  Updated successfully   : $($stats.Updated)"          -Level SUCCESS
Write-Log "  Failed                 : $($stats.Failed)"            -Level $(if ($stats.Failed -gt 0) { 'ERROR' } else { 'INFO' })
Write-Log "  Skipped (WhatIf)       : $($stats.Skipped)"          -Level $(if ($stats.Skipped -gt 0) { 'WHATIF' } else { 'INFO' })
Write-Log "  Log saved to           : $LogPath"                    -Level INFO
Write-Log "==============================" -Level INFO
#endregion
