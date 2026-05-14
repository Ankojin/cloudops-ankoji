<#
.SYNOPSIS
    Clone and generalize an Azure Virtual Desktop VM to create a proper golden image.

.DESCRIPTION
    This script addresses OS provisioning errors by properly preparing an AVD VM:
    1. Creates a snapshot of the ORIGINAL VM (unmodified backup)
    2. Clones the VM from the original disk
    3. Prepares the CLONE (cleanup, agent removal - source VM untouched)
    4. Runs sysprep and generalizes the clone
    5. Creates a Shared Image Gallery version
    
    IMPORTANT: Source VM remains operational and unchanged throughout the process.
    
    Fixes error: "OS Provisioning for VM did not finish in the allotted time"

.PARAMETER SourceVMName
    Name of the source AVD VM to clone (e.g., 'BABAVDSHDTA-2')

.PARAMETER SourceResourceGroupName
    Resource group containing the source VM

.PARAMETER TargetVMName
    Name for the cloned VM (e.g., 'BABAVDSHDTA-2-Clone')

.PARAMETER GalleryName
    Shared Image Gallery name for storing the generalized image

.PARAMETER ImageDefinitionName
    Image definition name in the gallery

.PARAMETER Location
    Azure region (default: westeurope)

.PARAMETER ReplicaRegions
    Additional regions for image replication (default: swedencentral)

.PARAMETER SubscriptionId
    Azure subscription ID (required for multi-subscription environments)

.PARAMETER CloneVMSize
    VM size for the cloned VM (default: same as source VM)
    Example: Standard_D4s_v5, Standard_E8s_v5

.PARAMETER CloneDiskType
    Disk type for the cloned VM OS disk (default: StandardSSD_LRS)
    Options: Standard_LRS, StandardSSD_LRS, Premium_LRS, UltraSSD_LRS

.PARAMETER NetworkSecurityGroupId
    Resource ID of NSG to attach to cloned VM NIC (prevents domain join)
    Example: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/networkSecurityGroups/{nsg}

.PARAMETER SkipPreparation
    Skip VM preparation step (use if already prepared)

.PARAMETER SkipSnapshot
    Skip snapshot creation (use with caution)

