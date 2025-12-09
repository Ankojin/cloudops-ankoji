<#
.SYNOPSIS
    Removes VMware Tools from Windows servers after Azure migration across multiple hosts.

.DESCRIPTION
    Production-grade script for removing VMware Tools from migrated Azure VMs:
    - Registry-based detection (fast, no Win32_Product slowness)
    - MSI uninstall with database patching for VM_LogStart issues
    - Comprehensive cleanup: services, devices, drivers, registry, folders
    - WinRM remoting with automatic authentication fallback
    - CSV or text file input for host lists
    - Detailed logging with success/failure tracking
    - WhatIf support for safe testing

.PARAMETER ComputersFile
    Path to CSV file (with ComputerName column) or text file (one hostname per line).
    If not provided, will look for 'computers.txt' or 'computers.csv' in script directory.

.PARAMETER LogPath
    Path to log file. Defaults to script directory with timestamp.

.PARAMETER Credential
    PSCredential object for remote authentication. If not provided, will prompt.

.PARAMETER UseSSL
    Use HTTPS for WinRM connections (requires proper cert configuration).

.PARAMETER MaxConcurrent
    Maximum number of concurrent remote executions (default: 5).

.PARAMETER WhatIf
    Shows what would happen without making changes.

.EXAMPLE
    .\Remove-VMwareTools.ps1
    Processes computers from computers.txt in script directory, prompts for credentials.

.EXAMPLE
    .\Remove-VMwareTools.ps1 -ComputersFile C:\Temp\servers.csv -WhatIf
    Dry-run using CSV file with ComputerName column.

.EXAMPLE
    $cred = Get-Credential
    .\Remove-VMwareTools.ps1 -ComputersFile servers.txt -Credential $cred -MaxConcurrent 10
    Process 10 servers concurrently with pre-supplied credentials.

.NOTES
    Author: BAB CloudOps Team
    Version: 2.0
    Requires: PowerShell 5.1+, WinRM enabled on target hosts
    Security: Uses secure credential handling, no hardcoded paths or secrets
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ComputersFile,

    [Parameter(Mandatory = $false)]
    [string]$LogPath,

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [switch]$UseSSL,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 50)]
    [int]$MaxConcurrent = 5
)

#Requires -Version 5.1

# ============================================================================
# INITIALIZATION
# ============================================================================

$ErrorActionPreference = 'Continue'
$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Get-Location }

# Auto-detect computers file if not specified
if (-not $ComputersFile) {
    $csvPath = Join-Path $scriptRoot 'computers.csv'
    $txtPath = Join-Path $scriptRoot 'computers.txt'
    
    if (Test-Path $csvPath) {
        $ComputersFile = $csvPath
    } elseif (Test-Path $txtPath) {
        $ComputersFile = $txtPath
    } else {
        Write-Error "No computers file found. Create 'computers.csv' or 'computers.txt' in $scriptRoot"
        exit 1
    }
}

# Set default log path
if (-not $LogPath) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $LogPath = Join-Path $scriptRoot "VMwareTools-Removal-$timestamp.log"
}

# Ensure log directory exists
$logDir = Split-Path $LogPath -Parent
if (-not (Test-Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Thread-safe file writing
    $mutex = New-Object System.Threading.Mutex($false, "VMwareToolsLogMutex")
    try {
        [void]$mutex.WaitOne()
        Add-Content -Path $script:LogPath -Value $logEntry -ErrorAction SilentlyContinue
    } finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
    
    # Console output with colors
    $color = switch ($Level) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        default   { 'White' }
    }
    Write-Host $logEntry -ForegroundColor $color
}

# ============================================================================
# COMPUTER LIST LOADING
# ============================================================================

function Get-ComputerList {
    param([string]$FilePath)
    
    if (-not (Test-Path $FilePath)) {
        Write-Log "Computer list file not found: $FilePath" -Level Error
        return @()
    }
    
    $extension = [System.IO.Path]::GetExtension($FilePath)
    
    if ($extension -eq '.csv') {
        # CSV file - expect ComputerName column
        try {
            $computers = Import-Csv -Path $FilePath | 
                Where-Object { $_.ComputerName -and $_.ComputerName.Trim() } |
                Select-Object -ExpandProperty ComputerName
            Write-Log "Loaded $($computers.Count) computers from CSV: $FilePath" -Level Info
            return $computers
        } catch {
            Write-Log "Failed to parse CSV file: $_" -Level Error
            return @()
        }
    } else {
        # Text file - one hostname per line
        try {
            $computers = Get-Content -Path $FilePath | 
                Where-Object { $_ -and $_.Trim() -ne '' } |
                ForEach-Object { $_.Trim() }
            Write-Log "Loaded $($computers.Count) computers from text file: $FilePath" -Level Info
            return $computers
        } catch {
            Write-Log "Failed to read text file: $_" -Level Error
            return @()
        }
    }
}

# ============================================================================
# WINRM CONNECTIVITY TEST
# ============================================================================

