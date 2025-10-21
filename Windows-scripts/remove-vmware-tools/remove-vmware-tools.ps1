<#
.SYNOPSIS
  Run remove-vmware-tools.ps1 on multiple domain-joined hosts using PowerShell Remoting (WinRM, Kerberos).
.DESCRIPTION
  - Prompts for domain credential (masked)
  - Reads host list from a text file
  - Copies the cleanup script to C:\Temp on each remote computer
  - Executes the copied script on each remote computer using Invoke-Command
  - Optionally supports UseSSL if remote WinRM endpoints are HTTPS-enabled
  - Writes per-host logging to a log file
  - Includes connection testing and progress tracking
  - Handles multiple authentication scenarios automatically
.PARAMETER CleanupScriptPath
  Path to the local cleanup script to copy and execute on remote hosts
.PARAMETER ComputersFile
  Path to text file containing list of computers (one per line)
.PARAMETER LogFile
  Path to log file for output
.PARAMETER UseSSL
  Use HTTPS for WinRM connections
.PARAMETER PreferredAuth
  Preferred authentication method to try first
#>

param(
    [string]$CleanupScriptPath = "C:\Ankoji\remove-vmware-tools-winrm.ps1",
    [string]$ComputersFile = "C:\Ankoji\computers.txt",
    [string]$LogFile = "C:\Ankoji\vmware_cleanup_winrm.log",
    [switch]$UseSSL = $false,
    [ValidateSet('Kerberos', 'Negotiate', 'Auto')]
    [string]$PreferredAuth = 'Auto'
)

# --- CONFIGURATION ---
$cleanupScriptPath = $CleanupScriptPath
$computersFile     = $ComputersFile
$logFile           = $LogFile
$useSSL = $UseSSL.IsPresent
$preferredAuth = $PreferredAuth
$remoteScriptPath = "C:\Temp\remove-vmware-tools-winrm.ps1"  # Remote destination path

# --- PRECHECKS ---
if (-not (Test-Path -Path $cleanupScriptPath)) {
    Write-Error "Local cleanup script not found: $cleanupScriptPath`nPlease correct the path and re-run."
    exit 1
}
if (-not (Test-Path -Path $computersFile)) {
    Write-Error "Computers file not found: $computersFile`nPlease create it with one host/IP per line and re-run."
    exit 1
}

# --- PROMPT FOR CREDENTIALS (masked) ---
$cred = Get-Credential -Message "Enter domain credentials with local admin rights on target hosts"
if (-not $cred) {
    Write-Error "Credentials are required to proceed."
    exit 1
}

# --- READ COMPUTERS ---
$computers = Get-Content -Path $computersFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
if ($computers.Count -eq 0) {
    Write-Error "No hosts found in $computersFile"
    exit 1
}

# Ensure log folder exists
$logDir = Split-Path $logFile -Parent
if (-not (Test-Path $logDir)) { 
    try {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null 
    } catch {
        Write-Error "Failed to create log directory: $logDir. Error: $_"
        exit 1
    }
}

function Log {
    param($text)
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    try {
        # Use Out-File to prevent output stream contamination
        "$ts`t$text" | Out-File -FilePath $logFile -Append -Encoding UTF8
        Write-Host "$ts`t$text"
    } catch {
        Write-Warning "Failed to write to log file: $_"
        Write-Host "$ts`t$text"
    }
}

function Test-WinRMConnectivity {
    param(
        [string]$ComputerName,
        [pscredential]$Credential,
        [string]$PreferredAuthentication = 'Auto'
    )
    
    # Define authentication methods to try
    $authMethods = switch ($PreferredAuthentication) {
        'Kerberos' { @('Kerberos', 'Negotiate') }
        'Negotiate' { @('Negotiate', 'Kerberos') }
        'Auto' { @('Negotiate', 'Kerberos') }
        default { @('Negotiate', 'Kerberos') }
    }
    
    foreach ($authMethod in $authMethods) {
        try {
            Log "Testing WinRM connectivity to $ComputerName using $authMethod authentication..."
            
            # Test with a simple command instead of Test-WSMan
            $testResult = Invoke-Command -ComputerName $ComputerName -Credential $Credential -Authentication $authMethod -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
            
            Log "WinRM connectivity confirmed for $ComputerName using $authMethod authentication (returned: $testResult)"
            return $authMethod
            
        } catch {
            Log "Failed to connect to $ComputerName using $authMethod : $($_.Exception.Message)"
            continue
        }
    }
    
    # If all authentication methods fail, throw the last error
    throw "Cannot establish WinRM connection to $ComputerName with any supported authentication method"
}

