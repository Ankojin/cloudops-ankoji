# ==============================================================================
# Script  : Windows Server In-Place Upgrade (Azure VM)
# Supports: WS 2008/2008R2 → 2012  │  WS 2012/2012R2 → 2016  │  WS 2012R2/2016 → 2019
#           WS 2016/2019   → 2022  │  WS 2012R2/2016/2019/2022 → 2025
# Modes   : Single VM  |  Multi-VM from CSV  |  Parallel (PS7+)
# Reference: https://learn.microsoft.com/en-us/azure/virtual-machines/windows-in-place-upgrade
#
# USAGE EXAMPLES
# --------------
# Single VM:
#   .\Invoke-WindowsServer2025-InPlaceUpgrade.ps1 `
#       -ResourceGroupName "bab-dev-mub-swec-rg-01" `
#       -VMName "DAMUBOMSAPWV02"
#
# Multiple VMs from CSV (sequential):
#   .\Invoke-WindowsServer2025-InPlaceUpgrade.ps1 -CsvPath .\vms-to-upgrade.csv
#
# Multiple VMs from CSV (parallel, PS7+, 3 at a time):
#   .\Invoke-WindowsServer2025-InPlaceUpgrade.ps1 -CsvPath .\vms-to-upgrade.csv -Parallel -ThrottleLimit 3
#
# Dry run (WhatIf):
#   .\Invoke-WindowsServer2025-InPlaceUpgrade.ps1 -ResourceGroupName "rg-01" -VMName "VM01" -WhatIf
#
# CSV REQUIRED COLUMNS: ResourceGroupName, VMName, Region, TargetSKU, UpgradeMediaSku
# CSV OPTIONAL COLUMN : UpgradeDiskName
#
# EXAMPLES — NON-2025 TARGET VERSIONS
# ------------------------------------
# WS 2019 → WS 2022  (UpgradeMediaSku auto-derived):
#   .\Invoke-WindowsServer2025-InPlaceUpgrade.ps1 `
#       -ResourceGroupName "rg-prod" `
#       -VMName "APPSERVER01" `
#       -TargetSKU "Windows Server 2022 Datacenter - x64 Gen2"
#
# WS 2016 → WS 2019  (Gen1 VM, explicit media SKU):
#   .\Invoke-WindowsServer2025-InPlaceUpgrade.ps1 `
#       -ResourceGroupName "rg-prod" `
#       -VMName "APPSERVER02" `
#       -TargetSKU "Windows Server 2019 Datacenter - x64 Gen1" `
#       -UpgradeMediaSku "server2019Upgrade"
#
# WS 2012 R2 → WS 2016  (auto TargetSKU Gen correction applies):
#   .\Invoke-WindowsServer2025-InPlaceUpgrade.ps1 `
#       -ResourceGroupName "rg-prod" `
#       -VMName "LEGACYSRV01" `
#       -TargetSKU "Windows Server 2016 Datacenter - x64 Gen2"
#
# WS 2012 → WS 2016  (Gen1 only — WS2012 has no Gen2 variant):
#   .\Invoke-WindowsServer2025-InPlaceUpgrade.ps1 `
#       -ResourceGroupName "rg-prod" `
#       -VMName "LEGACYSRV02" `
#       -TargetSKU "Windows Server 2016 Datacenter - x64 Gen1"
#
# Multi-version CSV (mixed targets in one run):
#   .\Invoke-WindowsServer2025-InPlaceUpgrade.ps1 -CsvPath .\vms-to-upgrade.csv -Parallel
#   # CSV example rows:
#   # rg-prod,VM01,swedencentral,Windows Server 2022 Datacenter - x64 Gen2,server2022Upgrade,
#   # rg-prod,VM02,swedencentral,Windows Server 2019 Datacenter - x64 Gen1,server2019Upgrade,
#   # rg-prod,VM03,swedencentral,Windows Server 2025 Datacenter - x64 Gen2,server2025Upgrade,
#
# UPGRADE PATH QUICK REFERENCE
# -----------------------------
#   WS 2008 / 2008 R2  →  2012
#   WS 2012            →  2016
#   WS 2012 R2         →  2016, 2019, 2025
#   WS 2016            →  2019, 2022, 2025
#   WS 2019            →  2022, 2025
#   WS 2022            →  2025
# ==============================================================================

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'SingleVM')]
param (
    # --- Single-VM mode ---
    [Parameter(ParameterSetName = 'SingleVM', Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(ParameterSetName = 'SingleVM', Mandatory = $true)]
    [string]$VMName,

    # --- Multi-VM mode (CSV) ---
    # Required CSV columns: ResourceGroupName, VMName, Region, TargetSKU, UpgradeMediaSku
    # Optional CSV column : UpgradeDiskName
    [Parameter(ParameterSetName = 'MultiVM', Mandatory = $true)]
    [string]$CsvPath,

    # --- Shared parameters ---
    [Parameter(Mandatory = $false)]
    [string]$Region = "swedencentral",

    [Parameter(Mandatory = $false)]
    [string]$TargetSKU = "Windows Server 2025 Datacenter - x64 Gen2",

    # Azure Marketplace upgrade media SKU — auto-derived from TargetSKU if left empty.
    # Override if needed: server2012Upgrade | server2016Upgrade | server2019Upgrade | server2022Upgrade | server2025Upgrade
    [Parameter(Mandatory = $false)]
    [string]$UpgradeMediaSku = "",

    # Name for the upgrade media managed disk (created in $ResourceGroupName)
    [Parameter(Mandatory = $false)]
    [string]$UpgradeDiskName = "",

    # --- Multi-VM orchestration options ---
    # -Parallel requires PowerShell 7+
    [Parameter(ParameterSetName = 'MultiVM')]
    [switch]$Parallel,

    [Parameter(ParameterSetName = 'MultiVM')]
    [ValidateRange(1, 10)]
    [int]$ThrottleLimit = 3
)

# --- Logging ---
$LogTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
# In MultiVM mode $VMName is empty; use 'MultiVM-Orchestrator' as placeholder.
$LogFile = Join-Path $PSScriptRoot "WS2025-Upgrade_$(if ($VMName) { $VMName } else { 'MultiVM-Orchestrator' })_${LogTimestamp}.log"

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Entry = "[$Timestamp] [$Level] $Message"
    Write-Host $Entry -ForegroundColor $(switch ($Level) {
        "INFO"    { "Cyan" }
        "SUCCESS" { "Green" }
        "WARNING" { "Yellow" }
        "ERROR"   { "Red" }
        default   { "White" }
    })
    Add-Content -Path $LogFile -Value $Entry -WhatIf:$false -Confirm:$false
}