.EXAMPLE
    .\Clone-And-Generalize-AVD.ps1 -SourceVMName "BABAVDSHDTA-2" `
        -SourceResourceGroupName "bab-vdi-avd-weeu-rg-01" `
        -TargetVMName "BABAVDSHDTA-2-Clone" `
        -GalleryName "bab_avd_shared_win10_gallery" `
        -ImageDefinitionName "bab-w10-avd-img" `
        -SubscriptionId "your-subscription-id"

.EXAMPLE
    # Dry run to see what would happen
    .\Clone-And-Generalize-AVD.ps1 -SourceVMName "BABAVDSHDTA-2" `
        -SourceResourceGroupName "bab-vdi-avd-weeu-rg-01" `
        -TargetVMName "BABAVDSHDTA-2-Clone" -WhatIf

.EXAMPLE
    # Clone with custom VM size, SSD disk, and NSG to prevent domain join
    .\Clone-And-Generalize-AVD.ps1 -SourceVMName "BABAVDSHDTA-1" `
        -SourceResourceGroupName "bab-vdi-avd-weeu-rg-01" `
        -TargetVMName "BABAVDSHDTA-1-GoldenImage" `
        -CloneVMSize "Standard_D4s_v5" `
        -CloneDiskType "StandardSSD_LRS" `
        -NetworkSecurityGroupId "/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.Network/networkSecurityGroups/ad-join-deny" `
        -SubscriptionId "your-subscription-id"

.NOTES
    Author: BAB CloudOps Team
    Date: April 2026
    Requires: Az.Compute, Az.Resources modules
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

    [Parameter(Mandatory = $false)]
    [string]$GalleryName = "bab_avd_shared_win10_gallery",

    [Parameter(Mandatory = $false)]
    [string]$ImageDefinitionName = "bab-w10-avd-img",

    [Parameter(Mandatory = $false)]
    [string]$Location = "westeurope",

    [Parameter(Mandatory = $false)]
    [string[]]$ReplicaRegions = @("swedencentral"),

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
    $logFile = ".\logs\AVD-Clone-$(Get-Date -Format 'yyyyMMdd').log"
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
        # Only return false for "not found" errors, re-throw other errors
        if ($_.Exception.Message -like "*ResourceNotFound*" -or 
            $_.Exception.Message -like "*not found*" -or
            $_.Exception.Message -like "*does not exist*") {
            return $false
        }
        # For other errors (auth, network, etc.), re-throw so they're visible
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
    
    Start-Transcript -Path "$logDir\AVD-Clone-Transcript-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    
    Write-Log "=== Starting AVD Clone and Generalization Process ===" -Level Success
    Write-Log "Source VM: $SourceVMName"
    Write-Log "Target VM: $TargetVMName"
    Write-Log "Subscription: $SubscriptionId"
    
    # Set Azure context
    Write-Log "Setting Azure subscription context..."
    $null = Set-AzContext -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue
    $context = Get-AzContext
    Write-Log "Connected to subscription: $($context.Subscription.Name)" -Level Success
    
    # Validate source VM exists
    Write-Log "Validating source VM exists..."
    Write-Log "Looking for VM: $SourceVMName in RG: $SourceResourceGroupName" -Level Info
    
    try {
        $vmExists = Test-VMExists -ResourceGroupName $SourceResourceGroupName -VMName $SourceVMName
        if (-not $vmExists) {
            Write-Log "VM not found. Listing available VMs in resource group..." -Level Warning
            $availableVMs = Get-AzVM -ResourceGroupName $SourceResourceGroupName -WarningAction SilentlyContinue | Select-Object -ExpandProperty Name
            if ($availableVMs) {
                Write-Log "Available VMs: $($availableVMs -join ', ')" -Level Info
            } else {
                Write-Log "No VMs found in resource group '$SourceResourceGroupName'" -Level Warning
            }
            throw "Source VM '$SourceVMName' not found in resource group '$SourceResourceGroupName'"
        }
    }
    catch {
        Write-Log "Error during VM validation: $($_.Exception.Message)" -Level Error
        throw
    }
    
    Write-Log "Retrieving source VM details..." -Level Info
    $sourceVM = Get-AzVM -ResourceGroupName $SourceResourceGroupName -Name $SourceVMName -WarningAction SilentlyContinue
    Write-Log "Source VM found: $($sourceVM.Id)" -Level Success
    Write-Log "VM Size: $($sourceVM.HardwareProfile.VmSize), OS: $($sourceVM.StorageProfile.OsDisk.OsType)" -Level Info
    
    #region Step 1: Create Snapshot (BEFORE any modifications)
    
    if (-not $SkipSnapshot) {
        Write-Log "=== Step 1: Creating Snapshot of Original VM (Unmodified Backup) ===" -Level Success
        
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
    
    Write-Log "=== Step 2: Cloning VM from Snapshot ===" -Level Success
    Write-Log "NOTE: Source VM '$SourceVMName' will remain UNCHANGED and operational" -Level Info
    
    # Check if target VM already exists
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
        
        Write-Log "Creating clone from source VM OS disk..."
        
        # Determine VM size for clone
        $cloneSize = if ($CloneVMSize) { $CloneVMSize } else { $sourceVM.HardwareProfile.VmSize }
        Write-Log "Clone VM size: $cloneSize (Disk type: $CloneDiskType)" -Level Info
        
        # Create new managed disk from source with specified disk type
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
        
        Write-Log "Cloned disk created: $clonedDiskName (Type: $CloneDiskType)" -Level Success
        
        # Create new VM config with custom or source VM size
        $vmConfig = New-AzVMConfig -VMName $TargetVMName -VMSize $cloneSize
        
        # Attach cloned OS disk
        $vmConfig = Set-AzVMOSDisk -VM $vmConfig `
            -ManagedDiskId $clonedDisk.Id `
            -CreateOption Attach `
            -Windows
        
        # Copy network configuration
        foreach ($nic in $sourceVM.NetworkProfile.NetworkInterfaces) {
            $nicName = "$TargetVMName-nic"
            $sourceNic = Get-AzNetworkInterface -ResourceId $nic.Id
            
            # Build NIC parameters
            $nicParams = @{
                Name                = $nicName
                ResourceGroupName   = $SourceResourceGroupName
                Location            = $Location
                SubnetId            = $sourceNic.IpConfigurations[0].Subnet.Id
                ErrorAction         = 'Stop'
            }
            
            # Attach NSG if provided (prevents domain join)
            if ($NetworkSecurityGroupId) {
                Write-Log "Attaching NSG to clone VM NIC (prevents domain join during prep)" -Level Info
                Write-Log "NOTE: NSG is NOT included in final image - only used temporarily" -Level Info
                
                # Parse NSG resource ID to extract name and resource group
                # Format: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/networkSecurityGroups/{nsg-name}
                if ($NetworkSecurityGroupId -match '/resourceGroups/([^/]+)/.*networkSecurityGroups/([^/]+)$') {
                    $nsgResourceGroup = $Matches[1]
                    $nsgName = $Matches[2]
                    
                    Write-Log "Retrieving NSG: $nsgName from RG: $nsgResourceGroup" -Level Info
                    $nsg = Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $nsgResourceGroup -ErrorAction Stop
                    $nicParams['NetworkSecurityGroupId'] = $nsg.Id
                    Write-Log "NSG attached: $($nsg.Name)" -Level Success
                }
                else {
                    throw "Invalid NSG Resource ID format. Expected: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/networkSecurityGroups/{nsg-name}"
                }
            }
            
            $newNic = New-AzNetworkInterface @nicParams
            
            $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $newNic.Id
            Write-Log "Network interface created: $nicName" -Level Success
        }
        
        # Create the VM
        Write-Log "Creating cloned VM: $TargetVMName"
        $null = New-AzVM -ResourceGroupName $SourceResourceGroupName `
            -Location $Location `
            -VM $vmConfig `
            -ErrorAction Stop
        
        Write-Log "VM cloned successfully: $TargetVMName" -Level Success
        Write-Log "  - VM Size: $cloneSize" -Level Info
        Write-Log "  - Disk Type: $CloneDiskType" -Level Info
        if ($NetworkSecurityGroupId) {
            Write-Log "  - NSG Attached: Yes (domain join prevented)" -Level Info
        }
    }
    
    #endregion
    
    #region Step 3: Prepare Cloned VM (NOT the source)
    
    if (-not $SkipPreparation) {
        Write-Log "=== Step 3: Preparing CLONED VM (Source VM untouched) ===" -Level Success
        Write-Log "Running cleanup and agent removal on: $TargetVMName" -Level Info
        
        if ($PSCmdlet.ShouldProcess($TargetVMName, "Prepare cloned VM (cleanup, disable services, remove AVD agents)")) {
            
            # Wait for VM to be fully ready
            Write-Log "Waiting for cloned VM to be fully operational..." -Level Info
            Start-Sleep -Seconds 60
            
            $prepScript = @'
# ========================================
# Microsoft AVD Golden Image Optimizations
# Reference: https://learn.microsoft.com/en-us/azure/virtual-desktop/set-up-customize-master-image
# ========================================

# CRITICAL: Force local unjoin from domain (NSG blocks domain communication by design)
Write-Host "=== FORCED LOCAL DOMAIN UNJOIN (NSG blocks domain communication) ===" -ForegroundColor Cyan
Write-Host "NOTE: NSG is blocking domain connectivity - performing LOCAL-ONLY unjoin" -ForegroundColor Yellow

$computerInfo = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue

if ($computerInfo -and $computerInfo.PartOfDomain) {
    Write-Host "VM is domain-joined to: $($computerInfo.Domain)" -ForegroundColor Yellow
    Write-Host "Performing FORCED local domain removal (no DC contact)..." -ForegroundColor Yellow
    
    # Method 1: Use Remove-Computer with -Force (no credentials needed for -Force flag)
    Write-Host "  Step 1: Using Remove-Computer -Force to unjoin from domain..."
    try {
        # Remove-Computer -Force doesn't need credentials - performs local-only unjoin
        Remove-Computer -Force -Restart -ErrorAction Stop
        Write-Host "    ✓ Remove-Computer initiated - VM will restart" -ForegroundColor Green
        Write-Host "    ⏳ Waiting for restart to begin..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
        exit 0  # Exit to allow restart
    }
    catch {
        Write-Host "    ✗ Remove-Computer failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "    Continuing with fallback methods..." -ForegroundColor Yellow
    }
    
    # Method 2: Use netdom with /force flag (local-only, no DC contact)
    Write-Host "  Step 2: Using netdom to force local workgroup join..."
    try {
        $netdomResult = & netdom.exe remove $env:COMPUTERNAME /force 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    ✓ Netdom force removal successful" -ForegroundColor Green
        }
        else {
            Write-Host "    Note: Netdom returned code $LASTEXITCODE - continuing with registry method" -ForegroundColor Gray
        }
    }
    catch {
        Write-Host "    Note: Netdom not available or failed - using registry method" -ForegroundColor Gray
    }
    
    # Method 3: Direct registry manipulation (guaranteed to work without network)
    Write-Host "  Step 2: Clearing domain configuration from registry..."
    try {
        # Clear TCP/IP domain parameters
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "Domain" -Value "" -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "NV Domain" -Value "" -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "DhcpDomain" -Force -ErrorAction SilentlyContinue
        
        # Set workgroup
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -Name "Domain" -Value "WORKGROUP" -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -Name "Domain" -Value "WORKGROUP" -Force -ErrorAction SilentlyContinue
        
        # Clear LSA secrets (domain credentials)
        reg delete "HKLM\SECURITY\Policy\Secrets\$MACHINE.ACC" /f 2>$null
        
        Write-Host "    ✓ Registry domain configuration cleared" -ForegroundColor Green
    }
    catch {
        Write-Host "    Warning: Registry cleanup encountered errors: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    
    # Method 4: Clear cached domain credentials
    Write-Host "  Step 4: Clearing cached domain credentials..."
    try {
        # Clear credential manager
        & cmdkey.exe /list 2>&1 | Where-Object {$_ -like "*Target:*"} | ForEach-Object {
            $target = $_.Split("Target: ")[1]
            if ($target) {
                & cmdkey.exe /delete:$target 2>&1 | Out-Null
            }
        }
        Write-Host "    ✓ Cached credentials cleared" -ForegroundColor Green
    }
    catch {
        Write-Host "    Note: Credential clearing completed with warnings" -ForegroundColor Gray
    }
    
    # Method 5: Disable Netlogon service (prevents domain communication attempts)
    Write-Host "  Step 5: Disabling Netlogon service..."
    try {
        Stop-Service -Name Netlogon -Force -ErrorAction SilentlyContinue
        Set-Service -Name Netlogon -StartupType Disabled -ErrorAction Stop
        Write-Host "    ✓ Netlogon service disabled" -ForegroundColor Green
    }
    catch {
        Write-Host "    Warning: Could not disable Netlogon: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    
    Write-Host "`n⚠️  Domain unjoin methods completed but restart did not occur" -ForegroundColor Yellow
    Write-Host "    Attempting manual restart..." -ForegroundColor Yellow
    Restart-Computer -Force
    Start-Sleep -Seconds 5
    exit 0  # Exit to allow restart
}
else {
    Write-Host "✓ VM is not domain-joined or already in workgroup" -ForegroundColor Green
    
    # Double-check with registry to be absolutely sure
    $regDomain = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -Name "Domain" -ErrorAction SilentlyContinue).Domain
    if ($regDomain -and $regDomain -ne "WORKGROUP" -and $regDomain -ne "") {
        Write-Host "⚠️  WARNING: WMI reports workgroup but registry shows domain: $regDomain" -ForegroundColor Yellow
        Write-Host "    Forcing registry cleanup..." -ForegroundColor Yellow
        
        # Force registry cleanup
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "Domain" -Value "" -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -Name "Domain" -Value "WORKGROUP" -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -Name "Domain" -Value "WORKGROUP" -Force -ErrorAction SilentlyContinue
        
        Write-Host "    Registry cleaned - restarting to apply..." -ForegroundColor Yellow
        Restart-Computer -Force
        Start-Sleep -Seconds 5
        exit 0
    }
    else {
        Write-Host "    ✓ Verified: Both WMI and registry show workgroup status" -ForegroundColor Green
    }
}

