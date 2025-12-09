<#
.SYNOPSIS
    Diagnostic script to check for VMware Tools remnants on a system.

.DESCRIPTION
    Scans multiple locations to detect VMware Tools installations and remnants:
    - Registry uninstall entries
    - Registry VMware keys
    - Services
    - Files and folders
    - PnP devices
    - Driver packages

.PARAMETER ComputerName
    Remote computer to diagnose. If not provided, runs on local computer.

.PARAMETER Credential
    Credentials for remote connection.

.EXAMPLE
    .\Diagnose-VMwareTools.ps1
    Run diagnostic on local computer.

.EXAMPLE
    .\Diagnose-VMwareTools.ps1 -ComputerName D2BDMAPWBSWV1 -Credential (Get-Credential)
    Run diagnostic on remote computer.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ComputerName,

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential
)

$diagnosticScript = {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "VMware Tools Diagnostic Report" -ForegroundColor Cyan
    Write-Host "Computer: $env:COMPUTERNAME" -ForegroundColor Cyan
    Write-Host "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    $foundItems = $false

    # 1. Check standard uninstall registry
    Write-Host "[1] Checking Uninstall Registry Keys..." -ForegroundColor Yellow
    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    
    $vmwareProducts = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
        Where-Object { 
            $_.DisplayName -like "*VMware*" -or 
            $_.Publisher -like "*VMware*"
        }
    
    if ($vmwareProducts) {
        $foundItems = $true
        Write-Host "  FOUND VMware products in Uninstall registry:" -ForegroundColor Red
        foreach ($product in $vmwareProducts) {
            Write-Host "    - $($product.DisplayName) v$($product.DisplayVersion)" -ForegroundColor White
            Write-Host "      Path: $($product.PSPath)" -ForegroundColor Gray
        }
    } else {
        Write-Host "  No VMware products found in Uninstall registry" -ForegroundColor Green
    }

    # 2. Check VMware, Inc. registry keys
    Write-Host "`n[2] Checking VMware, Inc. Registry Keys..." -ForegroundColor Yellow
    $vmwareRegPaths = @(
        'HKLM:\SOFTWARE\VMware, Inc.',
        'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.'
    )
    
    foreach ($path in $vmwareRegPaths) {
        if (Test-Path $path) {
            $foundItems = $true
            Write-Host "  FOUND: $path" -ForegroundColor Red
            try {
                $subKeys = Get-ChildItem $path -Recurse -ErrorAction SilentlyContinue | Select-Object -First 10
                foreach ($key in $subKeys) {
                    Write-Host "    - $($key.PSChildName)" -ForegroundColor White
                }
            } catch { }
        } else {
            Write-Host "  Not found: $path" -ForegroundColor Green
        }
    }

    # 3. Check Installer registry (HKCR)
    Write-Host "`n[3] Checking Installer Registry (HKCR)..." -ForegroundColor Yellow
    try {
        $hkcrProducts = Get-ChildItem 'Registry::HKEY_CLASSES_ROOT\Installer\Products' -ErrorAction SilentlyContinue
        $vmwareInstaller = $hkcrProducts | Where-Object {
            $productName = $_.GetValue('ProductName')
            $productName -like "*VMware*"
        }
        
        if ($vmwareInstaller) {
            $foundItems = $true
            Write-Host "  FOUND VMware in Installer Products:" -ForegroundColor Red
            foreach ($item in $vmwareInstaller) {
                $productName = $item.GetValue('ProductName')
                Write-Host "    - $productName" -ForegroundColor White
                Write-Host "      GUID: $($item.PSChildName)" -ForegroundColor Gray
            }
        } else {
            Write-Host "  No VMware entries in Installer Products" -ForegroundColor Green
        }
    } catch {
        Write-Host "  Unable to access HKCR Installer: $_" -ForegroundColor Yellow
    }

    # 4. Check VMware services
    Write-Host "`n[4] Checking VMware Services..." -ForegroundColor Yellow
    $vmwareServices = Get-Service -ErrorAction SilentlyContinue | 
        Where-Object { 
            $_.Name -like "*vmware*" -or 
            $_.DisplayName -like "*vmware*" -or
            $_.Name -eq "GISvc"
        }
    
    if ($vmwareServices) {
        $foundItems = $true
        Write-Host "  FOUND VMware services:" -ForegroundColor Red
        foreach ($service in $vmwareServices) {
            Write-Host "    - $($service.Name) ($($service.DisplayName)) - Status: $($service.Status)" -ForegroundColor White
        }
    } else {
        Write-Host "  No VMware services found" -ForegroundColor Green
    }

    # 5. Check VMware directories
    Write-Host "`n[5] Checking VMware Directories..." -ForegroundColor Yellow
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
            $foundItems = $true
            $items = Get-ChildItem $dir -ErrorAction SilentlyContinue | Select-Object -First 5
            Write-Host "  FOUND: $dir" -ForegroundColor Red
            if ($items) {
                Write-Host "    Contents:" -ForegroundColor White
                foreach ($item in $items) {
                    Write-Host "      - $($item.Name)" -ForegroundColor Gray
                }
            }
        } else {
            Write-Host "  Not found: $dir" -ForegroundColor Green
        }
    }

    # 6. Check VMware PnP devices
    Write-Host "`n[6] Checking VMware PnP Devices..." -ForegroundColor Yellow
    try {
        $vmwareDevices = Get-PnpDevice -ErrorAction SilentlyContinue | 
            Where-Object { $_.FriendlyName -like "*VMware*" }
        
        if ($vmwareDevices) {
            $foundItems = $true
            Write-Host "  FOUND VMware devices:" -ForegroundColor Red
            foreach ($device in $vmwareDevices) {
                Write-Host "    - $($device.FriendlyName) - Status: $($device.Status)" -ForegroundColor White
            }
        } else {
            Write-Host "  No VMware PnP devices found" -ForegroundColor Green
        }
    } catch {
        Write-Host "  Unable to query PnP devices: $_" -ForegroundColor Yellow
    }

    # 7. Check VMware drivers
    Write-Host "`n[7] Checking VMware Driver Packages..." -ForegroundColor Yellow
    try {
        $pnpOutput = & pnputil.exe /enum-drivers 2>&1
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
        
        if ($vmwareDrivers.Count -gt 0) {
            $foundItems = $true
            Write-Host "  FOUND VMware drivers:" -ForegroundColor Red
            foreach ($driver in $vmwareDrivers) {
                Write-Host "    - $driver" -ForegroundColor White
            }
        } else {
            Write-Host "  No VMware driver packages found" -ForegroundColor Green
        }
    } catch {
        Write-Host "  Unable to enumerate drivers: $_" -ForegroundColor Yellow
    }

    # 8. Check using Get-Package
    Write-Host "`n[8] Checking via Get-Package..." -ForegroundColor Yellow
    try {
        $packages = Get-Package -Name "*VMware*" -ErrorAction SilentlyContinue
        if ($packages) {
            $foundItems = $true
            Write-Host "  FOUND VMware packages:" -ForegroundColor Red
            foreach ($package in $packages) {
                Write-Host "    - $($package.Name) v$($package.Version)" -ForegroundColor White
            }
        } else {
            Write-Host "  No VMware packages found" -ForegroundColor Green
        }
    } catch {
        Write-Host "  Get-Package not available or failed" -ForegroundColor Yellow
    }

    # Summary
    Write-Host "`n========================================" -ForegroundColor Cyan
    if ($foundItems) {
        Write-Host "RESULT: VMware Tools remnants FOUND on this system" -ForegroundColor Red
        Write-Host "Run Remove-VMwareTools.ps1 to clean up" -ForegroundColor Yellow
    } else {
        Write-Host "RESULT: No VMware Tools detected on this system" -ForegroundColor Green
    }
    Write-Host "========================================`n" -ForegroundColor Cyan

    return $foundItems
}

# Execute diagnostic
if ($ComputerName) {
    Write-Host "Running diagnostic on remote computer: $ComputerName" -ForegroundColor Cyan
    
    if (-not $Credential) {
        $Credential = Get-Credential -Message "Enter credentials for $ComputerName"
    }
    
    try {
        $result = Invoke-Command -ComputerName $ComputerName -Credential $Credential -ScriptBlock $diagnosticScript -ErrorAction Stop
        
        if ($result) {
            Write-Host "`nVMware remnants detected on $ComputerName" -ForegroundColor Red
        } else {
            Write-Host "`nNo VMware remnants detected on $ComputerName" -ForegroundColor Green
        }
    } catch {
        Write-Host "Error connecting to ${ComputerName}: $_" -ForegroundColor Red
    }
} else {
    Write-Host "Running diagnostic on local computer..." -ForegroundColor Cyan
    $result = & $diagnosticScript
}