# ==============================================================================
# Multi-VM CSV Orchestration
# When -CsvPath is supplied each VM is upgraded in its own pwsh child process.
# This keeps exit codes isolated — no fragile patching of exit statements needed.
# ==============================================================================
if ($PSCmdlet.ParameterSetName -eq 'MultiVM') {

    $RequiredCsvColumns = @('ResourceGroupName', 'VMName', 'Region', 'TargetSKU', 'UpgradeMediaSku')

    if (-not (Test-Path $CsvPath)) {
        Write-Log "CSV file not found: $CsvPath" "ERROR"
        exit 1
    }

    $VMList = Import-Csv $CsvPath
    if (-not $VMList) {
        Write-Log "No records found in CSV: $CsvPath" "ERROR"
        exit 1
    }

    foreach ($Col in $RequiredCsvColumns) {
        if ($VMList[0].PSObject.Properties.Name -notcontains $Col) {
            Write-Log "CSV is missing required column: '$Col'" "ERROR"
            exit 1
        }
    }

    if ($Parallel -and $PSVersionTable.PSVersion.Major -lt 7) {
        Write-Log "-Parallel requires PowerShell 7+. Current: $($PSVersionTable.PSVersion). Falling back to sequential." "WARNING"
        $Parallel = $false
    }

    $ReportDir    = Join-Path $PSScriptRoot "Reports"
    New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
    $RunTs        = Get-Date -Format "yyyyMMdd_HHmmss"
    $ResultFile   = Join-Path $ReportDir "UpgradeResults_$RunTs.csv"
    $FailedFile   = Join-Path $ReportDir "Failed_$RunTs.txt"
    $PwshExe      = if ($PSVersionTable.PSVersion.Major -ge 7) { "pwsh" } else { "powershell" }

    Write-Log "Multi-VM mode: $($VMList.Count) VM(s) from '$CsvPath'  |  Parallel=$Parallel  |  Throttle=$ThrottleLimit" "INFO"
    Write-Log "Results file: $ResultFile" "INFO"

    # Build the argument list for one VM child process
    function New-VMUpgradeProcess {
        param($VMRow)
        $Args = @(
            "-NonInteractive", "-NoProfile",
            "-File", "`"$PSCommandPath`"",
            "-ResourceGroupName", $VMRow.ResourceGroupName,
            "-VMName",            $VMRow.VMName,
            "-Region",            $VMRow.Region,
            "-TargetSKU",         $VMRow.TargetSKU,
            "-UpgradeMediaSku",   $VMRow.UpgradeMediaSku
        )
        if ($VMRow.PSObject.Properties.Name -contains 'UpgradeDiskName' -and
            -not [string]::IsNullOrEmpty($VMRow.UpgradeDiskName)) {
            $Args += @("-UpgradeDiskName", $VMRow.UpgradeDiskName)
        }
        if ($WhatIfPreference) { $Args += "-WhatIf" }
        Start-Process -FilePath $PwshExe -ArgumentList $Args -PassThru -NoNewWindow
    }

    $Results = @()

    if ($Parallel) {
        Write-Log "Starting parallel processing (ThrottleLimit=$ThrottleLimit)..." "INFO"
        $Queue   = [System.Collections.Generic.Queue[object]]($VMList)
        $Running = @{}   # PID → { VM; Process }

        while ($Queue.Count -gt 0 -or $Running.Count -gt 0) {

            # Fill up to ThrottleLimit
            while ($Queue.Count -gt 0 -and $Running.Count -lt $ThrottleLimit) {
                $Row  = $Queue.Dequeue()
                $Proc = New-VMUpgradeProcess -VMRow $Row
                $Running[$Proc.Id] = [pscustomobject]@{ VM = $Row; Process = $Proc }
                Write-Log "Launched: $($Row.VMName)  (PID $($Proc.Id))" "INFO"
            }

            # Collect finished processes
            foreach ($Entry in @($Running.Values | Where-Object { $_.Process.HasExited })) {
                $St = if ($Entry.Process.ExitCode -eq 0) { "Success" } else { "Failed" }
                Write-Log "Finished: $($Entry.VM.VMName) — $St  (exit $($Entry.Process.ExitCode))" $(if ($St -eq 'Success') { 'SUCCESS' } else { 'ERROR' })
                $Results += [pscustomobject]@{
                    ResourceGroupName = $Entry.VM.ResourceGroupName
                    VMName            = $Entry.VM.VMName
                    Status            = $St
                    ExitCode          = $Entry.Process.ExitCode
                    CompletedAt       = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                }
                $Running.Remove($Entry.Process.Id)
            }

            if ($Running.Count -gt 0) { Start-Sleep -Seconds 5 }
        }
    }
    else {
        foreach ($Row in $VMList) {
            Write-Log "--- Starting: $($Row.VMName)  (RG: $($Row.ResourceGroupName)) ---" "INFO"
            $Proc = New-VMUpgradeProcess -VMRow $Row
            $Proc.WaitForExit()
            $St = if ($Proc.ExitCode -eq 0) { "Success" } else { "Failed" }
            Write-Log "Completed: $($Row.VMName) — $St  (exit $($Proc.ExitCode))" $(if ($St -eq 'Success') { 'SUCCESS' } else { 'ERROR' })
            $Results += [pscustomobject]@{
                ResourceGroupName = $Row.ResourceGroupName
                VMName            = $Row.VMName
                Status            = $St
                ExitCode          = $Proc.ExitCode
                CompletedAt       = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            }
        }
    }

    $Results | Export-Csv $ResultFile -NoTypeInformation
    $FailedVMs = $Results | Where-Object Status -eq "Failed" | Select-Object -ExpandProperty VMName
    if ($FailedVMs) { $FailedVMs | Set-Content $FailedFile }

    $OK  = ($Results | Where-Object Status -eq "Success").Count
    $Err = ($Results | Where-Object Status -eq "Failed").Count

    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "  Multi-VM Upgrade Summary"           -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "  Total      : $($Results.Count)"
    Write-Host "  Successful : $OK"  -ForegroundColor $(if ($OK  -gt 0) { "Green"  } else { "White" })
    Write-Host "  Failed     : $Err" -ForegroundColor $(if ($Err -gt 0) { "Red"    } else { "White" })
    Write-Host "  Results    : $ResultFile"
    if ($Err -gt 0) { Write-Host "  Failed VMs : $FailedFile" -ForegroundColor Yellow }
    Write-Host "======================================" -ForegroundColor Cyan

    exit $(if ($Err -gt 0) { 1 } else { 0 })
}

# ==============================================================================
# Single-VM mode continues below
# ==============================================================================

# --- Resolve UpgradeMediaSku from TargetSKU (auto-derivation) ---
# Ordered so longer year strings are matched before shorter ones (2012 R2 before 2012).
if ([string]::IsNullOrEmpty($UpgradeMediaSku)) {
    $MediaSkuByVersion = [ordered]@{
        '2025' = 'server2025Upgrade'
        '2022' = 'server2022Upgrade'
        '2019' = 'server2019Upgrade'
        '2016' = 'server2016Upgrade'
        '2012' = 'server2012Upgrade'
    }
    foreach ($Ver in $MediaSkuByVersion.Keys) {
        if ($TargetSKU -match $Ver) {
            $UpgradeMediaSku = $MediaSkuByVersion[$Ver]
            break
        }
    }
    if ([string]::IsNullOrEmpty($UpgradeMediaSku)) {
        Write-Log "Cannot auto-derive UpgradeMediaSku from TargetSKU '$TargetSKU'." "ERROR"
        Write-Log "Specify -UpgradeMediaSku explicitly: server2012Upgrade, server2016Upgrade, server2019Upgrade, server2022Upgrade, or server2025Upgrade" "ERROR"
        exit 1
    }
    Write-Log "UpgradeMediaSku auto-derived from TargetSKU: $UpgradeMediaSku" "INFO"
}

# --- Step 1: Pre-Upgrade Validation ---
Write-Log "======================================================" "INFO"
Write-Log "Starting Pre-Upgrade Validation for VM: $VMName" "INFO"
Write-Log "Resource Group : $ResourceGroupName" "INFO"
Write-Log "Region         : $Region" "INFO"
Write-Log "Target SKU     : $TargetSKU" "INFO"
Write-Log "Upgrade Media  : $UpgradeMediaSku" "INFO"
Write-Log "======================================================" "INFO"

# Check if VM exists
$VM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status -ErrorAction SilentlyContinue

if (-not $VM) {
    Write-Log "VM '$VMName' not found in Resource Group '$ResourceGroupName'." "ERROR"
    exit 1
}

$PowerState = ($VM.Statuses | Where-Object { $_.Code -match "PowerState" }).DisplayStatus

if ($PowerState -ne "VM running") {
    Write-Log "VM is not running (current: $PowerState). Starting VM..." "WARNING"
    Start-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop | Out-Null
    $StartWait = 0
    $StartMax  = 300  # 5 minutes
    do {
        Start-Sleep -Seconds 20
        $StartWait += 20
        $VM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status -ErrorAction SilentlyContinue
        $PowerState = ($VM.Statuses | Where-Object { $_.Code -match "PowerState" }).DisplayStatus
        Write-Log "Waiting for VM to start ($StartWait s)... state: $PowerState" "INFO"
    } while ($PowerState -ne "VM running" -and $StartWait -lt $StartMax)

    if ($PowerState -ne "VM running") {
        Write-Log "VM did not reach 'running' state within $StartMax seconds. Aborting." "ERROR"
        exit 1
    }
}

Write-Log "VM Power State : $PowerState" "SUCCESS"

# Validate source OS and upgrade path
$VMSourceCheck = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction SilentlyContinue
$SourceOsSku   = $VMSourceCheck.StorageProfile.ImageReference.Sku
Write-Log "Detected source OS image SKU: $(if ([string]::IsNullOrEmpty($SourceOsSku)) { '(unavailable - custom image)' } else { $SourceOsSku })" "INFO"

if (-not [string]::IsNullOrEmpty($SourceOsSku) -and $SourceOsSku -notmatch '20\d\d') {
    Write-Log "Source OS SKU '$SourceOsSku' does not appear to be a Windows Server SKU. Verify before proceeding." "WARNING"
}

# --- Upgrade path compatibility validation ---
# Source: https://learn.microsoft.com/en-us/azure/virtual-machines/windows-in-place-upgrade
# Keys use regex patterns; ordered longest-first to prevent '2012' matching '2012 R2' SKUs.
$UpgradeCompatMatrix = [ordered]@{
    '2008.R2' = @{ Label = 'WS 2008 R2'; AllowedTargets = @('2012') }
    '2008'    = @{ Label = 'WS 2008';    AllowedTargets = @('2012') }
    '2012.R2' = @{ Label = 'WS 2012 R2'; AllowedTargets = @('2016','2019','2025') }
    '2012'    = @{ Label = 'WS 2012';    AllowedTargets = @('2016') }
    '2016'    = @{ Label = 'WS 2016';    AllowedTargets = @('2019','2022','2025') }
    '2019'    = @{ Label = 'WS 2019';    AllowedTargets = @('2022','2025') }
    '2022'    = @{ Label = 'WS 2022';    AllowedTargets = @('2025') }
}

$TargetVersionMatch = [regex]::Match($TargetSKU, '20\d\d')
$TargetVersion      = if ($TargetVersionMatch.Success) { $TargetVersionMatch.Value } else { $null }

if (-not [string]::IsNullOrEmpty($SourceOsSku) -and $TargetVersion) {
    $MatchedEntry = $null
    foreach ($Pattern in $UpgradeCompatMatrix.Keys) {
        if ($SourceOsSku -match $Pattern) {
            $MatchedEntry = $UpgradeCompatMatrix[$Pattern]
            break
        }
    }

    if ($MatchedEntry) {
        if ($MatchedEntry.AllowedTargets -contains $TargetVersion) {
            Write-Log "Upgrade path: $($MatchedEntry.Label) → WS $TargetVersion  [SUPPORTED]" "SUCCESS"
        } else {
            Write-Log "Upgrade path: $($MatchedEntry.Label) → WS $TargetVersion is NOT a supported direct upgrade." "WARNING"
            Write-Log "Supported target(s) from $($MatchedEntry.Label): WS $($MatchedEntry.AllowedTargets -join ' / WS ')" "WARNING"
            Write-Log "Reference: https://learn.microsoft.com/en-us/azure/virtual-machines/windows-in-place-upgrade" "WARNING"
        }
    } else {
        Write-Log "Source OS not found in upgrade compatibility matrix for SKU '$SourceOsSku'. Path validation skipped." "WARNING"
    }
} elseif ([string]::IsNullOrEmpty($SourceOsSku)) {
    Write-Log "Source OS SKU unavailable (custom/captured image). Upgrade path validation skipped." "WARNING"
}

# --- Gen1/Gen2 detection and TargetSKU auto-correction ---
$VMGen = $VMSourceCheck.HyperVGeneration   # "V1" or "V2"
Write-Log "VM Generation  : $VMGen" "INFO"

if ($VMGen -eq 'V1' -and $TargetSKU -match 'Gen2') {
    $CorrectedSKU = $TargetSKU -replace 'Gen2', 'Gen1'
    Write-Log "VM is Gen1 but TargetSKU references Gen2. Auto-correcting: '$TargetSKU' → '$CorrectedSKU'" "WARNING"
    $TargetSKU = $CorrectedSKU
} elseif ($VMGen -eq 'V2' -and $TargetSKU -match 'Gen1') {
    $CorrectedSKU = $TargetSKU -replace 'Gen1', 'Gen2'
    Write-Log "VM is Gen2 but TargetSKU references Gen1. Auto-correcting: '$TargetSKU' → '$CorrectedSKU'" "WARNING"
    $TargetSKU = $CorrectedSKU
}
Write-Log "Effective TargetSKU: $TargetSKU" "INFO"

# --- Trusted Launch advisory ---
$SecurityType = $VMSourceCheck.SecurityProfile.SecurityType
Write-Log "VM Security Type : $(if ($SecurityType) { $SecurityType } else { 'Standard (not set)' })" "INFO"
if ([string]::IsNullOrEmpty($SecurityType) -or $SecurityType -eq 'Standard') {
    Write-Log "Advisory: This VM uses Standard security. Consider upgrading to Azure Trusted Launch for enhanced protection." "WARNING"
    Write-Log "Trusted Launch info : https://aka.ms/TrustedLaunch" "WARNING"
    Write-Log "Note: Trusted Launch upgrade is independent of this OS in-place upgrade." "WARNING"
}

# --- Step 1b: OS Upgrade Assessment Validation ---
# Runs Microsoft's OS Upgrade Assessment tool inside the VM via Run Command BEFORE taking
# snapshots or attaching media, so blocking issues are caught early at zero cost.
# Source: https://github.com/Azure/azure-support-scripts/tree/master/RunCommand/Windows/Windows_OSUpgrade_Assessment_Validation
Write-Log "======================================================" "INFO"
Write-Log "Step 1b: Running OS Upgrade Assessment Validation inside VM..." "INFO"
Write-Log "======================================================" "INFO"

# Single-quote here-string: no variable expansion — content is literal PowerShell executed inside the VM.
$AssessmentScript = @'
function Get-AzureSecurityProfile {
    try {
        $meta = Invoke-RestMethod `
            -Uri    "http://169.254.169.254/metadata/instance/compute?api-version=2023-07-01" `
            -Headers @{Metadata = 'true'} `
            -Method Get `
            -UseBasicParsing
        return $meta.securityProfile
    } catch {
        return $null
    }
}

$windowsProductName = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').ProductName
$isServer           = $windowsProductName -like "Windows Server*"

$serverUpgradeMatrix = @{
    'Windows Server 2008'                          = 'Windows Server 2012'
    'Windows Server 2008 R2'                       = 'Windows Server 2012'
    'Windows Server 2012'                          = 'Windows Server 2016'
    'Windows Server 2012 R2'                       = 'Windows Server 2016, Windows Server 2019, or Windows Server 2025'
    'Windows Server 2016'                          = 'Windows Server 2019, Windows Server 2022, or Windows Server 2025'
    'Windows Server 2019'                          = 'Windows Server 2022 or Windows Server 2025'
    'Windows Server 2022'                          = 'Windows Server 2025'
    'Windows Server 2025'                          = 'No direct upgrade path. Consider redeploying a new VM.'
    'Windows Server 2022 Datacenter Azure Edition' = 'No direct upgrade path. Consider redeploying a new VM.'
    'Windows Server 2025 Datacenter Azure Edition' = 'No direct upgrade path. Consider redeploying a new VM.'
}

# --- Hardware checks ---
$drive             = Get-PSDrive -Name C
$totalMemoryBytes  = (Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory
$totalMemoryGB     = [math]::Round($totalMemoryBytes / 1GB, 2)
$diskFreeGB        = [math]::Round($drive.Free / 1GB, 2)
$diskCheckFailed   = $drive.Free -lt 64GB
$memoryCheckFailed = $totalMemoryGB -lt 4

# --- Checklist ---
$checklist  = @()
$checklist += "Windows Version: $windowsProductName"
$checklist += ""

if (-not $diskCheckFailed) {
    $checklist += "[Passed] Disk Space        (Free: $diskFreeGB GB)"
} else {
    $checklist += "[Failed] Disk Space        (Free: $diskFreeGB GB; Required: >= 64 GB)"
}

if (-not $memoryCheckFailed) {
    $checklist += "[Passed] Physical Memory   (Total: $totalMemoryGB GB)"
} else {
    $checklist += "[Failed] Physical Memory   (Total: $totalMemoryGB GB; Required: >= 4 GB)"
}

# --- Messages ---
$messages = @()

if ($isServer) {
    if (-not $diskCheckFailed -and -not $memoryCheckFailed) {
        foreach ($serverVersion in $serverUpgradeMatrix.Keys) {
            if ($windowsProductName -like "$serverVersion*") {
                $messages += ""
                $messages += "Upgrade path for '$windowsProductName':"
                $messages += "  Supported targets : $($serverUpgradeMatrix[$serverVersion])"
                $messages += "  Reference         : https://learn.microsoft.com/en-us/azure/virtual-machines/windows-in-place-upgrade"
                break
            }
        }
        if ($messages.Count -eq 0) {
            $messages += ""
            $messages += "[Failed] Current OS '$windowsProductName' was not found in the supported upgrade matrix."
        }
    } else {
        if ($diskCheckFailed)   { $messages += "[Failed] Resolve disk space issue before upgrading." }
        if ($memoryCheckFailed) { $messages += "[Failed] Resolve memory issue before upgrading." }
    }
} else {
    $messages += ""
    $messages += "INFO: Non-server OS detected ('$windowsProductName'). Server upgrade checks skipped."
}

# --- AVD detection ---
if ($windowsProductName -match 'Virtual Desktop' -or $windowsProductName -match 'multi-session') {
    $messages += ""
    $messages += "[Failed] AVD pooled host pool session hosts are NOT supported for in-place upgrade."
    $messages += "         Personal host pool session hosts ARE supported."
}

# --- Output ---
$checklist | ForEach-Object { Write-Output $_ }
$messages  | ForEach-Object { Write-Output $_ }
Write-Output ""
Write-Output "Full assessment reference: https://aka.ms/AzVmOSUpgradeAssessment"
'@

try {
    if ($PSCmdlet.ShouldProcess("$VMName", "Run OS Upgrade Assessment Validation (Step 1b)")) {
        $AssessResult = Invoke-AzVMRunCommand `
            -ResourceGroupName $ResourceGroupName `
            -VMName            $VMName `
            -CommandId         "RunPowerShellScript" `
            -ScriptString      $AssessmentScript `
            -ErrorAction       Stop

        $AssessOutput = ($AssessResult.Value | Where-Object { $_.Code -match 'StdOut' }).Message
        $AssessErrors = ($AssessResult.Value | Where-Object { $_.Code -match 'StdErr' }).Message

        if (![string]::IsNullOrWhiteSpace($AssessErrors)) {
            Write-Log "Assessment RunCommand stderr: $AssessErrors" "WARNING"
        }

        if (![string]::IsNullOrWhiteSpace($AssessOutput)) {
            Write-Log "--- Assessment Results ---" "INFO"
            ($AssessOutput -split "`r?`n") | ForEach-Object {
                $Line = $_.Trim()
                if ($Line -ne '') { Write-Log $Line "INFO" }
            }
            Write-Log "--- End Assessment -------" "INFO"
        }

        # Any [Failed] item is a potential blocker — require explicit user confirmation
        $FailedChecks = ($AssessOutput -split "`r?`n") | Where-Object { $_ -match '\[Failed\]' }
        if ($FailedChecks.Count -gt 0) {
            Write-Log "$($FailedChecks.Count) failed assessment check(s) detected:" "WARNING"
            $FailedChecks | ForEach-Object { Write-Log "  >> $($_.Trim())" "WARNING" }

            if ($WhatIfPreference) {
                Write-Log "[-WhatIf] Skipping abort prompt — simulating continuation past failed checks." "INFO"
            } else {
                $ProceedAfterAssess = Read-Host "Assessment check(s) failed (see above). Proceed with upgrade anyway? (Y/N)"
                if ($ProceedAfterAssess -notin @("Y", "y")) {
                    Write-Log "Upgrade aborted by user after failed assessment." "WARNING"
                    exit 0
                }
                Write-Log "User confirmed continuation despite failed assessment check(s)." "WARNING"
            }
        } else {
            Write-Log "OS Upgrade Assessment passed — no blocking issues found." "SUCCESS"
        }
    }
} catch {
    Write-Log "OS Upgrade Assessment RunCommand failed. Proceeding without assessment." "WARNING"
    Write-Log "Error: $($_.Exception.Message)" "WARNING"
    Write-Log "You can run the assessment manually: https://aka.ms/AzVmOSUpgradeAssessment" "WARNING"
}

# --- Step 2: Verify SKU Availability ---
# Maps full TargetSKU display name → Azure image catalog SKU identifier for region availability check.
# If the exact key is not found the TargetSKU string itself is used as a fallback.
$ImageSkuMap = @{
    # WS 2012 (Gen1 only)
    "Windows Server 2012 Datacenter"                           = "2012-Datacenter"
    # WS 2012 R2 (Gen1 only)
    "Windows Server 2012 R2 Datacenter"                        = "2012-R2-Datacenter"
    # WS 2016
    "Windows Server 2016 Datacenter - x64 Gen2"                = "2016-datacenter-gensecond"
    "Windows Server 2016 Datacenter - x64 Gen1"                = "2016-datacenter"
    "Windows Server 2016 Datacenter"                           = "2016-datacenter"
    # WS 2019
    "Windows Server 2019 Datacenter - x64 Gen2"                = "2019-datacenter-gensecond"
    "Windows Server 2019 Datacenter - x64 Gen1"                = "2019-datacenter"
    "Windows Server 2019 Datacenter"                           = "2019-datacenter"
    # WS 2022
    "Windows Server 2022 Datacenter - x64 Gen2"                = "2022-datacenter-g2"
    "Windows Server 2022 Datacenter - x64 Gen1"                = "2022-datacenter"
    "Windows Server 2022 Datacenter"                           = "2022-datacenter"
    # WS 2025
    "Windows Server 2025 Datacenter - x64 Gen2"                = "2025-datacenter-g2"
    "Windows Server 2025 Datacenter - x64 Gen1"                = "2025-datacenter"
    "Windows Server 2025 Datacenter"                           = "2025-datacenter"
    "Windows Server 2025 Datacenter Azure Edition - x64 Gen2" = "2025-datacenter-azure-edition"
}

$ImageSku = $ImageSkuMap[$TargetSKU]
if ([string]::IsNullOrEmpty($ImageSku)) {
    $ImageSku = $TargetSKU
}

Write-Log "Checking if SKU '$ImageSku' is available in region '$Region'..." "INFO"

$SkuFound = az vm image list-skus `
    --publisher MicrosoftWindowsServer `
    --offer WindowsServer `
    --location $Region `
    --query "[?name=='$ImageSku'].name" -o tsv 2>$null

if ([string]::IsNullOrEmpty($SkuFound)) {
    Write-Log "Image SKU '$ImageSku' was not found in region '$Region' via list-skus." "WARNING"
    Write-Log "The 'az vm update --upgrade' command may still succeed for in-place upgrades." "WARNING"
    Write-Log "Fallback: attach the WS2025 ISO as a data disk and run setup.exe via RDP." "WARNING"

    if ($WhatIfPreference) {
        Write-Log "[-WhatIf] Skipping confirmation prompt and continuing simulation." "INFO"
    } else {
        $Confirm = Read-Host "Proceed with CLI upgrade attempt anyway? (Y/N)"
        if ($Confirm -notin @("Y", "y")) {
            Write-Log "Script aborted by user." "WARNING"
            exit 0
        }
    }
} else {
    Write-Log "SKU '$SkuFound' confirmed available in region '$Region'." "SUCCESS"
}

# --- Step 3: Take Snapshots of OS and Data Disks (Rollback Safety) ---
Write-Log "======================================================" "INFO"
Write-Log "Creating pre-upgrade snapshots of the VM disks..." "INFO"
Write-Log "======================================================" "INFO"

try {
    $VMConfig = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop

    # Build the list of disks to snapshot (OS disk + all data disks)
    $DisksToSnapshot = @()

    $OsDiskId = $VMConfig.StorageProfile.OsDisk.ManagedDisk.Id
    if ([string]::IsNullOrEmpty($OsDiskId)) {
        Write-Log "Could not resolve the managed OS disk ID. Unmanaged disks are not supported for snapshotting here." "ERROR"
        exit 1
    }
    $DisksToSnapshot += [pscustomobject]@{
        Type   = "OS"
        Name   = $VMConfig.StorageProfile.OsDisk.Name
        DiskId = $OsDiskId
    }

    foreach ($DataDisk in $VMConfig.StorageProfile.DataDisks) {
        $DataDiskId = $DataDisk.ManagedDisk.Id
        if ([string]::IsNullOrEmpty($DataDiskId)) {
            Write-Log "Data disk '$($DataDisk.Name)' (LUN $($DataDisk.Lun)) is unmanaged and cannot be snapshotted. Aborting." "ERROR"
            exit 1
        }
        $DisksToSnapshot += [pscustomobject]@{
            Type   = "Data (LUN $($DataDisk.Lun))"
            Name   = $DataDisk.Name
            DiskId = $DataDiskId
        }
    }

    Write-Log "Disks to snapshot: $($DisksToSnapshot.Count) (1 OS + $($VMConfig.StorageProfile.DataDisks.Count) data)" "INFO"

    # Snapshot timestamp without underscore (Azure name rules: letters, digits, hyphens, underscores; max 80 chars)
    $SnapTimestamp = Get-Date -Format "yyyyMMddHHmmss"

    foreach ($Disk in $DisksToSnapshot) {
        # Build name, replace any char that is not letter/digit/hyphen/underscore, then truncate to 80 chars
        $RawName      = "$($Disk.Name)-pre-$SnapTimestamp"
        $SafeName     = $RawName -replace '[^a-zA-Z0-9\-_]', '-'
        $SnapshotName = if ($SafeName.Length -gt 80) { $SafeName.Substring(0, 80).TrimEnd('-') } else { $SafeName }

        Write-Log "[$($Disk.Type)] Disk ID       : $($Disk.DiskId)" "INFO"
        Write-Log "[$($Disk.Type)] Snapshot Name : $SnapshotName" "INFO"

        if ($PSCmdlet.ShouldProcess("$SnapshotName", "Create snapshot of $($Disk.Type) disk")) {
            $SnapshotConfig = New-AzSnapshotConfig `
                -SourceUri $Disk.DiskId `
                -Location $Region `
                -CreateOption Copy

            $Snapshot = New-AzSnapshot `
                -ResourceGroupName $ResourceGroupName `
                -SnapshotName $SnapshotName `
                -Snapshot $SnapshotConfig `
                -ErrorAction Stop

            Write-Log "[$($Disk.Type)] Snapshot created successfully: $($Snapshot.Name)" "SUCCESS"
        }
    }

    Write-Log "All pre-upgrade snapshots created. Use them to restore the VM if the upgrade fails." "INFO"
} catch {
    Write-Log "Failed to create pre-upgrade snapshots." "ERROR"
    Write-Log "Error: $($_.Exception.Message)" "ERROR"
    Write-Log "Aborting upgrade because rollback snapshots are incomplete." "ERROR"
    exit 1
}

# --- Step 4: Create and Attach Upgrade Media Disk ---
# The correct upgrade method per Microsoft docs:
# https://learn.microsoft.com/en-us/azure/virtual-machines/windows-in-place-upgrade
# Uses a hidden Marketplace offer (WindowsServerUpgrade) to create a managed upgrade media disk,
# attaches it to the VM, then triggers setup.exe via Run Command.
Write-Log "======================================================" "INFO"
Write-Log "Step 4a: Creating upgrade media disk from Azure Marketplace..." "INFO"
Write-Log "Upgrade Media SKU : $UpgradeMediaSku" "INFO"
Write-Log "======================================================" "INFO"

# Resolve upgrade disk name
if ([string]::IsNullOrEmpty($UpgradeDiskName)) {
    $SnapTimestampDisk = Get-Date -Format "yyyyMMddHHmmss"
    $UpgradeDiskName  = "$VMName-upgmedia-$SnapTimestampDisk"
    $CleanDiskName    = $UpgradeDiskName -replace '[^a-zA-Z0-9\-_]', '-'
    $UpgradeDiskName  = $CleanDiskName.Substring(0, [Math]::Min(80, $CleanDiskName.Length)).TrimEnd('-')
}

try {
    # Get the latest version of the upgrade media image from the hidden Marketplace offer
    $UpgradeImages = Get-AzVMImage `
        -PublisherName "MicrosoftWindowsServer" `
        -Location $Region `
        -Offer "WindowsServerUpgrade" `
        -Skus $UpgradeMediaSku `
        -ErrorAction Stop | Sort-Object -Descending {
            # Pad each version component to ensure correct numeric ordering for large Azure build numbers
            ($_.Version -split '\.' | ForEach-Object { $_.PadLeft(10, '0') }) -join '.'
        }

    if (-not $UpgradeImages) {
        Write-Log "No upgrade media images found for SKU '$UpgradeMediaSku' in '$Region'." "ERROR"
        exit 1
    }

    $LatestVersion = $UpgradeImages[0].Version
    Write-Log "Latest upgrade media version : $LatestVersion" "INFO"

    $UpgradeImage = Get-AzVMImage `
        -Location $Region `
        -PublisherName "MicrosoftWindowsServer" `
        -Offer "WindowsServerUpgrade" `
        -Skus $UpgradeMediaSku `
        -Version $LatestVersion `
        -ErrorAction Stop

    Write-Log "Upgrade Disk Name : $UpgradeDiskName" "INFO"

    if ($PSCmdlet.ShouldProcess("$UpgradeDiskName", "Create upgrade media managed disk")) {
        $DiskConfig = New-AzDiskConfig `
            -SkuName "Standard_LRS" `
            -CreateOption FromImage `
            -Location $Region

        $DiskConfig = Set-AzDiskImageReference -Disk $DiskConfig -Id $UpgradeImage.Id -Lun 0

        $UpgradeDisk = New-AzDisk `
            -ResourceGroupName $ResourceGroupName `
            -DiskName $UpgradeDiskName `
            -Disk $DiskConfig `
            -ErrorAction Stop

        Write-Log "Upgrade media disk created: $($UpgradeDisk.Name)" "SUCCESS"
    }
} catch {
    Write-Log "Failed to create upgrade media disk." "ERROR"
    Write-Log "Error: $($_.Exception.Message)" "ERROR"
    exit 1
}

if (-not $UpgradeDisk -and -not $WhatIfPreference) {
    Write-Log "Upgrade disk object is null after creation step. Cannot continue." "ERROR"
    exit 1
}

# --- Step 4b: Attach Upgrade Media Disk to VM ---
Write-Log "Step 4b: Attaching upgrade media disk to VM..." "INFO"

try {
    # ----- Data disk capacity check -----
    # The attach will fail if the VM size's MaxDataDiskCount is already reached.
    $VMConfig4b   = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop
    $VMSizeInfo   = Get-AzVMSize -Location $Region | Where-Object { $_.Name -eq $VMConfig4b.HardwareProfile.VmSize }
    $MaxDataDisks = $VMSizeInfo.MaxDataDiskCount
    $UsedDisks    = $VMConfig4b.StorageProfile.DataDisks.Count
    Write-Log "VM size '$($VMConfig4b.HardwareProfile.VmSize)': $UsedDisks / $MaxDataDisks data disks in use." "INFO"

    if (($UsedDisks + 1) -gt $MaxDataDisks) {
        Write-Log "Cannot attach upgrade media disk. VM size allows $MaxDataDisks data disks; all $UsedDisks slots are occupied." "ERROR"
        Write-Log "Remediation: detach an unused data disk first, or resize the VM to a SKU with more data disk slots." "ERROR"
        exit 1
    }

    # Find the next free LUN
    $UsedLuns = $VMConfig4b.StorageProfile.DataDisks | Select-Object -ExpandProperty Lun
    $NextLun  = 0
    while ($UsedLuns -contains $NextLun) { $NextLun++ }

    if ($PSCmdlet.ShouldProcess("$VMName", "Attach upgrade media disk '$UpgradeDiskName' at LUN $NextLun")) {
        # Use 'az vm disk attach' (PATCH) rather than Add-AzVMDataDisk + Update-AzVM (PUT).
        # The PUT-based approach fails with HTTP 409 "Changing property 'osProfile' is not allowed"
        # on VMs cloned from captured or generalized images (e.g. SCCM/MDT builds, Azure Image Builder).
        Write-Log "Attaching via 'az vm disk attach' (PATCH) to avoid osProfile conflict on cloned VMs..." "INFO"

        $AttachOut = az vm disk attach `
            --resource-group $ResourceGroupName `
            --vm-name        $VMName `
            --name           $UpgradeDiskName `
            --lun            $NextLun 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "az vm disk attach failed (exit $LASTEXITCODE): $AttachOut"
        }

        Write-Log "Upgrade media disk attached at LUN $NextLun." "SUCCESS"
    }
} catch {
    Write-Log "Failed to attach upgrade media disk." "ERROR"
    Write-Log "Error: $($_.Exception.Message)" "ERROR"
    exit 1
}

# --- Step 4c: Trigger In-Place Upgrade via Run Command ---
# Searches all non-C: fixed drives recursively for setup.exe (handles subfolder structure
# e.g. F:\Windows Server 2025\setup.exe).
# /imageindex 3 = Server Core (no GUI); /imageindex 4 = Desktop Experience
$ImageIndex = if ($TargetSKU -match 'Core') { 3 } else { 4 }
Write-Log "Step 4c: Triggering setup.exe inside the VM via Run Command..." "INFO"
Write-Log "Using /imageindex $ImageIndex ($(if ($ImageIndex -eq 3) {'Server Core'} else {'Desktop Experience'}))" "INFO"
Write-Log "The VM will reboot automatically. This process typically takes 30-90 minutes." "WARNING"
Write-Log "DO NOT stop the VM manually during this process." "WARNING"

# setup.exe is launched with -NoNewWindow (fire-and-forget) so RunCommand returns immediately.
# Upgrade progress is monitored via the Step 5 polling loop, avoiding RunCommand API timeout.
$UpgradeScript = @"
`$SetupPath = Get-ChildItem -Path (
    [System.IO.DriveInfo]::GetDrives() |
    Where-Object { `$_.DriveType -eq "Fixed" -and `$_.Name -ne "C:\" } |
    Select-Object -ExpandProperty Name
) -Filter "setup.exe" -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName

if (-not `$SetupPath) {
    throw "setup.exe not found on any non-C: drive. Ensure the upgrade media disk is attached."
}

Write-Output "Found setup.exe at: `$SetupPath"
Start-Process -FilePath `$SetupPath -ArgumentList "/auto upgrade /dynamicupdate disable /eula accept /imageindex $ImageIndex" -NoNewWindow
"@

try {
    if ($PSCmdlet.ShouldProcess("$VMName", "Run setup.exe upgrade via Invoke-AzVMRunCommand")) {
        $RunResult = Invoke-AzVMRunCommand `
            -ResourceGroupName $ResourceGroupName `
            -VMName $VMName `
            -CommandId "RunPowerShellScript" `
            -ScriptString $UpgradeScript `
            -ErrorAction Stop

        $Output = ($RunResult.Value | Where-Object { $_.Code -match 'StdOut' }).Message
        $ErrOut = ($RunResult.Value | Where-Object { $_.Code -match 'StdErr' }).Message

        if (![string]::IsNullOrWhiteSpace($Output)) { Write-Log "RunCommand output: $Output" "INFO" }
        if (![string]::IsNullOrWhiteSpace($ErrOut)) { Write-Log "RunCommand stderr: $ErrOut" "WARNING" }

        Write-Log "Upgrade initiated inside VM. The VM will now reboot." "SUCCESS"
    }
} catch {
    Write-Log "Invoke-AzVMRunCommand failed." "ERROR"
    Write-Log "Error: $($_.Exception.Message)" "ERROR"
    Write-Log "Manual fallback: RDP into the VM, find setup.exe on the upgrade media disk, and run:" "WARNING"
    Write-Log "  .\setup.exe /auto upgrade /dynamicupdate disable /eula accept /imageindex $ImageIndex" "WARNING"
    exit 1
}

# --- Step 5: Post-Upgrade Monitoring and Cleanup ---
# Poll until the VM is back online, up to 90 minutes (upgrade involves multiple reboots).
$MaxWaitSeconds  = 5400   # 90 minutes
$PollIntervalSec = 60
$Elapsed         = 0
$PostState       = ""

Write-Log "Waiting for VM to complete upgrade and come back online (max 90 min, polling every 60s)..." "INFO"

while ($Elapsed -lt $MaxWaitSeconds) {
    Start-Sleep -Seconds $PollIntervalSec
    $Elapsed += $PollIntervalSec

    $VM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status -ErrorAction SilentlyContinue
    if ($null -ne $VM) {
        $PostState = ($VM.Statuses | Where-Object { $_.Code -match "PowerState" }).DisplayStatus
    }
    $Mins = [math]::Round($Elapsed / 60)
    Write-Log "[$Mins min elapsed] VM state: $(if ($PostState) { $PostState } else { '(unknown - transient API error)' })" "INFO"

    if ($PostState -eq "VM running") {
        break
    }
}

if ($PostState -eq "VM running") {
    Write-Log "VM is back online." "SUCCESS"
    Write-Log "RDP into the VM and run 'systeminfo' to confirm Windows Server 2025." "INFO"

    # Detach and remove the upgrade media disk
    Write-Log "Detaching upgrade media disk '$UpgradeDiskName'..." "INFO"
    try {
        if ($PSCmdlet.ShouldProcess("$VMName", "Detach upgrade media disk '$UpgradeDiskName'")) {
            # Use 'az vm disk detach' (PATCH) for the same reason as attach — avoids osProfile conflict.
            $DetachOut = az vm disk detach `
                --resource-group $ResourceGroupName `
                --vm-name        $VMName `
                --name           $UpgradeDiskName 2>&1

            if ($LASTEXITCODE -ne 0) {
                throw "az vm disk detach failed (exit $LASTEXITCODE): $DetachOut"
            }
            Write-Log "Upgrade media disk detached." "SUCCESS"

            Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $UpgradeDiskName -Force -ErrorAction Stop | Out-Null
            Write-Log "Upgrade media disk deleted." "SUCCESS"
        }
    } catch {
        Write-Log "Could not detach/delete upgrade media disk. Remove it manually: '$UpgradeDiskName'." "WARNING"
        Write-Log "Error: $($_.Exception.Message)" "WARNING"
    }

    Write-Log "Post-upgrade reminder: delete the pre-upgrade snapshots once you have verified the VM is healthy." "INFO"
    Write-Log "Also consider removing C:\Windows.old to reclaim disk space (8-20 GB)." "INFO"
} else {
    Write-Log "VM is not yet running (state: $PostState). Check Boot Diagnostics in the Azure Portal." "WARNING"
    Write-Log "If the upgrade failed, restore from the pre-upgrade snapshots created in Step 3." "WARNING"
}

Write-Log "Script execution finished. Log saved to: $LogFile" "INFO"
