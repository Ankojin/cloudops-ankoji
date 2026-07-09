<#
.SYNOPSIS
    Installs the Guest Attestation extension on supported Windows virtual machines.

.DESCRIPTION
    Scans Windows VMs in the specified subscription(s) and installs the
    Microsoft.Azure.Security.WindowsAttestation / GuestAttestation extension
    on any VM that does not already have it.
    Supports single VM, resource group scope, or full subscription sweep.
    Use -WhatIf to preview without making changes.

.PARAMETER SubscriptionId
    Required. One or more Azure subscription IDs to target.

.PARAMETER ResourceGroupName
    Limit scope to a specific resource group (optional).

.PARAMETER VMName
    Target a single VM by name (optional). If omitted, all Windows VMs in scope are processed.

.PARAMETER CsvPath
    Optional path to a CSV file with columns: vmName, resourceGroup.
    If provided, only VMs listed in the CSV are processed.

.PARAMETER LogPath
    Path to the output log file. Defaults to a timestamped file in the script directory.

.EXAMPLE
    # Preview across all VMs in a subscription
    .\Install-GuestAttestationExtension.ps1 -SubscriptionId "sub-id" -WhatIf

.EXAMPLE
    # Install on all Windows VMs in a subscription
    .\Install-GuestAttestationExtension.ps1 -SubscriptionId "sub-id"

.EXAMPLE
    # Install on a single VM
    .\Install-GuestAttestationExtension.ps1 -SubscriptionId "sub-id" -VMName "MyVM" -ResourceGroupName "MyResourceGroup"

.EXAMPLE
    # Install using a CSV list of VMs
    .\Install-GuestAttestationExtension.ps1 -SubscriptionId "sub-id" -CsvPath ".\vmList.csv"

.NOTES
    Requirements : Az.Compute module (Az 9+)
    Permissions  : Virtual Machine Contributor or Owner on each VM
    Extension    : Microsoft.Azure.Security.WindowsAttestation / GuestAttestation
    Supported OS : Windows (Windows Server 2016 and later, Windows 10+)
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param (
    [Parameter(Mandatory = $true, HelpMessage = 'One or more Azure subscription IDs to target.')]
    [string[]]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$VMName,

    [Parameter(Mandatory = $false)]
    [string]$CsvPath,

    [Parameter(Mandatory = $false)]
    [string]$LogPath
)

#region --- Constants -----------------------------------------------------
$ExtensionName      = 'GuestAttestation'
$ExtensionPublisher = 'Microsoft.Azure.Security.WindowsAttestation'
$ExtensionType      = 'GuestAttestation'
$ExtensionVersion   = '1.0'
#endregion

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
        [ValidateSet('INFO','WARN','ERROR','ACTION','SUCCESS','WHATIF','SKIP')]
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
        'SKIP'    { 'DarkGray'}
        default   { 'White'   }
    }
    Write-Host $entry -ForegroundColor $color
}
#endregion

#region --- Prerequisites ------------------------------------------------
Write-Log "=== Install-GuestAttestationExtension started ===" -Level INFO
Write-Log "Log file: $LogPath" -Level INFO