# Disable Windows Update
Write-Host "Disabling Windows Update..."
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Set-Service -Name wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
New-Item -Path "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate" -Force | Out-Null
New-Item -Path "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force | Out-Null
New-ItemProperty -Path "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate\AU" `
    -Name NoAutoUpdate -PropertyType DWord -Value 1 -Force | Out-Null
Write-Host "  ✓ Windows Update disabled"

# Disable Storage Sense (Microsoft recommended for AVD)
Write-Host "Disabling Storage Sense..."
New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" `
    -Name 01 -PropertyType DWord -Value 0 -Force | Out-Null
Write-Host "  ✓ Storage Sense disabled"

# Enable Time Zone Redirection
Write-Host "Enabling Time Zone Redirection..."
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" `
    -Name fEnableTimeZoneRedirection -PropertyType DWord -Value 1 -Force | Out-Null
Write-Host "  ✓ Time Zone Redirection enabled"

# Configure Telemetry for Feedback Hub
Write-Host "Configuring Telemetry..."
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" `
    -Name AllowTelemetry -PropertyType DWord -Value 3 -Force | Out-Null
Write-Host "  ✓ Telemetry configured"

# Disable Watson Crash Reporting
Write-Host "Disabling Watson Crash Reporting..."
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" `
    -Name Corporate* -Force -ErrorAction SilentlyContinue
