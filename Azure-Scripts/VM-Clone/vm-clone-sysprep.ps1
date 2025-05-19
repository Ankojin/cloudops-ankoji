# ---------------------------- CONFIGURATION ----------------------------
$sourceResourceGroup = "bab-vdi-avd-weeu-rg-01"
$targetResourceGroup = "bab-vdi-avd-weeu-rg-01"
$sourceVMName = "DEVAVDPHSA-2"
$newVMName = "BABAVDSHDTA-1"
$location = "westeurope"
$vnetrg  = "bab-vdi-nw-weeu-rg-01"
$vnetName = "bab-vdi-nw-weeu-vnet-vdi-01"
$subnetName = "snet-vdi-avd-01"
$nsgName = "test-vdi-join-nsg01"
$vmSize = "Standard_D8s_v5"
$useSSHOnly = $true  # Set to $false if you want password login for Linux

# ---------------------------- STOP SOURCE VM ----------------------------
$sourceVM = Get-AzVM -ResourceGroupName $sourceResourceGroup -Name $sourceVMName
if (-not $sourceVM) {
    throw "Source VM '$sourceVMName' not found in resource group '$sourceResourceGroup'."
}
# Stop-AzVM -ResourceGroupName $sourceResourceGroup -Name $sourceVMName -Force -NoWait
# Write-Host "Waiting for VM to deallocate..."

# Verify the source VM's OS disk
if (-not $sourceVM.StorageProfile -or -not $sourceVM.StorageProfile.OsDisk) {
    throw "Source VM '$sourceVMName' does not have a valid OS disk."
}

# Retrieve the OS disk
$osDisk = Get-AzDisk -ResourceGroupName $sourceResourceGroup -DiskName $sourceVM.StorageProfile.OsDisk.Name
if (-not $osDisk) {
    throw "OS disk for VM '$sourceVMName' could not be retrieved."
}

# Debugging output
Write-Host "OS Disk ID: $($osDisk.Id)"

# ---------------------------- OS DISK SNAPSHOT ----------------------------
# Check if the OS snapshot already exists
$snapshotOSName = "$newVMName-OSSnapshot"
$snapshotOS = Get-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotOSName -ErrorAction SilentlyContinue
if (-not $snapshotOS) {
    Write-Host "Creating OS snapshot '$snapshotOSName'..."
    $snapshotOS = New-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotOSName `
        -Snapshot (New-AzSnapshotConfig -SourceUri $osDisk.Id -Location $location -CreateOption Copy)
} else {
    Write-Host "OS snapshot '$snapshotOSName' already exists. Skipping creation."
}

# Check if the OS disk already exists
$newOSDiskName = "$newVMName-OSDisk"
$newOSDisk = Get-AzDisk -ResourceGroupName $targetResourceGroup -DiskName $newOSDiskName -ErrorAction SilentlyContinue
if (-not $newOSDisk) {
    Write-Host "Creating OS disk '$newOSDiskName'..."
    $newOSDisk = New-AzDisk -ResourceGroupName $targetResourceGroup -DiskName $newOSDiskName `
        -Disk (New-AzDiskConfig -Location $location -CreateOption Copy -SourceResourceId $snapshotOS.Id)
} else {
    Write-Host "OS disk '$newOSDiskName' already exists. Skipping creation."
}

# ---------------------------- CLONE DATA DISKS ----------------------------
$newDataDisks = @()
foreach ($dataDisk in $sourceVM.StorageProfile.DataDisks) {
    $disk = Get-AzDisk -ResourceGroupName $sourceResourceGroup -DiskName $dataDisk.Name

    # Check if the data disk snapshot already exists
    $snapshotName = "$newVMName-DataDisk-$($dataDisk.Lun)-Snap"
    $snapshot = Get-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotName -ErrorAction SilentlyContinue
    if (-not $snapshot) {
        Write-Host "Creating snapshot '$snapshotName' for data disk with LUN '$($dataDisk.Lun)'..."
        $snapshot = New-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotName `
            -Snapshot (New-AzSnapshotConfig -SourceUri $disk.Id -Location $location -CreateOption Copy)
    } else {
        Write-Host "Snapshot '$snapshotName' for data disk with LUN '$($dataDisk.Lun)' already exists. Skipping creation."
    }

    # Check if the cloned data disk already exists
    $clonedDiskName = "$newVMName-DataDisk-$($dataDisk.Lun)"
    $clonedDisk = Get-AzDisk -ResourceGroupName $targetResourceGroup -DiskName $clonedDiskName -ErrorAction SilentlyContinue
    if (-not $clonedDisk) {
        Write-Host "Creating cloned disk '$clonedDiskName'..."
        $clonedDisk = New-AzDisk -ResourceGroupName $targetResourceGroup -DiskName $clonedDiskName `
            -Disk (New-AzDiskConfig -Location $location -CreateOption Copy -SourceResourceId $snapshot.Id)
    } else {
        Write-Host "Cloned disk '$clonedDiskName' already exists. Skipping creation."
    }

    $newDataDisks += [PSCustomObject]@{Id=$clonedDisk.Id; Lun=$dataDisk.Lun}
}

# ---------------------------- CREATE NIC WITH NSG ----------------------------
$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $targetResourceGroup -Name $nsgName
$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetrg
$subnet = $vnet | Get-AzVirtualNetworkSubnetConfig -Name $subnetName

