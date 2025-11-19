<#
VMware-Tools-Cleanup-NoReboot.ps1

Purpose: Automated, non-rebooting cleanup of VMware Tools after migration (e.g. VMware -> Azure).
Run as Administrator. This script:
 - Stops and disables known VMware services
 - Removes VMware program folders (Program Files, Common Files, ProgramData, per-user AppData)
 - Removes VMware-related registry keys (Services entries and SOFTWARE\VMware...)
 - Deletes VMware driver files from System32\drivers
 - Tries to uninstall VMware drivers via PnP (Remove-PnpDevice / pnputil) where possible
 - Writes an operation log

CAUTION: Inspect the script before running. Keep a snapshot/backup if possible. This script attempts to be safe/idempotent and will not trigger a reboot.
#>

param(
    [switch]$WhatIfRun = $false, # if set, no destructive actions will be performed; actions are logged
    [string]$LogPath = "C:\Windows\Temp\vmware_cleanup_$((Get-Date).ToString('yyyyMMdd_HHmmss')).log"
)

function Log {
    param($msg)
    $t = (Get-Date).ToString('u')
    $line = "[$t] $msg"
    $line | Tee-Object -FilePath $LogPath -Append
}

# Ensure running as admin
if (-not ([bool](([System.Security.Principal.WindowsPrincipal] [System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)))) {
    Write-Error "This script must be run as Administrator. Exiting."
    exit 1
}

Log "=== VMware Tools Cleanup started ==="
if ($WhatIfRun) { Log "Running in WHATIF mode (no destructive actions)." }

# Common VMware service/driver names to target
$serviceNames = @(
    'VMTools', 'VMToolsDeviceUnlocker0', 'VMAuthdService', 'VMwareHostd',
    'vmci', 'vm3dmp', 'vmaudio', 'vmhgfs', 'VMMemCtl', 'vmmouse', 'VMRawDisk',
    'vmusbmouse', 'vmvss','vmxnet', 'vmxnet3', 'vmxnetadapter', 'VMnetDHCP', 'VMnetBridge', 'VMnetAdapter', 'VMwareCAF', 'vmstorfl', 'VMUsbArbService'
)

# Stop + disable services if present
foreach ($s in $serviceNames) {
    try {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($svc) {
            Log "Service found: $s (Status=$($svc.Status))"
            if ($svc.Status -ne 'Stopped') {
                Log "Stopping service $s..."
                if (-not $WhatIfRun) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
            }
            Log "Setting service $s startup type to Disabled..."
            if (-not $WhatIfRun) { Set-Service -Name $s -StartupType Disabled -ErrorAction SilentlyContinue }
        } else {
            Log "Service not present: $s"
        }
    } catch {
        Log "Error managing service $s: $($_.Exception.Message)"
    }
}

# Remove service keys from registry (CurrentControlSet) - target exact names from list
foreach ($s in $serviceNames) {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$s"
    try {
        if (Test-Path $regPath) {
            Log "Removing registry service key: $regPath"
            if (-not $WhatIfRun) { Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        Log "Failed to remove registry key $regPath: $($_.Exception.Message)"
    }
}

# Remove VMware software registry keys (both 64-bit and 32-bit view)
$swKeys = @(
    'HKLM:\SOFTWARE\VMware, Inc.',
    'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.',
    'HKLM:\SOFTWARE\VMware',
    'HKLM:\SOFTWARE\WOW6432Node\VMware'
)
foreach ($k in $swKeys) {
    try {
        if (Test-Path $k) {
            Log "Removing registry key: $k"
            if (-not $WhatIfRun) { Remove-Item -Path $k -Recurse -Force -ErrorAction SilentlyContinue }
        } else { Log "Registry key not found: $k" }
    } catch {
        Log "Failed to remove $k: $($_.Exception.Message)"
    }
}

# Folders to remove (Program Files, ProgramData, per-user AppData)
$paths = @(
    "C:\Program Files\VMware",
    "C:\Program Files\Common Files\VMware",
    "C:\ProgramData\VMware",
    "C:\ProgramData\VMware\VMware Tools",
    "C:\Program Files (x86)\VMware",
    "C:\Program Files (x86)\Common Files\VMware"
)

foreach ($p in $paths) {
    try {
        if (Test-Path $p) {
            Log "Removing folder: $p"
            if (-not $WhatIfRun) { Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue }
        } else { Log "Folder not present: $p" }
    } catch {
        Log "Failed to remove folder $p: $($_.Exception.Message)"
    }
}

# Remove per-user AppData VMware folders for all user profiles
try {
    $userProfiles = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' | ForEach-Object {
        Get-ItemProperty $_.PsPath
    }
    foreach ($up in $userProfiles) {
        $profilePath = $up.ProfileImagePath
        if ($profilePath -and (Test-Path $profilePath)) {
            $appPaths = @(
                Join-Path $profilePath 'AppData\Roaming\VMware',
                Join-Path $profilePath 'AppData\Local\VMware'
            )
            foreach ($ap in $appPaths) {
                if (Test-Path $ap) {
                    Log "Removing user AppData folder: $ap"
                    if (-not $WhatIfRun) { Remove-Item -Path $ap -Recurse -Force -ErrorAction SilentlyContinue }
                }
            }
        }
    }
} catch {
    Log "Error enumerating user profiles: $($_.Exception.Message)"
}

# Remove VMware-related driver files from System32\drivers
$driverDir = "$env:windir\System32\drivers"
$driverPatterns = @('vm*.sys','vmm*.sys','vmhgfs.sys','vmci.sys','vmaudio.sys','vmx_svga*.sys','vm3dmp.sys','vmxnet*.sys')
foreach ($pat in $driverPatterns) {
    try {
        $matches = Get-ChildItem -Path $driverDir -Filter $pat -ErrorAction SilentlyContinue
        foreach ($f in $matches) {
            Log "Deleting driver file: $($f.FullName)"
            if (-not $WhatIfRun) { Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        Log "Error removing drivers for pattern $pat: $($_.Exception.Message)"
    }
}

# Attempt to remove PnP devices and driver packages related to VMware
try {
    # Use Get-PnpDevice if available
    if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
        $pnp = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { ($_.FriendlyName -like '*VMware*') -or ($_.Manufacturer -like '*VMware*') }
        foreach ($d in $pnp) {
            Log "Found PnP device: $($d.InstanceId) - $($d.FriendlyName) - Status=$($d.Status)"
            try {
                if (-not $WhatIfRun) {
                    # Try Remove-PnpDevice - requires driver uninstall privileges
                    if (Get-Command Remove-PnpDevice -ErrorAction SilentlyContinue) {
                        Log "Attempting Remove-PnpDevice for $($d.InstanceId)"
                        Remove-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
                    } else {
                        Log "Remove-PnpDevice not available. Skipping device removal for $($d.InstanceId)"
                    }
                }
            } catch {
                Log "Failed to Remove-PnpDevice $($d.InstanceId): $($_.Exception.Message)"
            }
        }
    } else {
        Log "Get-PnpDevice not available on this system; skipping PnP device removal step."
    }

    # Remove driver packages using pnputil where possible (search by published name/provider)
    if (Get-Command pnputil.exe -ErrorAction SilentlyContinue) {
        Log "Enumerating driver packages via pnputil..."
        $drvList = pnputil.exe /enum-drivers 2>&1 | Out-String
        # Find lines containing VMware or vmware
        $driverLines = ($drvList -split "\r?\n") | Where-Object { $_ -match 'VMware' -or $_ -match 'vmware' }
        if ($driverLines) {
            Log "Driver packages referencing VMware found. Attempting to remove matching packages."
            # Extract oemXX.inf names and remove
            $infMatches = ($drvList -split "\r?\n") | Where-Object { $_ -match '^Published Name' -and ($_ -match 'oem\d+\.inf') }
            foreach ($ln in $infMatches) {
                $inf = ($ln -split ':')[1].Trim()
                # Read the section around the published name to check provider
                $block = ($drvList -split "\r?\n\r?\n") | Where-Object { $_ -match [regex]::Escape($inf) }
                if ($block -and ($block -match 'Provider.*VMware' -or $block -match 'VMware')) {
                    Log "Attempting pnputil /delete-driver $inf /uninstall /force"
                    if (-not $WhatIfRun) { pnputil.exe /delete-driver $inf /uninstall /force | Out-Null }
                }
            }
        } else { Log "No VMware driver packages found via pnputil." }
    } else { Log "pnputil not found; skipping driver package removal." }
} catch {
    Log "Error during PnP / driver package removal: $($_.Exception.Message)"
}

# Attempt to remove VMware display adapter driver (SVGA)
try {
    if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
        $svga = Get-PnpDevice | Where-Object { ($_.FriendlyName -like '*SVGA*') -or ($_.FriendlyName -like '*VMware SVGA*') -or ($_.Manufacturer -like '*VMware*') }
        foreach ($d in $svga) {
            Log "Found display/device: $($d.InstanceId) - $($d.FriendlyName)"
            if (-not $WhatIfRun -and (Get-Command Remove-PnpDevice -ErrorAction SilentlyContinue)) {
                try { Remove-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue; Log "Remove-PnpDevice invoked for $($d.InstanceId)" } catch { Log "Failed to remove device $($d.InstanceId): $($_.Exception.Message)" }
            }
        }
    }
} catch {
    Log "Error removing display adapter: $($_.Exception.Message)"
}

# Final cleanup: attempt to remove residual files under C:\Windows\INF referencing VMware (optional, be cautious)
try {
    $infFolder = "$env:windir\inf"
    $infFiles = Get-ChildItem -Path $infFolder -Filter '*.inf' -ErrorAction SilentlyContinue | Where-Object { ($_ | Get-Content -ErrorAction SilentlyContinue) -match 'VMware' }
    foreach ($inf in $infFiles) {
        Log "Found INF referencing VMware: $($inf.Name). Not deleting automatically. To remove, check $($inf.FullName) manually."
    }
} catch {
    Log "Error scanning INF files: $($_.Exception.Message)"
}

Log "=== VMware Tools Cleanup completed (no reboot). Check log at: $LogPath ==="

# Summary output
Write-Output "Cleanup finished. Log: $LogPath"
if ($WhatIfRun) { Write-Output "(WhatIfRun mode — no files/services/registry were actually removed.)" }