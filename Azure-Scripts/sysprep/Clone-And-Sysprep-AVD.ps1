<#
.SYNOPSIS
    Clone and sysprep an Azure Virtual Desktop VM (WITHOUT generalization or image creation)

.DESCRIPTION
    This script prepares a VM for generalization but STOPS before final steps:
    1. Creates a snapshot of the ORIGINAL VM (unmodified backup)
    2. Clones the VM from the original disk
    3. Prepares the CLONE (cleanup, agent removal)
    4. Runs sysprep and waits for VM to shut down
    5. STOPS - Does NOT generalize VM or create image
    
    Use this when you want to:
    - Verify sysprep completed successfully before generalizing
    - Do manual validation on the sysprepped VM
    - Keep option to restart VM for additional changes
    
    After validation, use separate script to generalize and create image.

.PARAMETER SourceVMName
    Name of the source AVD VM to clone

.PARAMETER SourceResourceGroupName
    Resource group containing the source VM

.PARAMETER TargetVMName
    Name for the cloned VM

.PARAMETER SubscriptionId
    Azure subscription ID

.PARAMETER CloneVMSize
    VM size for the cloned VM (default: same as source VM)

.PARAMETER CloneDiskType
    Disk type for the cloned VM OS disk (default: StandardSSD_LRS)
    Options: Standard_LRS, StandardSSD_LRS, Premium_LRS

.PARAMETER NetworkSecurityGroupId
    Resource ID of NSG to attach to cloned VM NIC (prevents domain join)

.PARAMETER Location
    Azure region (default: westeurope)

.PARAMETER SkipPreparation
    Skip VM preparation step

.PARAMETER SkipSnapshot
    Skip snapshot creation