# Specify the desired static private IP address
$staticIpAddress = "10.189.50.143"  # Replace with your desired IP address

$nic = New-AzNetworkInterface -Name "$newVMName-NIC" -ResourceGroupName $targetResourceGroup `
    -Location $location `
    -SubnetId $subnet.Id `
    -NetworkSecurityGroupId $nsg.Id `
    -PrivateIpAddress $staticIpAddress

# ---------------------------- CONFIGURE NEW VM ----------------------------
$vmConfig = New-AzVMConfig -VMName $newVMName -VMSize $vmSize

$osType = $sourceVM.StorageProfile.OsDisk.OsType

if ($osType -eq "Linux") {
    # Attach the OS disk without setting an OS profile
    $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $newOSDisk.Id -CreateOption Attach -Linux
} elseif ($osType -eq "Windows") {
    # Attach the OS disk without setting an OS profile
    $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $newOSDisk.Id -CreateOption Attach -Windows
} else {
    throw "Unknown OS type: $osType"
}

$vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id

foreach ($disk in $newDataDisks) {
    $vmConfig = Add-AzVMDataDisk -VM $vmConfig `
        -ManagedDiskId $disk.Id -CreateOption Attach -Lun $disk.Lun
}

# ---------------------------- ENABLE BOOT DIAGNOSTICS ----------------------------
# Specify the storage account for boot diagnostics
$bootDiagStorageAccountName = "babvdivmbootdiag01"
$bootdiagstracctrg = "bab-vdi-avd-weeu-rg-01"  
$bootDiagStorageAccount = Get-AzStorageAccount -ResourceGroupName $bootdiagstracctrg -Name $bootDiagStorageAccountName

if (-not $bootDiagStorageAccount) {
    throw "Boot diagnostics storage account '$bootDiagStorageAccountName' not found in resource group '$bootdiagstracctrg'."
}

# Enable boot diagnostics directly in the VM configuration
$vmConfig.DiagnosticsProfile = @{
    BootDiagnostics = @{
        Enabled = $true
        StorageUri = $bootDiagStorageAccount.PrimaryEndpoints.Blob
    }
}

# ---------------------------- CREATE THE NEW VM ----------------------------
try {
    New-AzVM -ResourceGroupName $targetResourceGroup -Location $location -VM $vmConfig
} catch {
    throw "Failed to create the new VM '$newVMName'. Error: $_"
}

Write-Host "`n✅ VM '$newVMName' cloned from '$sourceVMName'. OS/data disks and NSG attached. No public IP."

# # ---------------------------- GENERALIZE CLONED VM WITH SYSPREP & UNATTEND ----------------------------
# $clonedVM = Get-AzVM -ResourceGroupName $targetResourceGroup -Name $newVMName
# if ($clonedVM.StorageProfile.OsDisk.OsType -eq "Windows") {
#     Write-Host "Preparing to generalize cloned VM '$newVMName' with Sysprep and unattend.xml..."

#     # Ensure the VM is running
#     $vmStatus = (Get-AzVM -ResourceGroupName $targetResourceGroup -Name $newVMName -Status).Statuses | Where-Object { $_.Code -like "PowerState*" }
#     if ($vmStatus.DisplayStatus -ne "VM running") {
#         Write-Host "Starting cloned VM..."
#         Start-AzVM -ResourceGroupName $targetResourceGroup -Name $newVMName | Out-Null
#         Start-Sleep -Seconds 60
#     }

#     # Path to unattend.xml (update this to your actual location or storage URL)
#     $unattendUrl = "<YOUR_UNATTEND_XML_URL>" # e.g., https://<storageaccount>.blob.core.windows.net/scripts/unattend.xml

#     # Prepare Sysprep script
#     $sysprepScript = @"
# Invoke-WebRequest -Uri '$unattendUrl' -OutFile 'C:\unattend.xml'
# Start-Process -FilePath 'C:\Windows\System32\Sysprep\Sysprep.exe' -ArgumentList '/generalize /oobe /shutdown /unattend:C:\unattend.xml /quiet' -Wait
# "@
#     $scriptFile = "sysprep-unattend.ps1"
#     Set-Content -Path $scriptFile -Value $sysprepScript

#     # Run the script using Custom Script Extension
#     Set-AzVMCustomScriptExtension -ResourceGroupName $targetResourceGroup `
#         -VMName $newVMName `
#         -Name "SysprepUnattendExtension" `
#         -Location $location `
#         -FileUri "" `
#         -Run "powershell -ExecutionPolicy Unrestricted -Command `$sysprepScript" `
#         -Force

#     Write-Host "Waiting for VM to shutdown after Sysprep..."
#     do {
#         Start-Sleep -Seconds 15
#         $vmStatus = (Get-AzVM -ResourceGroupName $targetResourceGroup -Name $newVMName -Status).Statuses | Where-Object { $_.Code -like "PowerState*" }
#     } while ($vmStatus.DisplayStatus -ne "VM deallocated")

#     Write-Host "Sysprep with unattend.xml complete. VM is deallocated and generalized."
# } else {
#     Write-Host "Sysprep is only applicable to Windows VMs. Skipping for OS type: $($clonedVM.StorageProfile.OsDisk.OsType)"
# }
