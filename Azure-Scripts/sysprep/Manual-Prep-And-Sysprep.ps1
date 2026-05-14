<#
.SYNOPSIS
    Manual AVD image preparation and sysprep script - RUN DIRECTLY ON VM

.DESCRIPTION
    Run this script directly on the AVD VM (via RDP or console) to:
    1. Force domain unjoin (registry-only, no DC contact)
    2. Delete all user profiles
    3. Clean temp files and AppX packages
    4. Verify readiness
    5. Run sysprep with unattend.xml
    
    MUST RUN AS ADMINISTRATOR

.EXAMPLE
    # RDP to the VM, open PowerShell as Administrator, then run:
    .\Manual-Prep-And-Sysprep.ps1
    
    # Or with auto-confirmation:
    .\Manual-Prep-And-Sysprep.ps1 -AutoConfirm
    
    # Skip AppX removal (faster, but larger image):
    .\Manual-Prep-And-Sysprep.ps1 -SkipAppxRemoval

.NOTES
    Author: BAB CloudOps Team
    Date: April 2026
    
    CRITICAL: 
    - Run as Administrator
    - Log off all users before running
    - VM will shut down after sysprep completes
    - Sysprep limit is 3 runs per installation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$AutoConfirm,
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipDomainUnjoin,
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipProfileCleanup,
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipAppxRemoval,
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipSysprep
)

# Ensure running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator!" -ForegroundColor Red
    Write-Host "Right-click PowerShell and select 'Run as Administrator'" -ForegroundColor Yellow
    exit 1
}

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  MANUAL AVD IMAGE PREPARATION AND SYSPREP                  ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# Create transcript log
$logPath = "C:\AVD-Prep-Log-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
Start-Transcript -Path $logPath
Write-Host "Transcript logging to: $logPath`n" -ForegroundColor Gray

#region Pre-Flight Checks

Write-Host "═══ PRE-FLIGHT CHECKS ═══`n" -ForegroundColor Yellow

# Check 1: Current domain status
Write-Host "[1/5] Checking domain status..." -ForegroundColor Cyan
$computerInfo = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
Write-Host "  Domain-joined: $($computerInfo.PartOfDomain)" -ForegroundColor $(if ($computerInfo.PartOfDomain) { "Red" } else { "Green" })
if ($computerInfo.PartOfDomain) {
    Write-Host "  Domain: $($computerInfo.Domain)" -ForegroundColor Yellow
}

# Check 2: Logged in users
Write-Host "`n[2/5] Checking for logged-in users..." -ForegroundColor Cyan
$loggedInUsers = quser 2>$null | Select-Object -Skip 1
if ($loggedInUsers) {
    Write-Host "  ⚠️  WARNING: Users are currently logged in!" -ForegroundColor Red
    $loggedInUsers | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    Write-Host "  These users should log off before continuing!" -ForegroundColor Yellow
}
else {
    Write-Host "  ✓ No users logged in (good)" -ForegroundColor Green
}

# Check 3: Sysprep run count
Write-Host "`n[3/5] Checking sysprep run count..." -ForegroundColor Cyan
$sysprepCount = 0
$sysprepRegPath = "HKLM:\SYSTEM\Setup\Status\SysprepStatus"
if (Test-Path $sysprepRegPath) {
    $sysprepCount = (Get-ItemProperty -Path $sysprepRegPath -Name "GeneralizationState" -ErrorAction SilentlyContinue).GeneralizationState
    if ($sysprepCount -eq $null) { $sysprepCount = 0 }
}
Write-Host "  Sysprep count: $sysprepCount / 3" -ForegroundColor $(if ($sysprepCount -ge 3) { "Red" } elseif ($sysprepCount -ge 2) { "Yellow" } else { "Green" })
if ($sysprepCount -ge 3) {
    Write-Host "  ❌ CRITICAL: Sysprep limit reached! This VM cannot be sysprepped again!" -ForegroundColor Red
    if (-not $AutoConfirm) {
        $continue = Read-Host "Continue anyway? (yes/no)"
        if ($continue -ne "yes") { exit 1 }
    }
}

