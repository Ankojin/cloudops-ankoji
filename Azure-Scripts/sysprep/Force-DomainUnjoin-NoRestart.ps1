<#
.SYNOPSIS
    Force domain unjoin and cleanup WITHOUT internal restarts

.DESCRIPTION
    This script ONLY does cleanup - NO RESTART COMMANDS.
    After running this, you must manually restart the VM from Azure.
    
    Operations:
    1. Force registry-based domain unjoin
    2. Delete user profiles  
    3. Disable services
    4. Cleanup temp files
    
    DOES NOT CALL: Remove-Computer, Restart-Computer, or any restart

.PARAMETER VMName
    Target VM name

.PARAMETER ResourceGroupName
    Resource group

.PARAMETER SubscriptionId
    Subscription ID

.EXAMPLE
    # Step 1: Run cleanup
    .\Force-DomainUnjoin-NoRestart.ps1 -VMName "BABAVDSHDTA-1-v4" -ResourceGroupName "..." -SubscriptionId "..."
    
    # Step 2: Restart from Azure
    Restart-AzVM -ResourceGroupName "..." -Name "BABAVDSHDTA-1-v4"
    
    # Step 3: Verify
    .\Verify-VMState.ps1 -VMName "BABAVDSHDTA-1-v4" -ResourceGroupName "..." -SubscriptionId "..."
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId
)

Write-Host "=== FORCE DOMAIN UNJOIN (NO RESTART) ===" -ForegroundColor Cyan
Write-Host "VM: $VMName" -ForegroundColor White

# Set context
$null = Set-AzContext -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue

# Cleanup script - NO RESTART COMMANDS
$cleanupScript = @'
Write-Host "=== FORCE DOMAIN UNJOIN - REGISTRY ONLY ===" -ForegroundColor Cyan

# Check current state
$computerInfo = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
Write-Host "Current domain status:"
Write-Host "  PartOfDomain: $($computerInfo.PartOfDomain)"
Write-Host "  Domain: $($computerInfo.Domain)"
Write-Host "  Workgroup: $($computerInfo.Workgroup)"

# FORCE REGISTRY-ONLY DOMAIN UNJOIN (no network, no Remove-Computer)
Write-Host "`n1. Clearing domain from registry..." -ForegroundColor Yellow

# Clear all domain-related registry keys
$regChanges = 0