if (-not (Get-Module -ListAvailable -Name Az.Compute)) {
    Write-Log "Az.Compute module not found. Install with: Install-Module Az.Compute" -Level ERROR
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

#region --- CSV input (optional) -----------------------------------------
$csvVMs = $null
if ($CsvPath) {
    if (-not (Test-Path $CsvPath)) {
        Write-Log "CSV file not found: $CsvPath" -Level ERROR
        exit 1
    }
    $csvVMs = Import-Csv -Path $CsvPath
    Write-Log "Loaded $($csvVMs.Count) VMs from CSV: $CsvPath" -Level INFO
}
#endregion

#region --- Counters ------------------------------------------------------
$stats = @{
    Total      = 0
    AlreadyInstalled = 0
    Installed  = 0
    Skipped    = 0   # WhatIf / non-Windows / unsupported
    Failed     = 0
}
#endregion

foreach ($sid in $SubscriptionId) {
    $sub = Get-AzSubscription -SubscriptionId $sid -ErrorAction SilentlyContinue
    if (-not $sub) {
        Write-Log "Subscription not found or not accessible: $sid" -Level WARN
        continue
    }

    Write-Log "--- Processing subscription: $($sub.Name) ($sid) ---" -Level INFO
    Set-AzContext -SubscriptionId $sid | Out-Null

    # Build list of VMs to process
    $vmList = @()

    if ($csvVMs) {
        foreach ($row in $csvVMs) {
            $v = Get-AzVM -Name $row.vmName.Trim() -ResourceGroupName $row.resourceGroup.Trim() -ErrorAction SilentlyContinue
            if ($v) { $vmList += $v }
            else    { Write-Log "VM from CSV not found: $($row.vmName) / $($row.resourceGroup)" -Level WARN }
        }
    }
    elseif ($VMName -and $ResourceGroupName) {
        $v = Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        if ($v) { $vmList += $v }
        else    { Write-Log "VM not found: $VMName in $ResourceGroupName" -Level WARN }
    }
    elseif ($ResourceGroupName) {
        $vmList += Get-AzVM -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    }
    else {
        $vmList += Get-AzVM -ErrorAction SilentlyContinue
    }

    if ($vmList.Count -eq 0) {
        Write-Log "No VMs found in scope for subscription '$($sub.Name)'." -Level WARN
        continue
    }

    Write-Log "VMs in scope: $($vmList.Count)" -Level INFO

    foreach ($vm in $vmList) {
        $stats.Total++
        $vmNameCurrent = $vm.Name
        $rgName        = $vm.ResourceGroupName
        $location      = $vm.Location

        Write-Log "Inspecting VM: $vmNameCurrent (RG: $rgName, Location: $location)" -Level INFO

        # OS check — only Windows supported
        $osType = $null
        if ($vm.StorageProfile.OsDisk.OsType) {
            $osType = $vm.StorageProfile.OsDisk.OsType
        }
        elseif ($vm.OSProfile.WindowsConfiguration) { $osType = 'Windows' }
        elseif ($vm.OSProfile.LinuxConfiguration)   { $osType = 'Linux'   }

        if ($osType -ne 'Windows') {
            Write-Log "  Skipping '$vmNameCurrent' — OS is '$osType' (Guest Attestation Windows extension not applicable)." -Level SKIP
            $stats.Skipped++
            continue
        }

        # Check if extension already installed
        $existing = Get-AzVMExtension -ResourceGroupName $rgName -VMName $vmNameCurrent `
                                       -Name $ExtensionName -ErrorAction SilentlyContinue

        if ($existing -and $existing.ProvisioningState -eq 'Succeeded') {
            Write-Log "  '$vmNameCurrent' already has GuestAttestation extension (v$($existing.TypeHandlerVersion)). No action needed." -Level SUCCESS
            $stats.AlreadyInstalled++
            continue
        }

        # Check VM power state — extension needs VM running
        $vmStatus  = Get-AzVM -ResourceGroupName $rgName -Name $vmNameCurrent -Status -ErrorAction SilentlyContinue
        $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like 'PowerState/*' }).DisplayStatus

        if ($powerState -ne 'VM running') {
            Write-Log "  Skipping '$vmNameCurrent' — power state is '$powerState'. VM must be running to install extension." -Level WARN
            $stats.Skipped++
            continue
        }

        Write-Log "  ACTION: Installing GuestAttestation extension on '$vmNameCurrent'..." -Level ACTION

        if ($PSCmdlet.ShouldProcess("VM '$vmNameCurrent' in '$rgName'", "Install GuestAttestation extension")) {
            try {
                Set-AzVMExtension `
                    -ResourceGroupName  $rgName `
                    -VMName             $vmNameCurrent `
                    -Location           $location `
                    -Name               $ExtensionName `
                    -Publisher          $ExtensionPublisher `
                    -ExtensionType      $ExtensionType `
                    -TypeHandlerVersion $ExtensionVersion `
                    -ErrorAction Stop | Out-Null

                # Verify
                $verify = Get-AzVMExtension -ResourceGroupName $rgName -VMName $vmNameCurrent `
                                             -Name $ExtensionName -ErrorAction SilentlyContinue

                if ($verify.ProvisioningState -eq 'Succeeded') {
                    Write-Log "  SUCCESS: GuestAttestation installed on '$vmNameCurrent' (v$($verify.TypeHandlerVersion))." -Level SUCCESS
                    $stats.Installed++
                }
                else {
                    Write-Log "  Extension deployed but state is '$($verify.ProvisioningState)' on '$vmNameCurrent'. Manual check required." -Level WARN
                    $stats.Failed++
                }
            }
            catch {
                Write-Log "  FAILED to install extension on '$vmNameCurrent': $_" -Level ERROR
                $stats.Failed++
            }
        }
        else {
            Write-Log "  WHATIF: Would install GuestAttestation extension on '$vmNameCurrent'." -Level WHATIF
            $stats.Skipped++
        }
    }
}

#region --- Summary -------------------------------------------------------
Write-Log "------------------------------" -Level INFO
Write-Log "========== SUMMARY ==========" -Level INFO
Write-Log "  Total VMs evaluated        : $($stats.Total)"            -Level INFO
Write-Log "  Already installed          : $($stats.AlreadyInstalled)" -Level SUCCESS
Write-Log "  Installed successfully     : $($stats.Installed)"        -Level SUCCESS
Write-Log "  Skipped (non-Windows/off)  : $($stats.Skipped)"          -Level $(if ($stats.Skipped -gt 0) { 'WARN' } else { 'INFO' })
Write-Log "  Failed                     : $($stats.Failed)"            -Level $(if ($stats.Failed -gt 0) { 'ERROR' } else { 'INFO' })
Write-Log "  Log saved to               : $LogPath"                    -Level INFO
Write-Log "==============================" -Level INFO
#endregion