function Test-WinRMConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,
        
        [Parameter(Mandatory = $true)]
        [PSCredential]$Credential,
        
        [Parameter(Mandatory = $false)]
        [bool]$UseSSL = $false
    )
    
    $authMethods = @('Negotiate', 'Kerberos')
    
    foreach ($authMethod in $authMethods) {
        try {
            $testParams = @{
                ComputerName   = $ComputerName
                Credential     = $Credential
                Authentication = $authMethod
                ScriptBlock    = { $env:COMPUTERNAME }
                ErrorAction    = 'Stop'
            }
            
            if ($UseSSL) {
                $testParams['UseSSL'] = $true
            }
            
            $result = Invoke-Command @testParams
            
            if ($result) {
                Write-Log "WinRM connectivity confirmed: $ComputerName ($authMethod)" -Level Success
                return $authMethod
            }
        } catch {
            Write-Log "WinRM test failed with $authMethod on ${ComputerName}: $($_.Exception.Message)" -Level Warning
            continue
        }
    }
    
    return $null
}

# ============================================================================
# VMWARE TOOLS CLEANUP SCRIPTBLOCK (Remote Execution)
# ============================================================================

$vmwareCleanupScript = {
    param(
        [string]$ComputerName
    )
    
    $results = @{
        ComputerName = $ComputerName
        Success = $false
        Actions = @()
        Errors = @()
    }
    
    function Add-Result {
        param([string]$Action, [bool]$Success, [string]$Details = '')
        $script:results.Actions += [PSCustomObject]@{
            Action = $Action
            Success = $Success
            Details = $Details
            Timestamp = Get-Date
        }
    }
    
    try {
        # ===================================================================
        # STEP 1: Registry-based VMware Tools detection (FAST method)
        # ===================================================================
        
        function Get-VMwareToolsInfo {
            $uninstallPaths = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            )
            
            $vmwareProducts = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
                Where-Object { 
                    $_.DisplayName -like "*VMware*Tools*" -or 
                    $_.Publisher -like "*VMware*"
                }
            
            # Also check HKCR for installer GUID
            $installerGuid = $null
            try {
                $hkcrProducts = Get-ChildItem 'Registry::HKEY_CLASSES_ROOT\Installer\Products' -ErrorAction SilentlyContinue
                foreach ($item in $hkcrProducts) {
                    if ($item.GetValue('ProductName') -eq 'VMware Tools') {
                        $installerGuid = $item.PSChildName
                        $productIcon = $item.GetValue('ProductIcon')
                        if ($productIcon -match '\{([A-F0-9-]+)\}') {
                            $msiGuid = $Matches[1]
                        }
                        break
                    }
                }
            } catch {
                # HKCR may not be accessible in some contexts
            }
            
            return @{
                Products = $vmwareProducts
                InstallerGuid = $installerGuid
                MsiGuid = $msiGuid
            }
        }
        
        $vmwareInfo = Get-VMwareToolsInfo
        
        if ($vmwareInfo.Products.Count -eq 0) {
            Add-Result "Detection" $true "No VMware Tools found via registry"
            $results.Success = $true
            return $results
        }
        
        Add-Result "Detection" $true "Found $($vmwareInfo.Products.Count) VMware product(s)"
        
        # ===================================================================
        # STEP 2: MSI Uninstall with database patching
        # ===================================================================
        
        if ($vmwareInfo.InstallerGuid) {
            try {
                $localPackagePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$($vmwareInfo.InstallerGuid)\InstallProperties"
                $localPackage = (Get-ItemProperty -Path $localPackagePath -ErrorAction SilentlyContinue).LocalPackage
                
                if ($localPackage -and (Test-Path $localPackage)) {
                    # Patch MSI database to remove problematic actions
                    try {
                        $installer = New-Object -ComObject WindowsInstaller.Installer
                        $database = $installer.GetType().InvokeMember("OpenDatabase", "InvokeMethod", $null, $installer, @($localPackage, 2))
                        $query = "DELETE FROM CustomAction WHERE Action='VM_LogStart' OR Action='VM_CheckRequirements'"
                        $view = $database.GetType().InvokeMember("OpenView", "InvokeMethod", $null, $database, @($query))
                        $view.GetType().InvokeMember("Execute", "InvokeMethod", $null, $view, $null)
                        $view.GetType().InvokeMember("Close", "InvokeMethod", $null, $view, $null)
                        [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)
                        $database.GetType().InvokeMember("Commit", "InvokeMethod", $null, $database, $null)
                        [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($database)
                        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
                        
                        Add-Result "MSI-Patch" $true "Patched MSI database"
                    } catch {
                        Add-Result "MSI-Patch" $false "Failed to patch MSI: $($_.Exception.Message)"
                    }
                    
                    # Run MSI uninstaller
                    try {
                        $uninstallArgs = "/x `"$localPackage`" /qn /norestart /L*v `"$env:TEMP\vmware_uninstall.log`""
                        $process = Start-Process msiexec.exe -ArgumentList $uninstallArgs -Wait -PassThru -NoNewWindow
                        
                        if ($process.ExitCode -eq 0) {
                            Add-Result "MSI-Uninstall" $true "MSI uninstall completed (Exit: 0)"
                        } else {
                            Add-Result "MSI-Uninstall" $false "MSI uninstall completed with code: $($process.ExitCode)"
                        }
                    } catch {
                        Add-Result "MSI-Uninstall" $false "MSI uninstall failed: $($_.Exception.Message)"
                    }
                } else {
                    Add-Result "MSI-Uninstall" $false "Local MSI package not found"
                }
            } catch {
                Add-Result "MSI-Uninstall" $false "Error during MSI uninstall: $($_.Exception.Message)"
            }
        }
        
        # ===================================================================
        # STEP 3: Alternative uninstall using Get-Package (newer systems)
        # ===================================================================
        
        try {
            $packages = Get-Package -Name "*VMware*Tools*" -ErrorAction SilentlyContinue
            foreach ($package in $packages) {
                try {
                    Uninstall-Package -Name $package.Name -Force -ErrorAction Stop
                    Add-Result "Package-Uninstall" $true "Uninstalled: $($package.Name)"
                } catch {
                    Add-Result "Package-Uninstall" $false "Failed to uninstall $($package.Name): $_"
                }
            }
        } catch {
            # Get-Package not available or failed
        }
        
        # ===================================================================
        # STEP 4: Stop and remove VMware services
        # ===================================================================
        
        $vmwareServices = Get-Service -ErrorAction SilentlyContinue | 
            Where-Object { 
                $_.Name -like "*vmware*" -or 
                $_.DisplayName -like "*vmware*" -or
                $_.Name -eq "GISvc"
            }
        
        if ($vmwareServices) {
            # Stop dependent services first (per Broadcom KB315629)
            try {
                $dependentServices = @('EventLog', 'wmiApSrv', 'winmgmt')
                foreach ($depSvc in $dependentServices) {
                    $svc = Get-Service -Name $depSvc -ErrorAction SilentlyContinue
                    if ($svc -and $svc.Status -eq 'Running') {
                        Stop-Service -Name $depSvc -Force -ErrorAction SilentlyContinue
                        Add-Result "Service-Stop-Dependent" $true "Stopped dependent: $depSvc"
                    }
                }
                Start-Sleep -Seconds 2
            } catch { }
            
            # Stop services
            foreach ($service in $vmwareServices) {
                try {
                    if ($service.Status -eq 'Running') {
                        Stop-Service -Name $service.Name -Force -ErrorAction Stop
                        Add-Result "Service-Stop" $true "Stopped: $($service.Name)"
                    }
                } catch {
                    Add-Result "Service-Stop" $false "Failed to stop $($service.Name): $_"
                }
            }
            
            # Wait for services to fully stop
            Start-Sleep -Seconds 2
            
            # Delete services
            foreach ($service in $vmwareServices) {
                try {
                    if (Get-Command Remove-Service -ErrorAction SilentlyContinue) {
                        Remove-Service -Name $service.Name -ErrorAction Stop
                    } else {
                        $scResult = & sc.exe delete $service.Name 2>&1
                        if ($LASTEXITCODE -ne 0) { throw $scResult }
                    }
                    Add-Result "Service-Remove" $true "Removed: $($service.Name)"
                } catch {
                    Add-Result "Service-Remove" $false "Failed to remove $($service.Name): $_"
                }
            }
            
            # Restart dependent services
            try {
                $dependentServices = @('winmgmt', 'wmiApSrv', 'EventLog')
                foreach ($depSvc in $dependentServices) {
                    Start-Service -Name $depSvc -ErrorAction SilentlyContinue
                }
            } catch { }
        }
        
        # ===================================================================
        # STEP 5: Remove VMware registry entries
        # ===================================================================
        
        $registryPaths = @(
            'HKLM:\SOFTWARE\VMware, Inc.',
            'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.'
        )
        
        # Add installer-specific paths if found
        if ($vmwareInfo.InstallerGuid) {
            $registryPaths += @(
                "Registry::HKEY_CLASSES_ROOT\Installer\Features\$($vmwareInfo.InstallerGuid)",
                "Registry::HKEY_CLASSES_ROOT\Installer\Products\$($vmwareInfo.InstallerGuid)",
                "HKLM:\SOFTWARE\Classes\Installer\Features\$($vmwareInfo.InstallerGuid)",
                "HKLM:\SOFTWARE\Classes\Installer\Products\$($vmwareInfo.InstallerGuid)",
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$($vmwareInfo.InstallerGuid)"
            )
        }
        
        if ($vmwareInfo.MsiGuid) {
            $registryPaths += "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{$($vmwareInfo.MsiGuid)}"
        }
        
        # Remove VMware User Process from Run key
        $runKeyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
        try {
            $runKey = Get-ItemProperty -Path $runKeyPath -ErrorAction SilentlyContinue
            if ($runKey.'VMware User Process') {
                Remove-ItemProperty -Path $runKeyPath -Name 'VMware User Process' -Force -ErrorAction Stop
                Add-Result "Registry-RunKey" $true "Removed VMware User Process from Run key"
            }
        } catch {
            Add-Result "Registry-RunKey" $false "Failed to remove Run key: $_"
        }
        
        foreach ($regPath in $registryPaths) {
            if (Test-Path $regPath) {
                try {
                    Remove-Item -Path $regPath -Recurse -Force -ErrorAction Stop
                    Add-Result "Registry-Remove" $true "Removed: $regPath"
                } catch {
                    Add-Result "Registry-Remove" $false "Failed: $regPath - $_"
                }
            }
        }
        
        # ===================================================================
        # STEP 6: Remove VMware directories
        # ===================================================================
        
        $vmwareDirectories = @(
            "$env:ProgramFiles\VMware",
            "${env:ProgramFiles(x86)}\VMware",
            "$env:ProgramFiles\Common Files\VMware",
            "${env:ProgramFiles(x86)}\Common Files\VMware",
            "$env:ProgramData\VMware",
            "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\VMware"
        )
        
        foreach ($dir in $vmwareDirectories) {
            if (Test-Path $dir) {
                try {
                    Remove-Item -Path $dir -Recurse -Force -ErrorAction Stop
                    Add-Result "Directory-Remove" $true "Removed: $dir"
                } catch {
                    Add-Result "Directory-Remove" $false "Failed: $dir - $_"
                }
            }
        }
        
        # ===================================================================
        # STEP 7: Remove VMware PnP devices
        # ===================================================================
        
        try {
            $vmwareDevices = Get-PnpDevice -ErrorAction SilentlyContinue | 
                Where-Object { $_.FriendlyName -like "*VMware*" }
            
            foreach ($device in $vmwareDevices) {
                try {
                    $pnpResult = & pnputil.exe /remove-device $device.InstanceId 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Add-Result "Device-Remove" $true "Removed: $($device.FriendlyName)"
                    } else {
                        Add-Result "Device-Remove" $false "Failed: $($device.FriendlyName) - $pnpResult"
                    }
                } catch {
                    Add-Result "Device-Remove" $false "Error removing $($device.FriendlyName): $_"
                }
            }
        } catch {
            Add-Result "Device-Remove" $false "PnP device enumeration failed: $_"
        }
        
        # ===================================================================
        # STEP 8: Remove VMware driver packages
        # ===================================================================
        
        try {
            $pnpOutput = & pnputil.exe /enum-drivers
            $vmwareDrivers = @()
            
            for ($i = 0; $i -lt $pnpOutput.Count; $i++) {
                if ($pnpOutput[$i] -match "Published Name\s*:\s*(oem\d+\.inf)") {
                    $oemInf = $Matches[1]
                    $driverBlock = ($pnpOutput[$i..($i+10)] -join ' ')
                    
                    if ($driverBlock -match "VMware") {
                        $vmwareDrivers += $oemInf
                    }
                }
            }
            
            foreach ($driver in $vmwareDrivers) {
                try {
                    $driverResult = & pnputil.exe /delete-driver $driver /uninstall /force 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Add-Result "Driver-Remove" $true "Removed: $driver"
                    } else {
                        Add-Result "Driver-Remove" $false "Failed: $driver - $driverResult"
                    }
                } catch {
                    Add-Result "Driver-Remove" $false "Error removing $driver : $_"
                }
            }
        } catch {
            Add-Result "Driver-Remove" $false "Driver enumeration failed: $_"
        }
        
        # ===================================================================
        # STEP 9: Unregister DLL if present
        # ===================================================================
        
        $vmStatsDll = "$env:ProgramFiles\VMware\VMware Tools\vmStatsProvider\win64\vmStatsProvider.dll"
        if (Test-Path $vmStatsDll) {
            try {
                & regsvr32.exe /s /u $vmStatsDll
                Add-Result "DLL-Unregister" $true "Unregistered vmStatsProvider.dll"
            } catch {
                Add-Result "DLL-Unregister" $false "Failed to unregister DLL: $_"
            }
        }
        
        $results.Success = $true
        
    } catch {
        $results.Errors += "Critical error: $($_.Exception.Message)"
        $results.Success = $false
    }
    
    return $results
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "========================================" -Level Info
Write-Log "VMware Tools Removal Script - BAB CloudOps" -Level Info
Write-Log "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level Info
Write-Log "========================================" -Level Info