# Check 4: User profiles count
Write-Host "`n[4/5] Checking user profiles..." -ForegroundColor Cyan
$allProfiles = Get-WmiObject -Class Win32_UserProfile -ErrorAction SilentlyContinue
$userProfiles = $allProfiles | Where-Object { 
    -not $_.Special -and 
    $_.LocalPath -notlike "*\azureadmin*" -and
    $_.LocalPath -notlike "*\avdadmin*" -and
    $_.LocalPath -notlike "*\Default*" -and
    $_.LocalPath -notlike "*\Public" -and
    $_.LocalPath -notlike "*\systemprofile*" -and
    $_.LocalPath -notlike "*\LocalService*" -and
    $_.LocalPath -notlike "*\NetworkService*"
}
Write-Host "  User profiles found: $($userProfiles.Count)" -ForegroundColor $(if ($userProfiles.Count -gt 0) { "Yellow" } else { "Green" })
if ($userProfiles.Count -gt 0) {
    Write-Host "  Loaded profiles: $(($userProfiles | Where-Object { $_.Loaded }).Count)" -ForegroundColor $(if (($userProfiles | Where-Object { $_.Loaded }).Count -gt 0) { "Red" } else { "Yellow" })
}

# Check 5: Available disk space
Write-Host "`n[5/5] Checking disk space..." -ForegroundColor Cyan
$osDrive = Get-PSDrive -Name C
$freeGB = [math]::Round($osDrive.Free / 1GB, 2)
Write-Host "  Free space: $freeGB GB" -ForegroundColor $(if ($freeGB -lt 10) { "Red" } elseif ($freeGB -lt 20) { "Yellow" } else { "Green" })

Write-Host "`n═══════════════════════════════════════════════════════════`n" -ForegroundColor Yellow

if (-not $AutoConfirm) {
    $proceed = Read-Host "Proceed with preparation? (yes/no)"
    if ($proceed -ne "yes") {
        Write-Host "Aborted by user" -ForegroundColor Yellow
        Stop-Transcript
        exit 0
    }
}

#endregion

#region Step 1: Force Domain Unjoin

if (-not $SkipDomainUnjoin) {
    Write-Host "`n═══ STEP 1: FORCE DOMAIN UNJOIN ═══`n" -ForegroundColor Yellow
    
    if ($computerInfo.PartOfDomain) {
        Write-Host "VM is domain-joined to: $($computerInfo.Domain)" -ForegroundColor Yellow
        Write-Host "Performing registry-only domain removal (no DC contact)...`n" -ForegroundColor Cyan
        
        $regChanges = 0
        
        # Clear TCP/IP domain parameters
        Write-Host "  [1/7] Clearing TCP/IP domain parameters..." -NoNewline
        try {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "Domain" -Value "" -Force -ErrorAction Stop
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "NV Domain" -Value "" -Force -ErrorAction Stop
            Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "DhcpDomain" -Force -ErrorAction SilentlyContinue
            Write-Host " ✓" -ForegroundColor Green
            $regChanges++
        }
        catch {
            Write-Host " ✗" -ForegroundColor Red
        }
        
        # Clear Active ComputerName domain
        Write-Host "  [2/7] Clearing Active ComputerName domain..." -NoNewline
        try {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -Name "Domain" -Value "" -Force -ErrorAction Stop
            Write-Host " ✓" -ForegroundColor Green
            $regChanges++
        }
        catch {
            Write-Host " ✗" -ForegroundColor Red
        }
        
        # Clear ComputerName domain
        Write-Host "  [3/7] Clearing ComputerName domain..." -NoNewline
        try {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -Name "Domain" -Value "" -Force -ErrorAction Stop
            Write-Host " ✓" -ForegroundColor Green
            $regChanges++
        }
        catch {
            Write-Host " ✗" -ForegroundColor Red
        }
        
        # Clear LSA secrets
        Write-Host "  [4/7] Clearing LSA domain secrets..." -NoNewline
        try {
            & reg.exe delete "HKLM\SECURITY\Policy\Secrets\$MACHINE.ACC" /f 2>$null | Out-Null
            Write-Host " ✓" -ForegroundColor Green
        }
        catch {
            Write-Host " ⊙" -ForegroundColor Gray
        }
        
        # Clear cached credentials
        Write-Host "  [5/7] Clearing cached domain credentials..." -NoNewline
        try {
            & cmdkey.exe /list 2>&1 | Where-Object {$_ -like "*Target:*"} | ForEach-Object {
                $target = $_.Split("Target: ")[1]
                if ($target) {
                    & cmdkey.exe /delete:$target 2>&1 | Out-Null
                }
            }
            Write-Host " ✓" -ForegroundColor Green
        }
        catch {
            Write-Host " ⊙" -ForegroundColor Gray
        }
        
        # Disable Netlogon
        Write-Host "  [6/7] Disabling Netlogon service..." -NoNewline
        try {
            Stop-Service -Name Netlogon -Force -ErrorAction SilentlyContinue
            Set-Service -Name Netlogon -StartupType Disabled -ErrorAction Stop
            Write-Host " ✓" -ForegroundColor Green
        }
        catch {
            Write-Host " ✗" -ForegroundColor Red
        }
        
        # Disable Windows Update
        Write-Host "  [7/7] Disabling Windows Update..." -NoNewline
        try {
            Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
            Set-Service -Name wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Host " ✓" -ForegroundColor Green
        }
        catch {
            Write-Host " ✗" -ForegroundColor Red
        }
        
        Write-Host "`n  Registry changes applied: $regChanges" -ForegroundColor Green
        Write-Host "  ⚠️  Restart required for domain unjoin to take effect!" -ForegroundColor Yellow
        
        if (-not $AutoConfirm) {
            $restart = Read-Host "`nRestart now? (yes/no)"
            if ($restart -eq "yes") {
                Write-Host "Restarting in 10 seconds..." -ForegroundColor Yellow
                Write-Host "Re-run this script after restart to continue." -ForegroundColor Cyan
                Stop-Transcript
                Start-Sleep -Seconds 10
                Restart-Computer -Force
                exit 0
            }
            else {
                Write-Host "Please restart manually and re-run this script." -ForegroundColor Yellow
                Stop-Transcript
                exit 0
            }
        }
    }
    else {
        Write-Host "✓ VM is already in workgroup (not domain-joined)" -ForegroundColor Green
    }
}