.EXAMPLE
    .\Clone-And-Sysprep-AVD.ps1 -SourceVMName "BABAVDSHDTA-1" `
        -SourceResourceGroupName "bab-vdi-avd-weeu-rg-01" `
        -TargetVMName "BABAVDSHDTA-1-Prepared" `
        -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5" `
        -CloneVMSize "Standard_D4s_v5" `
        -CloneDiskType "StandardSSD_LRS"

.NOTES
    Author: BAB CloudOps Team
    Date: April 2026
    
    IMPORTANT: This script does NOT generalize the VM or create an image.
    Use the companion script "Generalize-And-CreateImage-AVD.ps1" after validation.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceVMName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetVMName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$CloneVMSize,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Standard_LRS', 'StandardSSD_LRS', 'Premium_LRS', 'UltraSSD_LRS')]
    [string]$CloneDiskType = 'StandardSSD_LRS',

    [Parameter(Mandatory = $false)]
    [string]$NetworkSecurityGroupId,

    [Parameter(Mandatory = $false)]
    [string]$Location = "westeurope",

    [Parameter(Mandatory = $false)]
    [switch]$SkipPreparation,

    [Parameter(Mandatory = $false)]
    [switch]$SkipSnapshot
)

#region Helper Functions

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "[$timestamp] [$Level] $Message"
    
    switch ($Level) {
        'Error'   { Write-Host $logMessage -ForegroundColor Red }
        'Warning' { Write-Host $logMessage -ForegroundColor Yellow }
        'Success' { Write-Host $logMessage -ForegroundColor Green }
        default   { Write-Host $logMessage -ForegroundColor Cyan }
    }
    
    # Append to log file
    $logFile = ".\logs\AVD-Sysprep-$(Get-Date -Format 'yyyyMMdd').log"
    $logMessage | Out-File -FilePath $logFile -Append -Encoding utf8
}

function Wait-ForVMState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        
        [Parameter(Mandatory = $true)]
        [string]$TargetState,
        
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 600,
        
        [Parameter(Mandatory = $false)]
        [int]$PollingIntervalSeconds = 10
    )
    
    $elapsed = 0
    Write-Log "Waiting for VM '$VMName' to reach state '$TargetState'..."
    
    while ($elapsed -lt $TimeoutSeconds) {
        $vmStatus = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status).Statuses |
            Where-Object { $_.Code -like 'PowerState/*' } |
            Select-Object -ExpandProperty Code
        
        if ($vmStatus -eq $TargetState) {
            Write-Log "VM reached target state: $TargetState" -Level Success
            return $true
        }
        
        Write-Log "Current state: $vmStatus (waiting for $TargetState) - Elapsed: ${elapsed}s" -Level Info
        Start-Sleep -Seconds $PollingIntervalSeconds
        $elapsed += $PollingIntervalSeconds
    }
    
    Write-Log "Timeout waiting for VM state '$TargetState'" -Level Error
    return $false
}

function Test-VMExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $true)]
        [string]$VMName
    )
    
    try {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop -WarningAction SilentlyContinue
        if ($vm) {
            return $true
        }
        return $false
    }
    catch {
        if ($_.Exception.Message -like "*ResourceNotFound*" -or 
            $_.Exception.Message -like "*not found*" -or
            $_.Exception.Message -like "*does not exist*") {
            return $false
        }
        throw
    }
}

#endregion

#region Main Script

try {
    # Initialize logging
    $logDir = ".\logs"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    
    Start-Transcript -Path "$logDir\AVD-Sysprep-Transcript-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    
    Write-Log "=== Starting AVD Clone and Sysprep Process ===" -Level Success
    Write-Log "Source VM: $SourceVMName"
    Write-Log "Target VM: $TargetVMName"
    Write-Log "Subscription: $SubscriptionId"
    Write-Log "NOTE: This script STOPS after sysprep - no generalization or image creation" -Level Warning
    
    # Set Azure context
    Write-Log "Setting Azure subscription context..."
    $null = Set-AzContext -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue
    $context = Get-AzContext
    Write-Log "Connected to subscription: $($context.Subscription.Name)" -Level Success
    
    # Validate source VM exists
    Write-Log "Validating source VM exists..."
    $vmExists = Test-VMExists -ResourceGroupName $SourceResourceGroupName -VMName $SourceVMName
    if (-not $vmExists) {
        throw "Source VM '$SourceVMName' not found in resource group '$SourceResourceGroupName'"
    }
    
    $sourceVM = Get-AzVM -ResourceGroupName $SourceResourceGroupName -Name $SourceVMName -WarningAction SilentlyContinue
    Write-Log "Source VM found: $($sourceVM.Id)" -Level Success
    
    #region Step 1: Create Snapshot
    
    if (-not $SkipSnapshot) {
        Write-Log "=== Step 1: Creating Snapshot of Original VM ===" -Level Success
        
        $snapshotName = "$SourceVMName-Snapshot-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        
        if ($PSCmdlet.ShouldProcess($sourceVM.StorageProfile.OsDisk.Name, "Create snapshot '$snapshotName'")) {
            
            Write-Log "Creating snapshot: $snapshotName"
            
            $snapshotConfig = New-AzSnapshotConfig `
                -SourceUri $sourceVM.StorageProfile.OsDisk.ManagedDisk.Id `
                -Location $Location `
                -CreateOption Copy
            
            $snapshot = New-AzSnapshot `
                -Snapshot $snapshotConfig `
                -SnapshotName $snapshotName `
                -ResourceGroupName $SourceResourceGroupName `
                -ErrorAction Stop
            
            Write-Log "Snapshot created: $($snapshot.Id)" -Level Success
        }
    }
    else {
        Write-Log "Skipping snapshot creation (SkipSnapshot flag set)" -Level Warning
    }
    
    #endregion
    
    #region Step 2: Clone VM
    
    Write-Log "=== Step 2: Cloning VM ===" -Level Success
    
    if (Test-VMExists -ResourceGroupName $SourceResourceGroupName -VMName $TargetVMName) {
        Write-Log "Target VM '$TargetVMName' already exists" -Level Warning
        
        if ($PSCmdlet.ShouldContinue("Do you want to delete existing VM '$TargetVMName'?", "Confirm deletion")) {
            Write-Log "Removing existing target VM..."
            Remove-AzVM -ResourceGroupName $SourceResourceGroupName -Name $TargetVMName -Force
            Write-Log "Existing VM removed" -Level Success
        }
        else {
            throw "Cannot proceed - target VM already exists"
        }
    }
    
    if ($PSCmdlet.ShouldProcess($TargetVMName, "Clone VM from $SourceVMName")) {
        
        $cloneSize = if ($CloneVMSize) { $CloneVMSize } else { $sourceVM.HardwareProfile.VmSize }
        Write-Log "Clone VM size: $cloneSize (Disk type: $CloneDiskType)" -Level Info
        
        # Create new managed disk from source
        $diskConfig = New-AzDiskConfig `
            -SourceResourceId $sourceVM.StorageProfile.OsDisk.ManagedDisk.Id `
            -Location $Location `
            -SkuName $CloneDiskType `
            -CreateOption Copy
        
        $clonedDiskName = "$TargetVMName-OsDisk"
        $clonedDisk = New-AzDisk `
            -Disk $diskConfig `
            -DiskName $clonedDiskName `
            -ResourceGroupName $SourceResourceGroupName `
            -ErrorAction Stop
        
        Write-Log "Cloned disk created: $clonedDiskName" -Level Success
        
        # Create VM config
        $vmConfig = New-AzVMConfig -VMName $TargetVMName -VMSize $cloneSize
        $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $clonedDisk.Id -CreateOption Attach -Windows
        
        # Copy network configuration
        foreach ($nic in $sourceVM.NetworkProfile.NetworkInterfaces) {
            $nicName = "$TargetVMName-nic"
            $sourceNic = Get-AzNetworkInterface -ResourceId $nic.Id
            
            $nicParams = @{
                Name                = $nicName
                ResourceGroupName   = $SourceResourceGroupName
                Location            = $Location
                SubnetId            = $sourceNic.IpConfigurations[0].Subnet.Id
                ErrorAction         = 'Stop'
            }
            
            # Attach NSG if provided
            if ($NetworkSecurityGroupId) {
                Write-Log "Attaching NSG to clone VM NIC" -Level Info
                
                if ($NetworkSecurityGroupId -match '/resourceGroups/([^/]+)/.*networkSecurityGroups/([^/]+)$') {
                    $nsgResourceGroup = $Matches[1]
                    $nsgName = $Matches[2]
                    
                    $nsg = Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $nsgResourceGroup -ErrorAction Stop
                    $nicParams['NetworkSecurityGroupId'] = $nsg.Id
                    Write-Log "NSG attached: $($nsg.Name)" -Level Success
                }
                else {
                    throw "Invalid NSG Resource ID format"
                }
            }
            
            $newNic = New-AzNetworkInterface @nicParams
            $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $newNic.Id
        }
        
        # Create the VM
        Write-Log "Creating cloned VM: $TargetVMName"
        $null = New-AzVM -ResourceGroupName $SourceResourceGroupName -Location $Location -VM $vmConfig -ErrorAction Stop
        
        Write-Log "VM cloned successfully: $TargetVMName" -Level Success
    }
    
    #endregion
    
    #region Step 3: Prepare Cloned VM
    
    if (-not $SkipPreparation) {
        Write-Log "=== Step 3: Preparing Cloned VM ===" -Level Success
        
        if ($PSCmdlet.ShouldProcess($TargetVMName, "Prepare cloned VM")) {
            
            Write-Log "Waiting for cloned VM to be ready..."
            Start-Sleep -Seconds 60
            
            $prepScript = @'
# Microsoft AVD Golden Image Optimizations
Write-Host "Starting VM preparation..."

# CRITICAL: Force local domain unjoin (NSG blocks domain communication by design)
Write-Host "=== FORCED LOCAL DOMAIN UNJOIN ===" -ForegroundColor Cyan
$computerInfo = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue

if ($computerInfo -and $computerInfo.PartOfDomain) {
    Write-Host "VM is domain-joined - performing forced local removal..." -ForegroundColor Yellow
    
    # Use netdom with /force flag (local-only)
    try {
        & netdom.exe remove $env:COMPUTERNAME /force 2>&1 | Out-Null
        Write-Host "  ✓ Netdom force removal" -ForegroundColor Green
    }
    catch { Write-Host "  Note: Netdom not available" -ForegroundColor Gray }
    
    # Direct registry manipulation
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "Domain" -Value "" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -Name "Domain" -Value "WORKGROUP" -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "DhcpDomain" -Force -ErrorAction SilentlyContinue
    
    # Disable Netlogon
    Stop-Service -Name Netlogon -Force -ErrorAction SilentlyContinue
    Set-Service -Name Netlogon -StartupType Disabled -ErrorAction SilentlyContinue
    
    Write-Host "  ✓ Local domain config cleared" -ForegroundColor Green
    Write-Host "Restarting to complete unjoin..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit 0
}
else {
    Write-Host "✓ VM not domain-joined" -ForegroundColor Green
}

# Disable Windows Update
Write-Host "Disabling Windows Update..."
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Set-Service -Name wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
New-Item -Path "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force | Out-Null
New-ItemProperty -Path "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name NoAutoUpdate -PropertyType DWord -Value 1 -Force | Out-Null

# Disable Storage Sense
New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" -Name 01 -PropertyType DWord -Value 0 -Force | Out-Null

# Enable Time Zone Redirection
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name fEnableTimeZoneRedirection -PropertyType DWord -Value 1 -Force | Out-Null

# Configure Telemetry
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name AllowTelemetry -PropertyType DWord -Value 3 -Force | Out-Null

# Disable Watson Crash Reporting
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" -Name Corporate* -Force -ErrorAction SilentlyContinue

# Enable 5K Resolution Support
New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name MaxMonitors -PropertyType DWord -Value 4 -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name MaxXResolution -PropertyType DWord -Value 5120 -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name MaxYResolution -PropertyType DWord -Value 2880 -Force | Out-Null

# Check and disable UWF
$uwfStatus = Get-WindowsOptionalFeature -Online -FeatureName "Client-UnifiedWriteFilter" -ErrorAction SilentlyContinue
if ($uwfStatus -and $uwfStatus.State -eq "Enabled") {
    Write-Host "Disabling UWF..."
    Disable-WindowsOptionalFeature -Online -FeatureName "Client-UnifiedWriteFilter" -NoRestart -ErrorAction SilentlyContinue
}

# Clean temporary files
$tempPaths = @("$env:SystemRoot\Temp\*", "$env:LOCALAPPDATA\Temp\*", "C:\Windows\Prefetch\*", "C:\Windows\SoftwareDistribution\Download\*")
foreach ($path in $tempPaths) {
    Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
}

# Clear Sysprep history
Remove-Item "C:\Windows\System32\Sysprep\Panther" -Recurse -Force -ErrorAction SilentlyContinue

# Enable CD/DVD-ROM
reg add HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\cdrom /v start /t REG_DWORD /d 1 /f

# Remove user-installed AppX packages
Write-Host "Removing AppX packages..."
$userAppxPackages = Get-AppxPackage -AllUsers | Where-Object { -not $_.IsFramework -and -not $_.IsBundle }
foreach ($app in $userAppxPackages) {
    if ($app.Name -notlike "*Windows.Photos*" -and $app.Name -notlike "*WindowsCalculator*" -and $app.Name -notlike "*WindowsStore*") {
        try {
            Remove-AppxPackage -Package $app.PackageFullName -AllUsers -ErrorAction Stop
        } catch { }
    }
}

# Disable Windows Defender
try {
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
    Write-Host "Windows Defender disabled"
} catch { }

# Remove user profiles
$profiles = Get-WmiObject -Class Win32_UserProfile | Where-Object { 
    -not $_.Special -and $_.LocalPath -notlike "*\Administrator" -and $_.LocalPath -notlike "*\Default*"
}
foreach ($profile in $profiles) {
    try { $profile.Delete() } catch { }
}

# Remove AVD agents
$avdPackagePatterns = @("*Remote Desktop Services*", "*Remote Desktop Agent*", "*RDAgent*", "*RDInfraAgent*")
foreach ($pattern in $avdPackagePatterns) {
    $avdPackages = Get-Package -Name $pattern -ErrorAction SilentlyContinue
    foreach ($pkg in $avdPackages) {
        try { $pkg | Uninstall-Package -Force -ErrorAction Stop } catch { }
    }
}

Write-Host "VM preparation complete"
'@
            
            Write-Log "Running preparation script..."
            $prepResult = Invoke-AzVMRunCommand -ResourceGroupName $SourceResourceGroupName `
                -VMName $TargetVMName `
                -CommandId 'RunPowerShellScript' `
                -ScriptString $prepScript `
                -ErrorAction Stop
            
            # Check if domain unjoin triggered a restart
            if ($prepResult.Value[0].Message -match "Restarting to complete unjoin" -or 
                $prepResult.Value[0].Message -match "Restart-Computer") {
                
                Write-Log "Domain unjoin detected - VM restarting..." -Level Warning
                Write-Log "Waiting 2 minutes for restart..." -Level Info
                Start-Sleep -Seconds 120
                
                # Wait for VM to come back online
                $running = Wait-ForVMState -ResourceGroupName $SourceResourceGroupName `
                    -VMName $TargetVMName `
                    -TargetState 'PowerState/running' `
                    -TimeoutSeconds 300
                
                if ($running) {
                    Write-Log "VM back online - waiting for services..." -Level Info
                    Start-Sleep -Seconds 60
                    
                    Write-Log "Re-running prep to complete remaining tasks..." -Level Info
                    $prepResult2 = Invoke-AzVMRunCommand -ResourceGroupName $SourceResourceGroupName `
                        -VMName $TargetVMName `
                        -CommandId 'RunPowerShellScript' `
                        -ScriptString $prepScript `
                        -ErrorAction Stop
                }
                else {
                    throw "VM failed to restart after domain unjoin"
                }
            }
            
            Write-Log "Preparation complete" -Level Success
        }
    }
    
    #endregion
    
    #region Step 4: Sysprep (WITHOUT generalization)
    
    Write-Log "=== Step 4: Running Sysprep ===" -Level Success
    
    if ($PSCmdlet.ShouldProcess($TargetVMName, "Run Sysprep")) {
        
        # Ensure VM is running
        $vmStatus = Get-AzVM -ResourceGroupName $SourceResourceGroupName -Name $TargetVMName -Status
        $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).Code
        
        if ($powerState -ne "PowerState/running") {
            Write-Log "Starting VM..."
            Start-AzVM -ResourceGroupName $SourceResourceGroupName -Name $TargetVMName -NoWait | Out-Null
            Start-Sleep -Seconds 60
        }
        
        # Sysprep script
        $sysprepScript = @'
# Final cleanup
Remove-Item "$env:SystemRoot\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

# Clear event logs
wevtutil el | ForEach-Object { wevtutil cl $_ 2>$null }

# Verify sysprep exists
if (-not (Test-Path "C:\Windows\System32\Sysprep\Sysprep.exe")) {
    Write-Error "Sysprep.exe not found!"
    exit 1
}

# Create unattend.xml to automate OOBE and prevent Azure provisioning timeout
Write-Host "Creating unattend.xml to automate OOBE..."
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
                        <Name>TempAdmin</Name>
                        <Group>Administrators</Group>
                        <Password>
                            <Value>UABhAHMAcwB3AG8AcgBkADEAMgAzACEA</Value>
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
Set-Content -Path $unattendPath -Value $unattendXml -Force
Write-Host "  ✓ Unattend.xml created at $unattendPath"

# Create flag file
Set-Content "C:\sysprep-started.txt" -Value (Get-Date).ToString()

# Run Sysprep with unattend.xml
Write-Host "Starting Sysprep with unattend.xml (OOBE will be automated)..."
Start-Process -FilePath "C:\Windows\System32\Sysprep\Sysprep.exe" `
    -ArgumentList "/oobe", "/generalize", "/shutdown", "/mode:vm", "/unattend:$unattendPath" `
    -NoNewWindow

Write-Host "Sysprep initiated - VM will shutdown when complete"
exit 0
'@
        
        Write-Log "Initiating Sysprep (5-15 minutes)..." -Level Info
        
        try {
            $sysprepResult = Invoke-AzVMRunCommand `
                -ResourceGroupName $SourceResourceGroupName `
                -VMName $TargetVMName `
                -CommandId 'RunPowerShellScript' `
                -ScriptString $sysprepScript `
                -ErrorAction Stop
        }
        catch {
            Write-Log "RunCommand may have timed out (expected)" -Level Warning
        }
        
        # Wait for VM to shut down
        Write-Log "Waiting for sysprep to complete (timeout: 20 minutes)..." -Level Info
        
        $maxWaitMinutes = 20
        $checkIntervalSeconds = 30
        $maxChecks = ($maxWaitMinutes * 60) / $checkIntervalSeconds
        $checkCount = 0
        $vmStopped = $false
        
        while ($checkCount -lt $maxChecks) {
            $checkCount++
            $elapsedMinutes = [math]::Round(($checkCount * $checkIntervalSeconds) / 60, 1)
            
            Start-Sleep -Seconds $checkIntervalSeconds
            
            $vmStatus = Get-AzVM -ResourceGroupName $SourceResourceGroupName -Name $TargetVMName -Status -ErrorAction SilentlyContinue
            $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).Code
            
            Write-Log "[$elapsedMinutes min] VM power state: $powerState" -Level Info
            
            if ($powerState -eq "PowerState/stopped" -or $powerState -eq "PowerState/deallocated") {
                Write-Log "VM stopped - Sysprep completed!" -Level Success
                $vmStopped = $true
                break
            }
        }
        
        if (-not $vmStopped) {
            throw "VM did not shut down within $maxWaitMinutes minutes"
        }
    }
    
    #endregion
    
    Write-Log "=== Sysprep Process Complete ===" -Level Success
    Write-Log "✅ VM '$TargetVMName' has been sysprepped and stopped" -Level Success
    Write-Log "⚠️  VM is NOT generalized - you can still restart it if needed" -Level Warning
    Write-Host ""
    Write-Log "Next steps:" -Level Info
    Write-Log "1. Verify VM is properly prepared (check logs, boot diagnostics)" -Level Info
    Write-Log "2. Run 'Generalize-And-CreateImage-AVD.ps1' to finalize image creation" -Level Info
    Write-Log "3. Or restart VM for additional manual changes" -Level Info
    
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" -Level Error
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level Error
    throw
}
finally {
    Stop-Transcript
}

#endregion