# TCP/IP Parameters
try {
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "Domain" -Value "" -Force
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "NV Domain" -Value "" -Force
    Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "DhcpDomain" -Force -ErrorAction SilentlyContinue
    $regChanges++
    Write-Host "  ✓ TCP/IP domain cleared"
} catch {
    Write-Host "  ⚠ TCP/IP: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Computer Name - Active
try {
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -Name "Domain" -Value "" -Force
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -Name "DomainName" -Value "" -Force -ErrorAction SilentlyContinue
    $regChanges++
    Write-Host "  ✓ Active computer name domain cleared"
} catch {
    Write-Host "  ⚠ ActiveName: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Computer Name - Standard
try {
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -Name "Domain" -Value "" -Force
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -Name "DomainName" -Value "" -Force -ErrorAction SilentlyContinue
    $regChanges++
    Write-Host "  ✓ Computer name domain cleared"
} catch {
    Write-Host "  ⚠ ComputerName: $($_.Exception.Message)" -ForegroundColor Yellow
}

# LSA Secrets (domain credentials)
try {
    & reg.exe delete "HKLM\SECURITY\Policy\Secrets\$MACHINE.ACC" /f 2>$null | Out-Null
    Write-Host "  ✓ LSA secrets cleared"
} catch {
    Write-Host "  ⚠ LSA secrets: might not exist" -ForegroundColor Gray
}

Write-Host "  Registry changes made: $regChanges"

# Disable Netlogon service
Write-Host "`n2. Disabling Netlogon service..." -ForegroundColor Yellow
try {
    Stop-Service -Name Netlogon -Force -ErrorAction SilentlyContinue
    Set-Service -Name Netlogon -StartupType Disabled -ErrorAction Stop
    Write-Host "  ✓ Netlogon disabled"
} catch {
    Write-Host "  ⚠ Netlogon: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Force delete user profiles
Write-Host "`n3. Deleting user profiles..." -ForegroundColor Yellow

$allProfiles = Get-WmiObject -Class Win32_UserProfile -ErrorAction SilentlyContinue
$userProfiles = $allProfiles | Where-Object { 
    -not $_.Special -and 
    $_.LocalPath -notlike "*\Administrator*" -and
    $_.LocalPath -notlike "*\Default*" -and
    $_.LocalPath -notlike "*\Public" -and
    $_.LocalPath -notlike "*\systemprofile*" -and
    $_.LocalPath -notlike "*\LocalService*" -and
    $_.LocalPath -notlike "*\NetworkService*"
}

Write-Host "  Found $($userProfiles.Count) user profiles to remove"

$removed = 0
$failed = 0

foreach ($profile in $userProfiles) {
    $path = $profile.LocalPath
    Write-Host "    Removing: $path" -NoNewline
    
    if ($profile.Loaded) {
        Write-Host " [SKIPPED - LOADED]" -ForegroundColor Red
        $failed++
        continue
    }
    
    try {
        # Try WMI delete first
        $profile.Delete()
        Start-Sleep -Milliseconds 200
        
        # Verify deletion
        if (Test-Path $path) {
            # WMI failed, force manual deletion
            & takeown.exe /f "$path" /r /d Y 2>&1 | Out-Null
            & icacls.exe "$path" /grant "Administrators:(OI)(CI)F" /t /c /q 2>&1 | Out-Null
            Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
        }
        
        # Remove registry entry
        $sid = $profile.SID
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
        if (Test-Path $regPath) {
            Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        
        Write-Host " ✓" -ForegroundColor Green
        $removed++
    }
    catch {
        Write-Host " ✗ ($($_.Exception.Message.Substring(0, [Math]::Min(40, $_.Exception.Message.Length))))" -ForegroundColor Red
        $failed++
    }
}

Write-Host "  Profiles removed: $removed, Failed: $failed"

# Remove AppX packages
Write-Host "`n4. Removing AppX packages..." -ForegroundColor Yellow
$appxRemoved = 0
$appxSkipped = 0

try {
    $userAppxPackages = Get-AppxPackage -AllUsers | Where-Object { 
        -not $_.IsFramework -and 
        -not $_.IsBundle -and
        $_.Name -notlike "*Windows.Photos*" -and 
        $_.Name -notlike "*WindowsCalculator*" -and
        $_.Name -notlike "*WindowsStore*" -and
        $_.Name -notlike "*VCLibs*" -and
        $_.Name -notlike "*NET.Native*" -and
        $_.Name -notlike "*Microsoft.UI*" -and
        $_.Name -notlike "*DesktopAppInstaller*"
    }
    
    foreach ($app in $userAppxPackages) {
        try {
            Remove-AppxPackage -Package $app.PackageFullName -AllUsers -ErrorAction Stop
            $appxRemoved++
        }
        catch {
            $appxSkipped++
        }
    }
    
    Write-Host "  AppX removed: $appxRemoved, Skipped: $appxSkipped"
}
catch {
    Write-Host "  ⚠ AppX cleanup error: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Cleanup temp files
Write-Host "`n5. Cleaning temp files..." -ForegroundColor Yellow
$cleaned = 0
$tempPaths = @(
    "$env:SystemRoot\Temp",
    "C:\Windows\Prefetch",
    "C:\Windows\SoftwareDistribution\Download",
    "C:\Windows\System32\Sysprep\Panther"
)

foreach ($path in $tempPaths) {
    if (Test-Path $path) {
        try {
            Remove-Item "$path\*" -Recurse -Force -ErrorAction SilentlyContinue
            $cleaned++
        } catch {}
    }
}
Write-Host "  Cleaned $cleaned temp locations"

# Disable Windows Update
Write-Host "`n6. Disabling Windows Update..." -ForegroundColor Yellow
try {
    Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
    Set-Service -Name wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Host "  ✓ Windows Update disabled"
} catch {
    Write-Host "  ⚠ Windows Update: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host "`n=== CLEANUP COMPLETE ===" -ForegroundColor Green
Write-Host "Registry changes: $regChanges" -ForegroundColor Green
Write-Host "Profiles removed: $removed" -ForegroundColor Green
Write-Host "AppX removed: $appxRemoved" -ForegroundColor Green
Write-Host "`n⚠️  YOU MUST NOW RESTART THE VM FROM AZURE" -ForegroundColor Yellow
Write-Host "Use: Restart-AzVM -ResourceGroupName '...' -Name '$env:COMPUTERNAME'" -ForegroundColor Yellow
'@

Write-Host "`nRunning cleanup (NO restart will occur)..." -ForegroundColor Yellow

try {
    $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName `
        -VMName $VMName `
        -CommandId 'RunPowerShellScript' `
        -ScriptString $cleanupScript `
        -ErrorAction Stop
    
    Write-Host "`n--- CLEANUP OUTPUT ---" -ForegroundColor Cyan
    Write-Host $result.Value[0].Message
    
    Write-Host "`n=== NEXT STEPS ===" -ForegroundColor Yellow
    Write-Host "1. Restart the VM from Azure:" -ForegroundColor White
    Write-Host "   Restart-AzVM -ResourceGroupName '$ResourceGroupName' -Name '$VMName'" -ForegroundColor Cyan
    Write-Host "`n2. Wait 2 minutes for VM to restart and stabilize" -ForegroundColor White
    Write-Host "`n3. Verify the domain unjoin:" -ForegroundColor White
    Write-Host "   .\Verify-VMState.ps1 -VMName '$VMName' -ResourceGroupName '$ResourceGroupName' -SubscriptionId '$SubscriptionId'" -ForegroundColor Cyan
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