#endregion

#region Step 2: Delete User Profiles

if (-not $SkipProfileCleanup) {
    Write-Host "`n═══ STEP 2: DELETE USER PROFILES ═══`n" -ForegroundColor Yellow
    
    $userProfiles = $allProfiles | Where-Object { 
        -not $_.Special -and 
        $_.LocalPath -notlike "*\Administrator*" -and
        $_.LocalPath -notlike "*\Default*" -and
        $_.LocalPath -notlike "*\Public" -and
        $_.LocalPath -notlike "*\systemprofile*" -and
        $_.LocalPath -notlike "*\LocalService*" -and
        $_.LocalPath -notlike "*\NetworkService*"
    }
    
    Write-Host "Found $($userProfiles.Count) user profiles to remove`n" -ForegroundColor Cyan
    
    if ($userProfiles.Count -eq 0) {
        Write-Host "✓ No user profiles to remove" -ForegroundColor Green
    }
    else {
        $removed = 0
        $skipped = 0
        $failed = 0
        
        foreach ($profile in $userProfiles) {
            $path = $profile.LocalPath
            $username = Split-Path $path -Leaf
            Write-Host "  [$($removed + $skipped + $failed + 1)/$($userProfiles.Count)] $username" -NoNewline
            
            # Skip loaded profiles
            if ($profile.Loaded) {
                Write-Host " [SKIPPED - LOGGED IN]" -ForegroundColor Red
                $skipped++
                continue
            }
            
            try {
                # Method 1: WMI Delete
                $profile.Delete()
                Start-Sleep -Milliseconds 300
                
                # Verify folder deleted
                if (Test-Path $path) {
                    # Method 2: Force takeown and delete
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
                
                # Double-check deletion
                if (-not (Test-Path $path)) {
                    Write-Host " ✓" -ForegroundColor Green
                    $removed++
                }
                else {
                    Write-Host " ⚠ (folder remains)" -ForegroundColor Yellow
                    $failed++
                }
            }
            catch {
                Write-Host " ✗ ($($_.Exception.Message.Substring(0, [Math]::Min(30, $_.Exception.Message.Length))))" -ForegroundColor Red
                $failed++
            }
        }
        
        Write-Host "`n  Summary:" -ForegroundColor Cyan
        Write-Host "    Removed: $removed" -ForegroundColor Green
        Write-Host "    Skipped: $skipped (loaded profiles)" -ForegroundColor Yellow
        Write-Host "    Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Gray" })
    }
}

#endregion

#region Step 3: Remove AppX Packages