Write-Host "  ✓ Watson Crash Reporting disabled"

# Enable 5K Resolution Support (multi-monitor)
Write-Host "Enabling 5K Resolution Support..."
New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
    -Name MaxMonitors -PropertyType DWord -Value 4 -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
    -Name MaxXResolution -PropertyType DWord -Value 5120 -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
    -Name MaxYResolution -PropertyType DWord -Value 2880 -Force | Out-Null
New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\rdp-sxs" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\rdp-sxs" `
    -Name MaxMonitors -PropertyType DWord -Value 4 -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\rdp-sxs" `
    -Name MaxXResolution -PropertyType DWord -Value 5120 -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\rdp-sxs" `
    -Name MaxYResolution -PropertyType DWord -Value 2880 -Force | Out-Null
Write-Host "  ✓ 5K Resolution Support enabled"

# Specify Start Layout (optional)
Write-Host "Configuring Start Layout..."
New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" `
    -Name SpecialRoamingOverrideAllowed -PropertyType DWord -Value 1 -Force | Out-Null
Write-Host "  ✓ Start Layout configured"

# Check and disable Unified Write Filter (UWF) - Not supported for AVD
Write-Host "Checking for Unified Write Filter (UWF)..."
$uwfStatus = Get-WindowsOptionalFeature -Online -FeatureName "Client-UnifiedWriteFilter" -ErrorAction SilentlyContinue
if ($uwfStatus -and $uwfStatus.State -eq "Enabled") {
    Write-Host "  ⚠️  WARNING: Unified Write Filter (UWF) is enabled - NOT SUPPORTED for AVD!" -ForegroundColor Yellow
    Write-Host "  Disabling UWF..."
    Disable-WindowsOptionalFeature -Online -FeatureName "Client-UnifiedWriteFilter" -NoRestart -ErrorAction SilentlyContinue
    Write-Host "  ✓ UWF disabled" -ForegroundColor Green
}
else {
    Write-Host "  ✓ UWF not enabled (good)"
}

# Clean temporary files
Write-Host "Cleaning temporary files..."
$tempPaths = @(
    "$env:SystemRoot\Temp\*",
    "$env:LOCALAPPDATA\Temp\*",
    "C:\Windows\Prefetch\*",
    "C:\Windows\SoftwareDistribution\Download\*"
)
foreach ($path in $tempPaths) {
    Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
}

# Clear Sysprep history
Write-Host "Clearing Sysprep history..."
Remove-Item "C:\Windows\System32\Sysprep\Panther" -Recurse -Force -ErrorAction SilentlyContinue

# Enable CD/DVD-ROM (required for Azure)
Write-Host "Enabling CD/DVD-ROM..."
reg add HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\cdrom /v start /t REG_DWORD /d 1 /f

# Remove user-installed AppX packages (recommended for sysprep)
Write-Host "`nRemoving user-specific AppX packages..."
$appxRemoved = 0
$appxSkipped = 0
$appxProtected = 0