function Execute-VMwareRemovalDirectly {
    param(
        [string]$ComputerName,
        [pscredential]$Credential,
        [string]$Authentication
    )
    
    try {
        Log "Executing VMware Tools removal directly on $ComputerName..."
        
        $vmwareRemovalScript = {
            # VMware Tools Removal Script - Embedded
            function Write-Log {
                param($Message, $Level = "INFO")
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                $logMessage = "[$timestamp] [$Level] $Message"
                Write-Output $logMessage
            }

            try {
                Write-Log "Starting VMware Tools removal on $env:COMPUTERNAME"
                
                # Method 1: Remove using WMI/Win32_Product
                Write-Log "Searching for VMware Tools using WMI..."
                $vmwareProducts = Get-WmiObject -Class Win32_Product | Where-Object { 
                    $_.Name -like "*VMware*" -and $_.Name -like "*Tools*" 
                }
                
                if ($vmwareProducts) {
                    foreach ($product in $vmwareProducts) {
                        Write-Log "Found VMware product: $($product.Name) - Version: $($product.Version)"
                        Write-Log "Attempting to uninstall: $($product.Name)"
                        
                        try {
                            $result = $product.Uninstall()
                            if ($result.ReturnValue -eq 0) {
                                Write-Log "Successfully uninstalled: $($product.Name)" "SUCCESS"
                            } else {
                                Write-Log "Uninstall failed with return code: $($result.ReturnValue)" "ERROR"
                            }
                        } catch {
                            Write-Log "Error uninstalling $($product.Name): $_" "ERROR"
                        }
                    }
                } else {
                    Write-Log "No VMware Tools found via WMI method"
                }
                
                # Method 2: Try using Get-Package (for newer systems)
                Write-Log "Searching for VMware Tools using Package Manager..."
                try {
                    $packageProducts = Get-Package | Where-Object { $_.Name -like "*VMware*Tools*" }
                    if ($packageProducts) {
                        foreach ($package in $packageProducts) {
                            Write-Log "Found package: $($package.Name) - Version: $($package.Version)"
                            try {
                                Uninstall-Package -Name $package.Name -Force
                                Write-Log "Successfully uninstalled package: $($package.Name)" "SUCCESS"
                            } catch {
                                Write-Log "Error uninstalling package $($package.Name): $_" "ERROR"
                            }
                        }
                    } else {
                        Write-Log "No VMware Tools found via Package Manager method"
                    }
                } catch {
                    Write-Log "Package Manager method not available: $_" "WARNING"
                }
                
                # Clean up VMware registry entries
                Write-Log "Cleaning up VMware registry entries..."
                $regPaths = @(
                    "HKLM:\SOFTWARE\VMware, Inc.",
                    "HKLM:\SOFTWARE\WOW6432Node\VMware, Inc."
                )
                
                foreach ($path in $regPaths) {
                    if (Test-Path $path) {
                        Write-Log "Removing registry path: $path"
                        try {
                            Remove-Item $path -Recurse -Force -ErrorAction Stop
                            Write-Log "Successfully removed registry path: $path" "SUCCESS"
                        } catch {
                            Write-Log "Failed to remove registry path $path : $_" "ERROR"
                        }
                    } else {
                        Write-Log "Registry path not found: $path"
                    }
                }
                
                # Clean up VMware services
                Write-Log "Stopping and removing VMware services..."
                $vmwareServices = Get-Service | Where-Object { 
                    $_.Name -like "*vmware*" -or $_.DisplayName -like "*vmware*" 
                }
                
                if ($vmwareServices) {
                    foreach ($service in $vmwareServices) {
                        Write-Log "Processing service: $($service.Name) ($($service.DisplayName))"
                        try {
                            if ($service.Status -eq 'Running') {
                                Stop-Service $service.Name -Force -ErrorAction Stop
                                Write-Log "Stopped service: $($service.Name)" "SUCCESS"
                            }
                            
                            # Remove service using sc.exe
                            $scResult = & sc.exe delete $service.Name 2>&1
                            if ($LASTEXITCODE -eq 0) {
                                Write-Log "Removed service: $($service.Name)" "SUCCESS"
                            } else {
                                Write-Log "Failed to remove service $($service.Name). Result: $scResult" "WARNING"
                            }
                        } catch {
                            Write-Log "Error processing service $($service.Name): $_" "ERROR"
                        }
                    }
                } else {
                    Write-Log "No VMware services found"
                }
                
                # Clean up VMware directories
                Write-Log "Cleaning up VMware directories..."
                $vmwarePaths = @(
                    "$env:ProgramFiles\VMware",
                    "${env:ProgramFiles(x86)}\VMware",
                    "$env:ProgramData\VMware",
                    "$env:APPDATA\VMware",
                    "$env:LOCALAPPDATA\VMware"
                )
                
                foreach ($path in $vmwarePaths) {
                    if (Test-Path $path) {
                        Write-Log "Removing directory: $path"
                        try {
                            Remove-Item $path -Recurse -Force -ErrorAction Stop
                            Write-Log "Successfully removed directory: $path" "SUCCESS"
                        } catch {
                            Write-Log "Failed to remove directory $path : $_" "ERROR"
                        }
                    } else {
                        Write-Log "Directory not found: $path"
                    }
                }
                
                Write-Log "VMware Tools cleanup completed on $env:COMPUTERNAME" "SUCCESS"
                Write-Log "Please reboot the system to complete the removal process" "INFO"
                return $true
                
            } catch {
                Write-Log "Critical error during VMware Tools removal: $_" "ERROR"
                return $false
            }
        }
        
        $invokeParams = @{
            ComputerName = $ComputerName
            Credential = $Credential
            Authentication = $Authentication
            ScriptBlock = $vmwareRemovalScript
            ErrorAction = 'Stop'
        }
        
        if ($useSSL) {
            $invokeParams['UseSSL'] = $true
        }

        $output = Invoke-Command @invokeParams

        if ($output) {
            foreach ($line in $output) {
                Log "$ComputerName`t$line"
            }
        } else {
            Log "$ComputerName`t(No output returned)"
        }

        return $true
        
    } catch {
        Log "ERROR: Failed to execute VMware removal on $ComputerName : $_"
        return $false
    }
}