# Load computer list
$computers = Get-ComputerList -FilePath $ComputersFile

if ($computers.Count -eq 0) {
    Write-Log "No computers to process. Exiting." -Level Error
    exit 1
}

Write-Log "Total computers to process: $($computers.Count)" -Level Info

# Prompt for credentials if not provided
if (-not $Credential) {
    try {
        $Credential = Get-Credential -Message "Enter credentials with admin rights on target hosts"
        if (-not $Credential) {
            Write-Log "Credentials are required. Exiting." -Level Error
            exit 1
        }
    } catch {
        Write-Log "Failed to obtain credentials: $_" -Level Error
        exit 1
    }
}

# Initialize tracking variables
$totalCount = $computers.Count

# Results collection (thread-safe)
$allResults = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

# Process computers with throttling
Write-Log "Processing $totalCount computers (max $MaxConcurrent concurrent)..." -Level Info

$executionResults = $computers | ForEach-Object -ThrottleLimit $MaxConcurrent -Parallel {
    $computer = $_
    $cred = $using:Credential
    $useSSL = $using:UseSSL
    $logPath = $using:LogPath
    $whatIf = $using:WhatIfPreference
    $totalCount = $using:totalCount
    $allResults = $using:allResults
    
    # Import logging function into parallel scope
    function Write-Log {
        param([string]$Message, [string]$Level = 'Info')
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $logEntry = "[$timestamp] [$Level] $Message"
        $mutex = New-Object System.Threading.Mutex($false, "VMwareToolsLogMutex")
        try {
            [void]$mutex.WaitOne()
            Add-Content -Path $logPath -Value $logEntry -ErrorAction SilentlyContinue
        } finally {
            $mutex.ReleaseMutex()
            $mutex.Dispose()
        }
        $color = switch ($Level) {
            'Success' { 'Green' }
            'Warning' { 'Yellow' }
            'Error'   { 'Red' }
            default   { 'White' }
        }
        Write-Host $logEntry -ForegroundColor $color
    }
    
    Write-Log "===== Processing: $computer =====" -Level Info
    
    # Create result object for this computer
    $computerResult = [PSCustomObject]@{
        ComputerName = $computer
        Success = $false
        Connected = $false
        ExecutionSuccess = $false
    }
    
    if ($whatIf) {
        Write-Log "WhatIf: Would remove VMware Tools from $computer" -Level Info
        $computerResult.Success = $true
        $computerResult.Connected = $true
        $computerResult.ExecutionSuccess = $true
        return $computerResult
    }
    
    # Test WinRM connectivity
    $authMethod = $null
    $authMethods = @('Negotiate', 'Kerberos')
    
    foreach ($auth in $authMethods) {
        try {
            $testParams = @{
                ComputerName   = $computer
                Credential     = $cred
                Authentication = $auth
                ScriptBlock    = { $env:COMPUTERNAME }
                ErrorAction    = 'Stop'
            }
            if ($useSSL) { $testParams['UseSSL'] = $true }
            
            $testResult = Invoke-Command @testParams
            if ($testResult) {
                $authMethod = $auth
                Write-Log "WinRM connected to $computer ($auth)" -Level Success
                $computerResult.Connected = $true
                break
            }
        } catch {
            continue
        }
    }
    
    if (-not $authMethod) {
        Write-Log "Failed to connect to $computer via WinRM" -Level Error
        return $computerResult
    }
    
    # Execute cleanup - inline scriptblock to avoid $using: scriptblock variable issue
    try {
        $cleanupScriptBlock = {
            param([string]$ComputerName)
            
            $results = @{
                ComputerName = $ComputerName
                Success = $false
                Actions = @()
                Errors = @()
            }
            
            function Add-Result {
                param([string]$Action, [bool]$Success, [string]$Details = '')
                $script:results.Actions += [PSCustomObject]@{
                    Action = $Action
                    Success = $Success
                    Details = $Details
                    Timestamp = Get-Date
                }
            }
            
            try {
                # Registry-based VMware Tools detection
                function Get-VMwareToolsInfo {
                    $uninstallPaths = @(
                        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
                    )
                    
                    $vmwareProducts = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
                        Where-Object { 
                            $_.DisplayName -like "*VMware*Tools*" -or 
                            $_.Publisher -like "*VMware*"
                        }
                    
                    $installerGuid = $null
                    $msiGuid = $null
                    try {
                        $hkcrProducts = Get-ChildItem 'Registry::HKEY_CLASSES_ROOT\Installer\Products' -ErrorAction SilentlyContinue
                        foreach ($item in $hkcrProducts) {
                            if ($item.GetValue('ProductName') -eq 'VMware Tools') {
                                $installerGuid = $item.PSChildName
                                $productIcon = $item.GetValue('ProductIcon')
                                if ($productIcon -match '\{([A-F0-9-]+)\}') {
                                    $msiGuid = $Matches[1]
                                }
                                break
                            }
                        }
                    } catch { }
                    
                    return @{
                        Products = $vmwareProducts
                        InstallerGuid = $installerGuid
                        MsiGuid = $msiGuid
                    }
                }
                
                $vmwareInfo = Get-VMwareToolsInfo
                
                # Enhanced detection - check for VMware presence even without uninstall entry
                $vmwareDetected = $false
                $detectionSources = @()
                
                if ($vmwareInfo.Products.Count -gt 0) {
                    $vmwareDetected = $true
                    $detectionSources += "Uninstall Registry ($($vmwareInfo.Products.Count) product(s))"
                }
                
                # Check for VMware registry keys (orphaned installations)
                $regKey1Exists = Test-Path 'HKLM:\SOFTWARE\VMware, Inc.' -ErrorAction SilentlyContinue
                $regKey2Exists = Test-Path 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.' -ErrorAction SilentlyContinue
                if ($regKey1Exists -or $regKey2Exists) {
                    $vmwareDetected = $true
                    $detectionSources += "VMware Registry Keys"
                    if ($regKey1Exists) { Add-Result "Detection-Debug" $true "Found: HKLM:\SOFTWARE\VMware, Inc." }
                    if ($regKey2Exists) { Add-Result "Detection-Debug" $true "Found: HKLM:\SOFTWARE\WOW6432Node\VMware, Inc." }
                }
                
                # Check for VMware folders
                $vmwareFolders = @(
                    "$env:ProgramFiles\VMware",
                    "${env:ProgramFiles(x86)}\VMware",
                    "$env:ProgramData\VMware"
                )
                foreach ($folder in $vmwareFolders) {
                    $folderExists = Test-Path $folder -ErrorAction SilentlyContinue
                    if ($folderExists) {
                        $vmwareDetected = $true
                        $detectionSources += "VMware Folders"
                        Add-Result "Detection-Debug" $true "Found folder: $folder"
                        break
                    }
                }
                
                # Check for VMware services
                $vmwareServices = Get-Service -ErrorAction SilentlyContinue | 
                    Where-Object { $_.Name -like "*vmware*" -or $_.DisplayName -like "*vmware*" }
                if ($vmwareServices) {
                    $vmwareDetected = $true
                    $detectionSources += "VMware Services ($($vmwareServices.Count))"
                }
                
                if (-not $vmwareDetected) {
                    Add-Result "Detection" $true "No VMware Tools detected (checked registry, folders, services)"
                    $results.Success = $true
                    return $results
                }
                
                $detectionMsg = "VMware Tools detected via: $($detectionSources -join ', ')"
                Add-Result "Detection" $true $detectionMsg
                
                # MSI Uninstall
                if ($vmwareInfo.InstallerGuid) {
                    try {
                        $localPackagePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$($vmwareInfo.InstallerGuid)\InstallProperties"
                        $localPackage = (Get-ItemProperty -Path $localPackagePath -ErrorAction SilentlyContinue).LocalPackage
                        
                        if ($localPackage -and (Test-Path $localPackage)) {
                            try {
                                $installer = New-Object -ComObject WindowsInstaller.Installer
                                $database = $installer.GetType().InvokeMember("OpenDatabase", "InvokeMethod", $null, $installer, @($localPackage, 2))
                                $query = "DELETE FROM CustomAction WHERE Action='VM_LogStart' OR Action='VM_CheckRequirements'"
                                $view = $database.GetType().InvokeMember("OpenView", "InvokeMethod", $null, $database, @($query))
                                $view.GetType().InvokeMember("Execute", "InvokeMethod", $null, $view, $null)
                                $view.GetType().InvokeMember("Close", "InvokeMethod", $null, $view, $null)
                                [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)
                                $database.GetType().InvokeMember("Commit", "InvokeMethod", $null, $database, $null)
                                [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($database)
                                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
                                Add-Result "MSI-Patch" $true "Patched MSI database"
                            } catch {
                                Add-Result "MSI-Patch" $false "Failed to patch MSI: $($_.Exception.Message)"
                            }
                            
                            try {
                                $uninstallArgs = "/x `"$localPackage`" /qn /norestart /L*v `"$env:TEMP\vmware_uninstall.log`""
                                $process = Start-Process msiexec.exe -ArgumentList $uninstallArgs -Wait -PassThru -NoNewWindow
                                if ($process.ExitCode -eq 0) {
                                    Add-Result "MSI-Uninstall" $true "MSI uninstall completed (Exit: 0)"
                                } else {
                                    Add-Result "MSI-Uninstall" $false "MSI uninstall completed with code: $($process.ExitCode)"
                                }
                            } catch {
                                Add-Result "MSI-Uninstall" $false "MSI uninstall failed: $($_.Exception.Message)"
                            }
                        } else {
                            Add-Result "MSI-Uninstall" $false "Local MSI package not found"
                        }
                    } catch {
                        Add-Result "MSI-Uninstall" $false "Error during MSI uninstall: $($_.Exception.Message)"
                    }
                }
                
                # Package uninstall
                try {
                    $packages = Get-Package -Name "*VMware*Tools*" -ErrorAction SilentlyContinue
                    foreach ($package in $packages) {
                        try {
                            Uninstall-Package -Name $package.Name -Force -ErrorAction Stop
                            Add-Result "Package-Uninstall" $true "Uninstalled: $($package.Name)"
                        } catch {
                            Add-Result "Package-Uninstall" $false "Failed to uninstall $($package.Name): $_"
                        }
                    }
                } catch { }
                
                # Stop and remove services
                $vmwareServices = Get-Service -ErrorAction SilentlyContinue | 
                    Where-Object { $_.Name -like "*vmware*" -or $_.DisplayName -like "*vmware*" -or $_.Name -eq "GISvc" }
                
                if ($vmwareServices) {
                    foreach ($service in $vmwareServices) {
                        try {
                            if ($service.Status -eq 'Running') {
                                Stop-Service -Name $service.Name -Force -ErrorAction Stop
                                Add-Result "Service-Stop" $true "Stopped: $($service.Name)"
                            }
                        } catch {
                            Add-Result "Service-Stop" $false "Failed to stop $($service.Name): $_"
                        }
                    }
                    
                    foreach ($service in $vmwareServices) {
                        try {
                            if (Get-Command Remove-Service -ErrorAction SilentlyContinue) {
                                Remove-Service -Name $service.Name -ErrorAction Stop
                            } else {
                                $scResult = & sc.exe delete $service.Name 2>&1
                                if ($LASTEXITCODE -ne 0) { throw $scResult }
                            }
                            Add-Result "Service-Remove" $true "Removed: $($service.Name)"
                        } catch {
                            Add-Result "Service-Remove" $false "Failed to remove $($service.Name): $_"
                        }
                    }
                }
                
                # Remove registry entries
                $registryPaths = @('HKLM:\SOFTWARE\VMware, Inc.', 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.')
                
                if ($vmwareInfo.InstallerGuid) {
                    $registryPaths += @(
                        "Registry::HKEY_CLASSES_ROOT\Installer\Features\$($vmwareInfo.InstallerGuid)",
                        "Registry::HKEY_CLASSES_ROOT\Installer\Products\$($vmwareInfo.InstallerGuid)",
                        "HKLM:\SOFTWARE\Classes\Installer\Features\$($vmwareInfo.InstallerGuid)",
                        "HKLM:\SOFTWARE\Classes\Installer\Products\$($vmwareInfo.InstallerGuid)",
                        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$($vmwareInfo.InstallerGuid)"
                    )
                }
                
                if ($vmwareInfo.MsiGuid) {
                    $registryPaths += "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{$($vmwareInfo.MsiGuid)}"
                }
                
                $runKeyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
                try {
                    $runKey = Get-ItemProperty -Path $runKeyPath -ErrorAction SilentlyContinue
                    if ($runKey.'VMware User Process') {
                        Remove-ItemProperty -Path $runKeyPath -Name 'VMware User Process' -Force -ErrorAction Stop
                        Add-Result "Registry-RunKey" $true "Removed VMware User Process from Run key"
                    }
                } catch {
                    Add-Result "Registry-RunKey" $false "Failed to remove Run key: $_"
                }
                
                foreach ($regPath in $registryPaths) {
                    if (Test-Path $regPath) {
                        try {
                            Remove-Item -Path $regPath -Recurse -Force -ErrorAction Stop
                            Add-Result "Registry-Remove" $true "Removed: $regPath"
                        } catch {
                            Add-Result "Registry-Remove" $false "Failed: $regPath - $_"
                        }
                    }
                }
                
                # Remove directories
                $vmwareDirectories = @(
                    "$env:ProgramFiles\VMware",
                    "${env:ProgramFiles(x86)}\VMware",
                    "$env:ProgramFiles\Common Files\VMware",
                    "${env:ProgramFiles(x86)}\Common Files\VMware",
                    "$env:ProgramData\VMware",
                    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\VMware"
                )
                
                foreach ($dir in $vmwareDirectories) {
                    if (Test-Path $dir) {
                        try {
                            Remove-Item -Path $dir -Recurse -Force -ErrorAction Stop
                            Add-Result "Directory-Remove" $true "Removed: $dir"
                        } catch {
                            Add-Result "Directory-Remove" $false "Failed: $dir - $_"
                        }
                    }
                }
                
                # Remove PnP devices
                try {
                    $vmwareDevices = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -like "*VMware*" }
                    foreach ($device in $vmwareDevices) {
                        try {
                            $pnpResult = & pnputil.exe /remove-device $device.InstanceId 2>&1
                            if ($LASTEXITCODE -eq 0) {
                                Add-Result "Device-Remove" $true "Removed: $($device.FriendlyName)"
                            } else {
                                Add-Result "Device-Remove" $false "Failed: $($device.FriendlyName) - $pnpResult"
                            }
                        } catch {
                            Add-Result "Device-Remove" $false "Error removing $($device.FriendlyName): $_"
                        }
                    }
                } catch {
                    Add-Result "Device-Remove" $false "PnP device enumeration failed: $_"
                }
                
                # Remove driver packages
                try {
                    $pnpOutput = & pnputil.exe /enum-drivers
                    $vmwareDrivers = @()
                    for ($i = 0; $i -lt $pnpOutput.Count; $i++) {
                        if ($pnpOutput[$i] -match "Published Name\s*:\s*(oem\d+\.inf)") {
                            $oemInf = $Matches[1]
                            $driverBlock = ($pnpOutput[$i..($i+10)] -join ' ')
                            if ($driverBlock -match "VMware") {
                                $vmwareDrivers += $oemInf
                            }
                        }
                    }
                    foreach ($driver in $vmwareDrivers) {
                        try {
                            $driverResult = & pnputil.exe /delete-driver $driver /uninstall /force 2>&1
                            if ($LASTEXITCODE -eq 0) {
                                Add-Result "Driver-Remove" $true "Removed: $driver"
                            } else {
                                Add-Result "Driver-Remove" $false "Failed: $driver - $driverResult"
                            }
                        } catch {
                            Add-Result "Driver-Remove" $false "Error removing $driver : $_"
                        }
                    }
                } catch {
                    Add-Result "Driver-Remove" $false "Driver enumeration failed: $_"
                }
                
                # Unregister DLL
                $vmStatsDll = "$env:ProgramFiles\VMware\VMware Tools\vmStatsProvider\win64\vmStatsProvider.dll"
                if (Test-Path $vmStatsDll) {
                    try {
                        & regsvr32.exe /s /u $vmStatsDll
                        Add-Result "DLL-Unregister" $true "Unregistered vmStatsProvider.dll"
                    } catch {
                        Add-Result "DLL-Unregister" $false "Failed to unregister DLL: $_"
                    }
                }
                
                $results.Success = $true
            } catch {
                $results.Errors += "Critical error: $($_.Exception.Message)"
                $results.Success = $false
            }
            
            return $results
        }
        
        $invokeParams = @{
            ComputerName   = $computer
            Credential     = $cred
            Authentication = $authMethod
            ScriptBlock    = $cleanupScriptBlock
            ArgumentList   = @($computer)
            ErrorAction    = 'Stop'
        }
        if ($useSSL) { $invokeParams['UseSSL'] = $true }
        
        $result = Invoke-Command @invokeParams
        
        if ($result.Success) {
            Write-Log "Successfully cleaned VMware Tools from $computer" -Level Success
            $computerResult.Success = $true
            $computerResult.ExecutionSuccess = $true
        } else {
            Write-Log "Cleanup completed with errors on $computer" -Level Warning
            foreach ($error in $result.Errors) {
                Write-Log "  Error: $error" -Level Error
            }
            $computerResult.ExecutionSuccess = $false
        }
        
        # Log individual actions
        foreach ($action in $result.Actions) {
            $actionLevel = if ($action.Success) { 'Info' } else { 'Warning' }
            Write-Log "  $($action.Action): $($action.Details)" -Level $actionLevel
        }
        
        $allResults.Add($result)
        
    } catch {
        Write-Log "Failed to execute cleanup on $computer : $_" -Level Error
        $computerResult.ExecutionSuccess = $false
    }
    
    return $computerResult
}

Write-Progress -Activity "VMware Tools Removal" -Completed

# Calculate statistics from results
$successCount = ($executionResults | Where-Object { $_.Success -eq $true }).Count
$failureCount = ($executionResults | Where-Object { $_.Success -eq $false }).Count
$connectionFailures = ($executionResults | Where-Object { $_.Connected -eq $false }).Count

# ============================================================================
# SUMMARY REPORT
# ============================================================================

Write-Log "Generating summary report..." -Level Info
Write-Log "========================================" -Level Info
Write-Log "SUMMARY REPORT" -Level Info
Write-Log "========================================" -Level Info
Write-Log "Total computers: $totalCount" -Level Info
Write-Log "Successful: $successCount" -Level Success
Write-Log "Failed: $failureCount" -Level Error
if ($connectionFailures -gt 0) {
    Write-Log "Connection failures: $connectionFailures" -Level Warning
}
$successRate = if ($totalCount -gt 0) { [math]::Round(($successCount / $totalCount) * 100, 1) } else { 0 }
Write-Log "Success rate: $successRate%" -Level Info
Write-Log "Log file: $LogPath" -Level Info
Write-Log "Completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level Info
Write-Log "========================================" -Level Info

# Display console summary
Write-Host "`n" -NoNewline
Write-Host "╔════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║      VMware Tools Removal Summary      ║" -ForegroundColor Cyan
Write-Host "╠════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║ Total Hosts:    " -NoNewline -ForegroundColor Cyan
Write-Host ("{0,20}" -f $totalCount) -NoNewline -ForegroundColor White
Write-Host " ║" -ForegroundColor Cyan
Write-Host "║ Successful:     " -NoNewline -ForegroundColor Cyan
Write-Host ("{0,20}" -f $successCount) -NoNewline -ForegroundColor Green
Write-Host " ║" -ForegroundColor Cyan
Write-Host "║ Failed:         " -NoNewline -ForegroundColor Cyan
Write-Host ("{0,20}" -f $failureCount) -NoNewline -ForegroundColor Red
Write-Host " ║" -ForegroundColor Cyan
Write-Host "║ Success Rate:   " -NoNewline -ForegroundColor Cyan
Write-Host ("{0,19}%" -f $successRate) -NoNewline -ForegroundColor Yellow
Write-Host " ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "`nLog file: $LogPath" -ForegroundColor Gray
Write-Host "`nNote: Reboot target systems to complete VMware Tools removal.`n" -ForegroundColor Yellow

exit 0