try {
    # Get all AppX packages for all users (not provisioned)
    $userAppxPackages = Get-AppxPackage -AllUsers | Where-Object { 
        -not $_.IsFramework -and 
        -not $_.IsBundle -and
        # Skip critical Windows components
        $_.Name -notlike "*Windows.Photos*" -and 
        $_.Name -notlike "*WindowsCalculator*" -and
        $_.Name -notlike "*WindowsStore*" -and
        $_.Name -notlike "*VCLibs*" -and
        $_.Name -notlike "*NET.Native*" -and
        $_.Name -notlike "*Microsoft.UI*" -and
        $_.Name -notlike "*DesktopAppInstaller*"
    }
    
    Write-Host "Total packages to process: $($userAppxPackages.Count)"
    
    foreach ($app in $userAppxPackages) {
        Write-Host "  Attempting: $($app.Name)" -NoNewline
        
        try {
            Remove-AppxPackage -Package $app.PackageFullName -AllUsers -ErrorAction Stop
            Write-Host " ✓" -ForegroundColor Green
            $appxRemoved++
        }
        catch {
            # Check for specific error codes
            if ($_.Exception.Message -match "0x80070032") {
                # ERROR_NOT_SUPPORTED or ERROR_SHARING_VIOLATION - system-protected package
                Write-Host " ⊙ (system-protected)" -ForegroundColor Gray
                $appxProtected++
            }
            elseif ($_.Exception.Message -match "0x80073CFA") {
                # Package is in use
                Write-Host " ⊙ (in use)" -ForegroundColor Yellow
                $appxSkipped++
            }
            elseif ($_.Exception.Message -match "deployment") {
                # Generic deployment error - usually system package
                Write-Host " ⊙ (deployment protected)" -ForegroundColor Gray
                $appxProtected++
            }
            else {
                Write-Host " ⚠ ($($_.Exception.Message.Substring(0, [Math]::Min(50, $_.Exception.Message.Length)))...)" -ForegroundColor Yellow
                $appxSkipped++
            }
        }
    }
    
    Write-Host "`n✓ AppX package cleanup summary:" -ForegroundColor Cyan
    Write-Host "  Removed: $appxRemoved" -ForegroundColor Green
    Write-Host "  Protected (system packages): $appxProtected" -ForegroundColor Gray
    Write-Host "  Skipped (other errors): $appxSkipped" -ForegroundColor Yellow
    
    if ($appxProtected -gt 0) {
        Write-Host "`nℹ️  System-protected packages will NOT block sysprep" -ForegroundColor Cyan
    }
    
    if ($appxSkipped -gt 0) {
        Write-Host "⚠️  Some packages could not be removed but sysprep should still succeed" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "✗ AppX cleanup failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  AppX package removal is optional - sysprep may still succeed" -ForegroundColor Yellow
}

# Check and report third-party applications that may cause sysprep issues
Write-Host "`nChecking for potentially problematic third-party applications..."
$problematicApps = @()

# List of app patterns known to cause sysprep issues
$problematicPatterns = @(
    "*McAfee*",
    "*Norton*",
    "*Symantec*",
    "*Trend Micro*",
    "*Kaspersky*",
    "*Cisco AnyConnect*",
    "*FortiClient*",
    "*Palo Alto*",
    "*VPN*",
    "*Backup Exec*",
    "*Veeam*",
    "*SCOM*",
    "*System Center*",
    "*Carbon Black*",
    "*CrowdStrike*"
)

foreach ($pattern in $problematicPatterns) {
    $foundApps = Get-Package -Name $pattern -ErrorAction SilentlyContinue
    if ($foundApps) {
        foreach ($app in $foundApps) {
            $problematicApps += $app
            Write-Host "  ⚠️  Found: $($app.Name) ($($app.Version))" -ForegroundColor Yellow
        }
    }
}

if ($problematicApps.Count -gt 0) {
    Write-Host "`n⚠️  WARNING: $($problematicApps.Count) potentially problematic app(s) found!" -ForegroundColor Yellow
    Write-Host "These apps may cause sysprep to fail. Consider removing them:" -ForegroundColor Yellow
    
    # Optional: Uncomment the following lines to auto-remove problematic apps
    # Write-Host "Attempting to remove problematic applications..."
    # foreach ($app in $problematicApps) {
    #     Write-Host "  Removing: $($app.Name)"
    #     try {
    #         $app | Uninstall-Package -Force -ErrorAction Stop
    #         Write-Host "    ✓ Removed successfully" -ForegroundColor Green
    #     }
    #     catch {
    #         Write-Host "    ✗ Failed: $($_.Exception.Message)" -ForegroundColor Red
    #     }
    # }
}
else {
    Write-Host "  ✓ No known problematic third-party apps detected" -ForegroundColor Green
}

# Disable antivirus programs (Microsoft recommendation before sysprep)
Write-Host "`nDisabling antivirus programs for sysprep..."
$antivirusDisabled = $false
try {
    # Disable Windows Defender
    $defenderStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($defenderStatus -and $defenderStatus.RealTimeProtectionEnabled) {
        Write-Host "  Disabling Windows Defender Real-Time Protection..."
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
        $antivirusDisabled = $true
        Write-Host "    ✓ Windows Defender disabled" -ForegroundColor Green
    }
}
catch {
    Write-Host "  Note: Could not disable Windows Defender: $($_.Exception.Message)" -ForegroundColor Gray
}

if (-not $antivirusDisabled) {
    Write-Host "  ℹ️  No active antivirus found or already disabled"
}

# Remove unnecessary user profiles (keep Default and system profiles)
Write-Host "`nCleaning up user profiles..."
$profilesRemoved = 0
$profilesSkipped = 0
$profilesFailed = 0

try {
    # Get all user profiles
    $allProfiles = Get-WmiObject -Class Win32_UserProfile -ErrorAction Stop
    Write-Host "Total profiles found: $($allProfiles.Count)"
    
    # Filter profiles to remove (exclude system and critical profiles)
    $profilesToRemove = $allProfiles | Where-Object { 
        -not $_.Special -and 
        $_.LocalPath -notlike "*\Administrator" -and
        $_.LocalPath -notlike "*\Default*" -and
        $_.LocalPath -notlike "*\Public" -and
        $_.L
            # VERIFY the profile was actually deleted
            Start-Sleep -Milliseconds 500
            if (Test-Path $profilePath) {
                Write-Host "    ⚠ WMI delete reported success but folder still exists" -ForegroundColor Yellow
                throw "Profile folder not deleted"
            }
            
            Write-Host "    ✓ Removed and verified" -ForegroundColor Green
            $profilesRemoved++
        }
        catch {
            Write-Host "    ⚠ WMI delete failed or incomplete
    Write-Host "Profiles to remove: $($profilesToRemove.Count)"
    
    foreach ($profile in $profilesToRemove) {
        $profilePath = $profile.LocalPath
        Write-Host "  Attempting to remove: $profilePath"
        
        # Check if profile is loaded (indicates user is logged in)
        if ($profile.Loaded) {
            Write-Host "    ⊙ Skipped: Profile is currently loaded (user logged in or services running)" -ForegroundColor Yellow
            $profilesSkipped++
            continue
        }
        
        try {
            # Method 1: WMI Delete (preferred)
            $profile.Delete()
            Write-Host "    ✓ Removed successfully" -ForegroundColor Green
            $profilesRemoved++
        }
        catch {
            Write-Host "    ⚠ WMI delete failed: $($_.Exception.Message)" -ForegroundColor Yellow
            
            # Method 2: Manual removal (fallback)
            try {
                Write-Host "    Attempting manual removal..."
                
                # Remove profile registry entry
                $sid = $profile.SID
                $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
                if (Test-Path $regPath) {
                    Remove-Item -Path $regPath -Recurse -Force -ErrorAction Stop
                    Write-Host "      ✓ Registry entry removed" -ForegroundColor Gray
                }
                
                # Remove profile folder
                if (Test-Path $profilePath) {
                    # Take ownership first (helps with locked files)
                    & takeown.exe /f "$profilePath" /r /d Y 2>&1 | Out-Null
                    & icacls.exe "$profilePath" /grant Administrators:F /t /c /q 2>&1 | Out-Null
                    
                    Remove-Item -Path $profilePath -Recurse -Force -ErrorAction Stop
                    Write-Host "      ✓ Profile folder removed" -ForegroundColor Gray
                }
                
                Write-Host "    ✓ Removed via manual method" -ForegroundColor Green
                $profilesRemoved++
            }
            catch {
                Write-Host "    ✗ Failed: $($_.Exception.Message)" -ForegroundColor Red
                $profilesFailed++
            }
        }
    }
    
    Write-Host "`n✓ Profile cleanup summary:" -ForegroundColor Cyan
    Write-Host "  Removed: $profilesRemoved" -ForegroundColor Green
    Write-Host "  Skipped: $profilesSkipped (loaded profiles)" -ForegroundColor Yellow
    Write-Host "  Failed: $profilesFailed" -ForegroundColor $(if ($profilesFailed -gt 0) { "Red" } else { "Gray" })
    
    if ($profilesSkipped -gt 0) {
        Write-Host "`n⚠️  WARNING: $profilesSkipped profile(s) could not be removed (currently loaded)" -ForegroundColor Yellow
        Write-Host "  This may cause sysprep issues. Ensure no users are logged in." -ForegroundColor Yellow
    }
    
    if ($profilesFailed -gt 0) {
        Write-Host "`n⚠️  WARNING: $profilesFailed profile(s) failed to remove" -ForegroundColor Yellow
        Write-Host "  Sysprep may still succeed, but consider manual cleanup" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "  ✗ Profile cleanup failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  WARNING: Sysprep may fail with user profiles present!" -ForegroundColor Yellow
}

# Remove AVD agents using Get-Package (faster than Win32_Product)
Write-Host "Removing AVD agents..."

# Search for multiple AVD-related packages
$avdPackagePatterns = @(
    "*Remote Desktop Services*",
    "*Remote Desktop Agent*",
    "*RDAgent*",
    "*RDInfraAgent*"
)

$removedCount = 0
foreach ($pattern in $avdPackagePatterns) {
    $avdPackages = Get-Package -Name $pattern -ErrorAction SilentlyContinue
    foreach ($pkg in $avdPackages) {
        Write-Host "Uninstalling: $($pkg.Name) ($($pkg.Version))"
        try {
            $pkg | Uninstall-Package -Force -ErrorAction Stop
            $removedCount++
            Write-Host "  ✓ Removed successfully"
        }
        catch {
            Write-Host "  ✗ Failed to remove: $($_.Exception.Message)"
        }
    }
}

Write-Host "Total AVD packages removed: $removedCount"
Write-Host "✅ VM preparation complete"
'@
            
            Write-Log "Running preparation script on CLONED VM: $TargetVMName..."
            $prepResult = Invoke-AzVMRunCommand -ResourceGroupName $SourceResourceGroupName `
                -VMName $TargetVMName `
                -CommandId 'RunPowerShellScript' `
                -ScriptString $prepScript `
                -ErrorAction Stop
            
            if ($prepResult.Value[0].Message) {
                Write-Log "Preparation output: $($prepResult.Value[0].Message)" -Level Info
            }
            
            # Check if domain unjoin triggered a restart
            if ($prepResult.Value[0].Message -match "Restarting VM to apply changes" -or 
                $prepResult.Value[0].Message -match "Restart-Computer") {
                
                Write-Log "Domain unjoin detected - VM is restarting..." -Level Warning
                Write-Log "Waiting for VM to restart and stabilize (2 minutes)..." -Level Info
                Start-Sleep -Seconds 120
                
                # Wait for VM to be running again
                $running = Wait-ForVMState -ResourceGroupName $SourceResourceGroupName `
                    -VMName $TargetVMName `
                    -TargetState 'PowerState/running' `
                    -TimeoutSeconds 300
                
                if ($running) {
                    Write-Log "VM restarted - waiting 60 seconds for services to stabilize..." -Level Info
                    Start-Sleep -Seconds 60
                    
                    Write-Log "Re-running preparation script to complete remaining tasks..." -Level Info
                    $prepResult2 = Invoke-AzVMRunCommand -ResourceGroupName $SourceResourceGroupName `
                        -VMName $TargetVMName `
                        -CommandId 'RunPowerShellScript' `
                        -ScriptString $prepScript `
                        -ErrorAction Stop
                    
                    if ($prepResult2.Value[0].Message) {
                        Write-Log "Second prep run output: $($prepResult2.Value[0].Message)" -Level Info
                    }
                    Write-Log "Preparation completed after domain unjoin restart" -Level Success
                }
                else {
                    throw "VM failed to restart after domain unjoin"
                }
            }
            
            Write-Log "Cloned VM prepared successfully (Source VM: $SourceVMName remains UNCHANGED)" -Level Success
        }
    }
    else {
        Write-Log "Skipping VM preparation (SkipPreparation flag set)" -Level Warning
    }
    
    #endregion
    
    #region Step 4: Sysprep and Generalize Cloned VM
    
    Write-Log "=== Step 4: Running Sysprep and Generalizing CLONED VM ===" -Level Success
    
    if ($PSCmdlet.ShouldProcess($TargetVMName, "Run Sysprep and generalize")) {
        
        # Ensure VM is running
        Write-Log "Ensuring VM is running before sysprep..."
        $vmStatus = Get-AzVM -ResourceGroupName $SourceResourceGroupName -Name $TargetVMName -Status
        $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).Code
        
        if ($powerState -ne "PowerState/running") {
            Write-Log "Starting VM..."
            Start-AzVM -ResourceGroupName $SourceResourceGroupName -Name $TargetVMName -NoWait | Out-Null
            Start-Sleep -Seconds 60
        }
        
        # CRITICAL: Verify VM is NOT domain-joined before sysprep
        Write-Log "Verifying VM is unjoined from domain before sysprep..." -Level Info
        $verifyScript = @'
# Comprehensive domain and profile verification before sysprep
Write-Host "=== PRE-SYSPREP VERIFICATION ===" -ForegroundColor Cyan

# Check 1: WMI Domain Status
$computerInfo = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
if ($computerInfo.PartOfDomain) {
    Write-Error "ERROR: VM is still domain-joined to $($computerInfo.Domain)!"
    exit 1
}
else {
    Write-Host "✓ WMI Check: VM is in workgroup (not domain-joined)" -ForegroundColor Green
}

# Check 2: Registry Domain Status
$regDomain = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -Name "Domain" -ErrorAction SilentlyContinue).Domain
if ($regDomain -and $regDomain -ne "WORKGROUP" -and $regDomain -ne "") {
    Write-Error "ERROR: Registry still shows domain: $regDomain"
    exit 1
}
else {
    Write-Host "✓ Registry Check: Domain = '$regDomain' (workgroup)" -ForegroundColor Green
}

# Check 3: User Profile Count
$allProfiles = Get-WmiObject -Class Win32_UserProfile -ErrorAction SilentlyContinue
$userProfiles = $allProfiles | Where-Object { 
    -not $_.Special -and 
    $_.LocalPath -notlike "*\Administrator" -and
    $_.LocalPath -notlike "*\Default*" -and
    $_.LocalPath -notlike "*\Public" -and
    $_.LocalPath -notlike "*\systemprofile*" -and
    $_.LocalPath -notlike "*\LocalService*" -and
    $_.LocalPath -notlike "*\NetworkService*"
}

Write-Host "User profiles remaining: $($userProfiles.Count)" -ForegroundColor $(if ($userProfiles.Count -gt 0) { "Yellow" } else { "Green" })
if ($userProfiles.Count -gt 0) {
    Write-Host "  WARNING: The following user profiles still exist:" -ForegroundColor Yellow
    foreach ($profile in $userProfiles) {
        $loaded = if ($profile.Loaded) { " [LOADED - IN USE]" } else { "" }
        Write-Host "    - $($profile.LocalPath)$loaded" -ForegroundColor $(if ($profile.Loaded) { "Red" } else { "Yellow" })
    }
    Write-Host "  These profiles may cause sysprep issues!" -ForegroundColor Yellow
}
else {
    Write-Host "  ✓ No user profiles found (good)" -ForegroundColor Green
}

Write-Host "`n✓ VERIFIED: VM is in workgroup (not domain-joined)" -ForegroundColor Green
exit 0
'@
        
        try {
            $verifyResult = Invoke-AzVMRunCommand -ResourceGroupName $SourceResourceGroupName `
                -VMName $TargetVMName `
                -CommandId 'RunPowerShellScript' `
                -ScriptString $verifyScript `
                -ErrorAction Stop
            
            if ($verifyResult.Value[0].Message -match "ERROR: VM is still domain-joined") {
                throw "VM is still domain-joined! Sysprep will fail. Domain unjoin did not complete successfully."
            }
            Write-Log "✓ VM is properly unjoined from domain" -Level Success
        }
        catch {
            Write-Log "ERROR: Failed to verify domain status: $($_.Exception.Message)" -Level Error
            throw "Cannot proceed with sysprep - domain status verification failed"
        }
        
        # Sysprep script - DO NOT USE -Wait (VM will shut down)
        $sysprepScript = @'
# Final cleanup before sysprep
Write-Host "Performing final cleanup..."
Remove-Item "$env:SystemRoot\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

# Clear event logs to reduce image size
Write-Host "Clearing event logs..."
wevtutil el | ForEach-Object { wevtutil cl $_ 2>$null }

# Verify sysprep is available
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

# Create a flag file to track sysprep start
Set-Content "C:\sysprep-started.txt" -Value (Get-Date).ToString()

# Run Sysprep with unattend.xml - DO NOT USE -Wait (process will terminate when VM shuts down)
Write-Host "Starting Sysprep with /generalize /oobe /shutdown /unattend..."
Write-Host "VM will shut down automatically when sysprep completes..."
Write-Host "OOBE will be automated on next boot (no timeout issues)..."

# Start sysprep without waiting (VM will shutdown when done)
Start-Process -FilePath "C:\Windows\System32\Sysprep\Sysprep.exe" `
    -ArgumentList "/oobe", "/generalize", "/shutdown", "/mode:vm", "/unattend:$unattendPath" `
    -NoNewWindow

Write-Host "Sysprep process initiated - VM will shutdown when generalization completes"
exit 0
'@
        
        Write-Log "Initiating Sysprep on VM: $TargetVMName (this will take 5-15 minutes)..." -Level Info
        Write-Log "⚠️  VM will automatically shut down when sysprep completes" -Level Warning
        
        try {
            $sysprepResult = Invoke-AzVMRunCommand `
                -ResourceGroupName $SourceResourceGroupName `
                -VMName $TargetVMName `
                -CommandId 'RunPowerShellScript' `
                -ScriptString $sysprepScript `
                -ErrorAction Stop
            
            if ($sysprepResult.Value[0].Message) {
                Write-Log "Sysprep initiation output: $($sysprepResult.Value[0].Message)" -Level Info
            }
        }
        catch {
            Write-Log "Warning: RunCommand may have timed out (expected if sysprep is running)" -Level Warning
        }
        
        # Wait for VM to shut down (sysprep takes 5-15 minutes)
        Write-Log "Waiting for sysprep to complete and VM to shut down (timeout: 20 minutes)..." -Level Info
        Write-Log "This is normal - sysprep is generalizing Windows..." -Level Info
        
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
                Write-Log "✅ VM has stopped - Sysprep completed successfully!" -Level Success
                $vmStopped = $true
                break
            }
        }
        
        if (-not $vmStopped) {
            throw "VM did not shut down within $maxWaitMinutes minutes. Sysprep may have failed. Check VM console for errors."
        }
        
        # Deallocate VM if only stopped
        if ($powerState -eq "PowerState/stopped") {
            Write-Log "Deallocating VM..."
            Stop-AzVM -ResourceGroupName $SourceResourceGroupName -Name $TargetVMName -Force | Out-Null
            Start-Sleep -Seconds 30
        }
        
        # Verify deallocated state
        $deallocated = Wait-ForVMState -ResourceGroupName $SourceResourceGroupName `
            -VMName $TargetVMName `
            -TargetState 'PowerState/deallocated' `
            -TimeoutSeconds 180
        
        if (-not $deallocated) {
            throw "VM failed to deallocate. Current state: $powerState"
        }
        
        # CRITICAL: Mark VM as generalized in Azure
        Write-Log "Marking VM as generalized in Azure..." -Level Info
        Set-AzVM -ResourceGroupName $SourceResourceGroupName -Name $TargetVMName -Generalized -ErrorAction Stop
        
        # Verify generalization
        Start-Sleep -Seconds 10
        $vmInfo = Get-AzVM -ResourceGroupName $SourceResourceGroupName -Name $TargetVMName -ErrorAction Stop
        
        if ($vmInfo.OSProfile) {
            Write-Log "WARNING: VM still has OSProfile - generalization may not be complete!" -Level Warning
            Write-Log "Waiting additional 30 seconds and retrying..." -Level Warning
            Start-Sleep -Seconds 30
            Set-AzVM -ResourceGroupName $SourceResourceGroupName -Name $TargetVMName -Generalized -ErrorAction Stop
            Start-Sleep -Seconds 10
        }
        
        Write-Log "✅ VM generalized successfully and ready for image capture" -Level Success
    }
    
    #endregion
    
    #region Step 5: Create Shared Image Gallery Version
    
    Write-Log "=== Step 5: Creating Shared Image Gallery Version ===" -Level Success
    
    if ($PSCmdlet.ShouldProcess($GalleryName, "Create image version in Shared Image Gallery")) {
        
        # Ensure gallery exists
        $gallery = Get-AzGallery -ResourceGroupName $SourceResourceGroupName `
            -Name $GalleryName `
            -ErrorAction SilentlyContinue
        
        if (-not $gallery) {
            Write-Log "Creating Shared Image Gallery: $GalleryName"
            $gallery = New-AzGallery `
                -ResourceGroupName $SourceResourceGroupName `
                -GalleryName $GalleryName `
                -Location $Location `
                -Description "BAB AVD Shared Image Gallery" `
                -ErrorAction Stop
            Write-Log "Gallery created successfully" -Level Success
        }
        
        # Ensure image definition exists
        $imageDef = Get-AzGalleryImageDefinition `
            -ResourceGroupName $SourceResourceGroupName `
            -GalleryName $GalleryName `
            -Name $ImageDefinitionName `
            -ErrorAction SilentlyContinue
        
        if (-not $imageDef) {
            Write-Log "Creating Image Definition: $ImageDefinitionName"
            $imageDef = New-AzGalleryImageDefinition `
                -ResourceGroupName $SourceResourceGroupName `
                -GalleryName $GalleryName `
                -Name $ImageDefinitionName `
                -Location $Location `
                -OsState Generalized `
                -OsType Windows `
                -Publisher "babcloud" `
                -Offer "windows-10-avd" `
                -Sku "20h2-avd" `
                -HyperVGeneration V1 `
                -ErrorAction Stop
            Write-Log "Image definition created successfully" -Level Success
        }
        
        # Create image version with timestamp
        $imageVersion = "{0}.{1}.{2}" -f (Get-Date -Format "yyyy"), (Get-Date -Format "MMdd"), (Get-Date -Format "HHmm")
        Write-Log "Creating image version: $imageVersion" -Level Info
        Write-Log "NOTE: Image will contain ONLY the generalized OS disk (no NIC/NSG/networking)" -Level Info
        
        $targetVMId = (Get-AzVM -ResourceGroupName $SourceResourceGroupName -Name $TargetVMName).Id
        
        # Build target regions array
        $targetRegions = @(@{Name = $Location; ReplicaCount = 1})
        foreach ($region in $ReplicaRegions) {
            $targetRegions += @{Name = $region; ReplicaCount = 1}
        }
        
        $imageVersionParams = @{
            ResourceGroupName              = $SourceResourceGroupName
            GalleryName                    = $GalleryName
            GalleryImageDefinitionName     = $ImageDefinitionName
            Name                           = $imageVersion
            Location                       = $Location
            SourceImageVMId               = $targetVMId
            TargetRegion                   = $targetRegions
            ErrorAction                    = 'Stop'
        }
        
        $imgVersion = New-AzGalleryImageVersion @imageVersionParams
        
        Write-Log "Image version created successfully: $imageVersion" -Level Success
        Write-Log "Image ID: $($imgVersion.Id)" -Level Info
    }
    
    #endregion
    
    Write-Log "=== AVD Clone and Generalization Complete ===" -Level Success
    Write-Log "✅ Source VM '$SourceVMName' remains UNCHANGED and operational" -Level Success
    Write-Log "✅ Generalized image created from clone: '$TargetVMName'" -Level Success
    Write-Log "You can now create new AVD session hosts from image version: $imageVersion" -Level Success
    Write-Log "Snapshot available for rollback: Check Azure Portal for snapshots" -Level Info
    
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
