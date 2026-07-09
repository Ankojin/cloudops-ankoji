<#
.SYNOPSIS
    Reports Soft Delete and Purge Protection status for all Key Vaults in a subscription.

.DESCRIPTION
    Scans all Key Vaults in the specified subscription(s) and outputs a table showing
    whether Soft Delete and Purge Protection are enabled on each vault.
    Optionally exports results to CSV.

.PARAMETER SubscriptionId
    Required. One or more Azure subscription IDs to scan.

.PARAMETER ResourceGroupName
    Limit scope to a specific resource group (optional).

.PARAMETER ExportCsv
    If specified, exports the report to this CSV file path.

.PARAMETER LogPath
    Path to the output log file. Defaults to a timestamped file in the script directory.

.EXAMPLE
    .\Get-KeyVaultProtectionStatus.ps1 -SubscriptionId "e48414cd-f96d-4414-ae9e-da7fec844f77"

.EXAMPLE
    .\Get-KeyVaultProtectionStatus.ps1 -SubscriptionId "sub-id-1","sub-id-2" -ExportCsv "C:\Reports\kv-status.csv"

.EXAMPLE
    .\Get-KeyVaultProtectionStatus.ps1 -SubscriptionId "sub-id" -ResourceGroupName "rg-security"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = 'One or more Azure subscription IDs to scan.')]
    [string[]]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$ExportCsv,

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
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')]
        [string]$Level = 'INFO'
    )
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogPath -Value $entry -Encoding UTF8

    $color = switch ($Level) {
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red'    }
        'SUCCESS' { 'Green'  }
        default   { 'White'  }
    }
    Write-Host $entry -ForegroundColor $color
}
#endregion

#region --- Prerequisites ------------------------------------------------
Write-Log "=== Get-KeyVaultProtectionStatus started ===" -Level INFO
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

#region --- Collect results ----------------------------------------------
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($sid in $SubscriptionId) {
    $sub = Get-AzSubscription -SubscriptionId $sid -ErrorAction SilentlyContinue
    if (-not $sub) {
        Write-Log "Subscription not found or not accessible: $sid" -Level WARN
        continue
    }

    Write-Log "--- Scanning subscription: $($sub.Name) ($sid) ---" -Level INFO
    Set-AzContext -SubscriptionId $sid | Out-Null

    $vaultParams = @{}
    if ($ResourceGroupName) { $vaultParams['ResourceGroupName'] = $ResourceGroupName }

    try {
        $vaults = Get-AzKeyVault @vaultParams -ErrorAction Stop
    }
    catch {
        Write-Log "Failed to list Key Vaults in subscription '$($sub.Name)': $_" -Level ERROR
        continue
    }

    if (-not $vaults) {
        Write-Log "No Key Vaults found in subscription '$($sub.Name)'." -Level WARN
        continue
    }

    foreach ($vaultRef in $vaults) {
        try {
            $vault = Get-AzKeyVault -VaultName $vaultRef.VaultName `
                                    -ResourceGroupName $vaultRef.ResourceGroupName `
                                    -ErrorAction Stop

            $softDelete   = if ($vault.EnableSoftDelete)      { 'Enabled' } else { 'Disabled' }
            $purgeProtect = if ($vault.EnablePurgeProtection) { 'Enabled' } else { 'Disabled' }
            $fullyProtected = ($vault.EnableSoftDelete -and $vault.EnablePurgeProtection)

            $row = [PSCustomObject]@{
                SubscriptionName      = $sub.Name
                SubscriptionId        = $sid
                ResourceGroup         = $vault.ResourceGroupName
                KeyVaultName          = $vault.VaultName
                Location              = $vault.Location
                SKU                   = $vault.Sku
                SoftDelete            = $softDelete
                RetentionDays         = $vault.SoftDeleteRetentionInDays
                PurgeProtection       = $purgeProtect
                FullyProtected        = if ($fullyProtected) { 'YES' } else { 'NO - ACTION REQUIRED' }
            }
            $results.Add($row)

            $level = if ($fullyProtected) { 'SUCCESS' } else { 'WARN' }
            Write-Log "  $($vault.VaultName) | SoftDelete=$softDelete | PurgeProtection=$purgeProtect | FullyProtected=$($row.FullyProtected)" -Level $level
        }
        catch {
            Write-Log "  Failed to inspect vault '$($vaultRef.VaultName)': $_" -Level ERROR
        }
    }
}
#endregion

#region --- Summary table ------------------------------------------------
Write-Log "------------------------------" -Level INFO
Write-Log "========== SUMMARY ==========" -Level INFO
Write-Log "Total vaults scanned   : $($results.Count)" -Level INFO
Write-Log "Fully protected        : $(($results | Where-Object { $_.FullyProtected -eq 'YES' }).Count)" -Level SUCCESS

$notProtected = $results | Where-Object { $_.FullyProtected -ne 'YES' }
if ($notProtected.Count -gt 0) {
    Write-Log "Action required        : $($notProtected.Count)" -Level WARN
}
else {
    Write-Log "Action required        : 0" -Level SUCCESS
}
Write-Log "==============================" -Level INFO
#endregion

#region --- Console table output ----------------------------------------
Write-Host "`n===== KEY VAULT PROTECTION STATUS =====" -ForegroundColor Cyan
$results | Format-Table -AutoSize -Property KeyVaultName, ResourceGroup, Location, SoftDelete, RetentionDays, PurgeProtection, FullyProtected
#endregion

#region --- CSV export --------------------------------------------------
if ($ExportCsv) {
    try {
        $results | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
        Write-Log "Report exported to: $ExportCsv" -Level SUCCESS
    }
    catch {
        Write-Log "Failed to export CSV to '$ExportCsv': $_" -Level ERROR
    }
}
#endregion

# Return results object for pipeline use
return $results