if (-not $SkipAppxRemoval) {
    Write-Host "`n═══ STEP 3: REMOVE APPX PACKAGES ═══`n" -ForegroundColor Yellow

    $appxRemoved = 0
    $appxProtected = 0
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
    
    Write-Host "Found $($userAppxPackages.Count) AppX packages to remove`n" -ForegroundColor Cyan
    
    $counter = 0
    foreach ($app in $userAppxPackages) {
        $counter++
        Write-Host "  [$counter/$($userAppxPackages.Count)] $($app.Name)" -NoNewline
        
        try {
            Remove-AppxPackage -Package $app.PackageFullName -AllUsers -ErrorAction Stop
            Write-Host " ✓" -ForegroundColor Green
            $appxRemoved++
        }
        catch {
            if ($_.Exception.Message -match "0x80070032" -or $_.Exception.Message -match "deployment") {
                Write-Host " ⊙" -ForegroundColor Gray
                $appxProtected++
            }
            else {
                Write-Host " ✗" -ForegroundColor Yellow
                $appxSkipped++
            }
        }
    }
    
    Write-Host "`n  Summary:" -ForegroundColor Cyan
    Write-Host "    Removed: $appxRemoved" -ForegroundColor Green
    Write-Host "    Protected: $appxProtected (system packages)" -ForegroundColor Gray
    }
    catch {
        Write-Host "  ✗ AppX cleanup failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}
else {
    Write-Host "`n═══ STEP 3: REMOVE APPX PACKAGES (SKIPPED) ═══`n" -ForegroundColor Gray
    Write-Host "  AppX removal skipped - packages will remain in image" -ForegroundColor Yellow
    Write-Host "  ✗ AppX cleanup failed: $($_.Exception.Message)" -ForegroundColor Red
}

#endregion

#region Step 4: Clean Temp Files

Write-Host "`n═══ STEP 4: CLEAN TEMP FILES ═══`n" -ForegroundColor Yellow

$cleanedLocations = 0
$tempPaths = @(
    @{ Path = "$env:SystemRoot\Temp"; Name = "Windows Temp" },
    @{ Path = "C:\Windows\Prefetch"; Name = "Prefetch" },
    @{ Path = "C:\Windows\SoftwareDistribution\Download"; Name = "Windows Update" },
    @{ Path = "C:\Windows\System32\Sysprep\Panther"; Name = "Sysprep Panther" },
    @{ Path = "C:\Windows\Panther"; Name = "Windows Panther" }
)

foreach ($item in $tempPaths) {
    Write-Host "  Cleaning $($item.Name)..." -NoNewline
    if (Test-Path $item.Path) {
        try {
            Remove-Item "$($item.Path)\*" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host " ✓" -ForegroundColor Green
            $cleanedLocations++
        }
        catch {
            Write-Host " ⊙" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host " [not found]" -ForegroundColor Gray
    }
}

# Clear event logs
Write-Host "  Clearing event logs..." -NoNewline
try {
    $eventLogs = wevtutil el
    $cleared = 0
    foreach ($log in $eventLogs) {
        wevtutil cl $log 2>$null
        if ($?) { $cleared++ }
    }
    Write-Host " ✓ ($cleared logs)" -ForegroundColor Green
}
catch {
    Write-Host " ⊙" -ForegroundColor Yellow
}

Write-Host "`n  Cleaned $cleanedLocations locations" -ForegroundColor Green

#endregion

#region Step 5: Pre-Sysprep Verification

Write-Host "`n═══ STEP 5: PRE-SYSPREP VERIFICATION ═══`n" -ForegroundColor Yellow

$issues = @()

# Check domain status
$computerInfo = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
Write-Host "  [1/4] Domain status..." -NoNewline
if ($computerInfo.PartOfDomain) {
    Write-Host " ❌ STILL DOMAIN-JOINED" -ForegroundColor Red
    $issues += "VM is still domain-joined to $($computerInfo.Domain)"
}
else {
    Write-Host " ✓ Workgroup" -ForegroundColor Green
}

# Check user profiles
$remainingProfiles = Get-WmiObject -Class Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { 
    -not $_.Special -and 
    $_.LocalPath -notlike "*\Administrator*" -and
    $_.LocalPath -notlike "*\Default*" -and
    $_.LocalPath -notlike "*\Public" -and
    $_.LocalPath -notlike "*\systemprofile*" -and
    $_.LocalPath -notlike "*\LocalService*" -and
    $_.LocalPath -notlike "*\NetworkService*"
}
Write-Host "  [2/4] User profiles..." -NoNewline
if ($remainingProfiles.Count -gt 0) {
    Write-Host " ⚠️  $($remainingProfiles.Count) remain" -ForegroundColor Yellow
    $issues += "$($remainingProfiles.Count) user profiles still present"
}
else {
    Write-Host " ✓ None" -ForegroundColor Green
}

# Check loaded profiles
$loadedProfiles = $remainingProfiles | Where-Object { $_.Loaded }
Write-Host "  [3/4] Loaded profiles..." -NoNewline
if ($loadedProfiles.Count -gt 0) {
    Write-Host " ❌ $($loadedProfiles.Count) users logged in" -ForegroundColor Red
    $issues += "$($loadedProfiles.Count) users are currently logged in"
}
else {
    Write-Host " ✓ None" -ForegroundColor Green
}

# Check sysprep count
Write-Host "  [4/4] Sysprep count..." -NoNewline
if ($sysprepCount -ge 3) {
    Write-Host " ❌ Limit reached ($sysprepCount/3)" -ForegroundColor Red
    $issues += "Sysprep limit exceeded ($sysprepCount runs)"
}
elseif ($sysprepCount -ge 2) {
    Write-Host " ⚠️  $sysprepCount/3 (last chance!)" -ForegroundColor Yellow
}
else {
    Write-Host " ✓ $sysprepCount/3" -ForegroundColor Green
}

if ($issues.Count -gt 0) {
    Write-Host "`n  ⚠️  Issues found:" -ForegroundColor Yellow
    foreach ($issue in $issues) {
        Write-Host "     • $issue" -ForegroundColor Yellow
    }
    
    if (-not $AutoConfirm) {
        Write-Host ""
        $proceed = Read-Host "  Continue with sysprep anyway? (yes/no)"
        if ($proceed -ne "yes") {
            Write-Host "`nAborted by user. Please fix issues and re-run." -ForegroundColor Yellow
            Stop-Transcript
            exit 1
        }
    }
}
else {
    Write-Host "`n  ✅ All checks passed - ready for sysprep!" -ForegroundColor Green
}

#endregion

#region Step 6: Run Sysprep

if (-not $SkipSysprep) {
    Write-Host "`n═══ STEP 6: RUN SYSPREP ═══`n" -ForegroundColor Yellow
    
    # Verify sysprep.exe exists
    $sysprepPath = "C:\Windows\System32\Sysprep\Sysprep.exe"
    if (-not (Test-Path $sysprepPath)) {
        Write-Host "❌ ERROR: Sysprep.exe not found at $sysprepPath" -ForegroundColor Red
        Stop-Transcript
        exit 1
    }
    
    # Create unattend.xml
    Write-Host "Creating unattend.xml..." -ForegroundColor Cyan
    $unattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
            </OOBE>
            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Name>azureadmin</Name>
                        <Group>Administrators</Group>
                        <Password>
                            <Value>yldED0Ratrequt456E3u</Value>
                            <PlainText>false</PlainText>
                        </Password>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
            <AutoLogon>
                <Enabled>false</Enabled>
            </AutoLogon>
            <TimeZone>UTC</TimeZone>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <ComputerName>*</ComputerName>
        </component>
    </settings>
</unattend>
"@
    
    $unattendPath = "C:\Windows\System32\Sysprep\unattend.xml"
    try {
        Set-Content -Path $unattendPath -Value $unattendXml -Force
        Write-Host "  ✓ Unattend.xml created at $unattendPath" -ForegroundColor Green
    }
    catch {
        Write-Host "  ✗ Failed to create unattend.xml: $($_.Exception.Message)" -ForegroundColor Red
        Stop-Transcript
        exit 1
    }
    
    # Final warning
    Write-Host "`n⚠️  FINAL WARNING:" -ForegroundColor Yellow
    Write-Host "  • VM will shut down after sysprep completes" -ForegroundColor Yellow
    Write-Host "  • This process takes 5-15 minutes" -ForegroundColor Yellow
    Write-Host "  • DO NOT restart or power on the VM manually" -ForegroundColor Yellow
    Write-Host "  • After shutdown, generalize in Azure and create image" -ForegroundColor Yellow
    
    if (-not $AutoConfirm) {
        Write-Host ""
        $final = Read-Host "Start sysprep now? (yes/no)"
        if ($final -ne "yes") {
            Write-Host "Sysprep aborted by user" -ForegroundColor Yellow
            Stop-Transcript
            exit 0
        }
    }
    
    # Stop transcript before sysprep
    Write-Host "`nStopping transcript..." -ForegroundColor Gray
    Stop-Transcript
    
    # Run sysprep
    Write-Host "`nStarting sysprep..." -ForegroundColor Cyan
    Write-Host "VM will shut down when complete.`n" -ForegroundColor Yellow
    
    $sysprepArgs = "/oobe", "/generalize", "/shutdown", "/mode:vm", "/unattend:$unattendPath"
    
    Start-Process -FilePath $sysprepPath -ArgumentList $sysprepArgs -Wait -NoNewWindow
    
    # This line will only execute if sysprep fails
    Write-Host "`n❌ Sysprep exited unexpectedly!" -ForegroundColor Red
    Write-Host "Check C:\Windows\System32\Sysprep\Panther\setuperr.log for errors" -ForegroundColor Yellow
    exit 1
}
else {
    Write-Host "`n⚠️  Sysprep skipped (use -SkipSysprep:$false to enable)" -ForegroundColor Yellow
    Stop-Transcript
}

#endregion