Log "Starting WinRM multi-host VMware Tools cleanup. Host count: $($computers.Count)"
Log "Script path: $cleanupScriptPath"
Log "Remote script path: $remoteScriptPath"
Log "Use SSL: $useSSL"
Log "Preferred authentication: $preferredAuth"

# --- Execution: run script on each host ---
$processedCount = 0
$successCount = 0
$failureCount = 0
$totalCount = $computers.Count

foreach ($computer in $computers) {
    $processedCount++
    $percentComplete = [math]::Round(($processedCount / $totalCount) * 100, 1)
    
    Write-Progress -Activity "Processing VMware Tools Cleanup" -Status "Processing $computer" -PercentComplete $percentComplete -CurrentOperation "$processedCount of $totalCount hosts"
    
    Log "==== Processing $computer ($processedCount/$totalCount - $percentComplete%) ===="
    
    # Test WinRM connectivity and determine working authentication method
    try {
        $workingAuth = Test-WinRMConnectivity -ComputerName $computer -Credential $cred -PreferredAuthentication $preferredAuth
    } catch {
        Log "ERROR: Cannot reach $computer via WinRM: $_"
        $failureCount++
        continue
    }
    
    # Execute VMware removal directly (no file copying needed)
    try {
        $executionSuccess = Execute-VMwareRemovalDirectly -ComputerName $computer -Credential $cred -Authentication $workingAuth
        
        if ($executionSuccess) {
            Log "==== Completed cleanup on $computer ===="
            $successCount++
        } else {
            Log "ERROR: VMware removal failed on $computer"
            $failureCount++
        }
        
    } catch {
        Log "ERROR: Failed to execute VMware removal on $computer : $_"
        $failureCount++
    }
}

Write-Progress -Activity "Processing VMware Tools Cleanup" -Completed

# Summary statistics
Log "============================================"
Log "SUMMARY STATISTICS"
Log "============================================"
Log "Total hosts processed: $totalCount"
Log "Successful executions: $successCount"
Log "Failed executions: $failureCount"
Log "Success rate: $([math]::Round(($successCount / $totalCount) * 100, 1))%"
Log "All hosts processed. Script finished."

Write-Host "`nSummary:" -ForegroundColor Cyan
Write-Host "  Total hosts: $totalCount" -ForegroundColor White
Write-Host "  Successful: $successCount" -ForegroundColor Green
Write-Host "  Failed: $failureCount" -ForegroundColor Red
Write-Host "  Success rate: $([math]::Round(($successCount / $totalCount) * 100, 1))%" -ForegroundColor Yellow
Write-Host "  Log file: $logFile" -ForegroundColor Gray