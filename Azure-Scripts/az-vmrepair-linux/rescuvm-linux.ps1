# Variables
$ResourceGroup   = "bab-sit-bpm-swec-rg-01"        # Resource Group where VMs live
$Location        = "swedencentral"                 # Region
$BrokenVM        = "DABPMAPWSILV1"             # Name of the failed VM
$RescueVM        = "DABPMAPWSILV1-rescuevm"             # New Rescue VM name
$RescueVMSize    = "Standard_D2s_v5"        # Size of Rescue VM
$RescueAdminUser = "azureuser"              # Admin username
$RescuePassword  = "P@ssw0rd@12345"     # Admin password (consider using a more secure method for production)
$VnetName        = "bab-sit-nw-swec-vnet-nonpci-01" 
$VnetNamerg      = "bab-sit-nw-swec-rg-01"      # Existing VNET (must be reachable by Bastion/jumpbox)
$SubnetName      = "snet-sit-nonpci-web-01"                # Existing Subnet

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Azure RHEL VM Rescue Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ----------------------------
# Check and cleanup previous rescue attempts
# ----------------------------
Write-Host "[*] Checking for previous rescue VM..."
$existingRescueVM = Get-AzVM -ResourceGroupName $ResourceGroup -Name $RescueVM -ErrorAction SilentlyContinue
if ($existingRescueVM) {
    Write-Host "[!] Found existing rescue VM: $RescueVM" -ForegroundColor Yellow
    $cleanup = Read-Host "Delete existing rescue VM and start fresh? (yes/no)"
    if ($cleanup -eq "yes") {
        Write-Host "[*] Stopping and deleting existing rescue VM..."
        Stop-AzVM -ResourceGroupName $ResourceGroup -Name $RescueVM -Force -ErrorAction SilentlyContinue | Out-Null
        Remove-AzVM -ResourceGroupName $ResourceGroup -Name $RescueVM -Force | Out-Null
        Write-Host "[✓] Existing rescue VM deleted" -ForegroundColor Green
        
        # Clean up associated resources
        $oldNIC = Get-AzNetworkInterface -ResourceGroupName $ResourceGroup | Where-Object { $_.Name -like "*$RescueVM*" }
        if ($oldNIC) {
            Remove-AzNetworkInterface -ResourceGroupName $ResourceGroup -Name $oldNIC.Name -Force -ErrorAction SilentlyContinue | Out-Null
            Write-Host "[✓] Old NIC deleted" -ForegroundColor Green
        }
        
        $oldDisk = Get-AzDisk -ResourceGroupName $ResourceGroup | Where-Object { $_.Name -like "*$RescueVM*" }
        if ($oldDisk) {
            Remove-AzDisk -ResourceGroupName $ResourceGroup -DiskName $oldDisk.Name -Force -ErrorAction SilentlyContinue | Out-Null
            Write-Host "[✓] Old rescue VM disk deleted" -ForegroundColor Green
        }
    } else {
        Write-Host "[!] Keeping existing rescue VM. Script will exit." -ForegroundColor Yellow
        exit 0
    }
}

Write-Host ""

# ----------------------------
# Get Broken VM OS Disk
# ----------------------------
$BrokenVMObj = Get-AzVM -ResourceGroupName $ResourceGroup -Name $BrokenVM
$BrokenDiskName = $BrokenVMObj.StorageProfile.OsDisk.Name
$BrokenDisk   = Get-AzDisk -ResourceGroupName $ResourceGroup -DiskName $BrokenDiskName

Write-Host "[*] OS Disk of broken VM: $($BrokenDisk.Name)"

# ----------------------------
# Stop Broken VM before detaching disk
# ----------------------------
Write-Host "[*] Stopping broken VM..."
Stop-AzVM -Name $BrokenVM -ResourceGroupName $ResourceGroup -Force

Write-Host "[*] Waiting for VM to fully stop..."
Start-Sleep -Seconds 10

# ----------------------------
# Create Snapshot of OS Disk (Azure doesn't allow detaching OS disk from stopped VM)
# ----------------------------
Write-Host "[*] Checking for existing snapshots..."

# Check if snapshot already exists from previous run
$existingSnapshots = Get-AzSnapshot -ResourceGroupName $ResourceGroup | Where-Object { $_.Name -like "$BrokenDiskName-snapshot-*" }
$Snapshot = $null

if ($existingSnapshots) {
    Write-Host "[!] Found $($existingSnapshots.Count) existing snapshot(s):" -ForegroundColor Yellow
    $existingSnapshots | ForEach-Object { Write-Host "    - $($_.Name)" -ForegroundColor Yellow }
    
    $useExisting = Read-Host "Use most recent existing snapshot? (yes/no)"
    if ($useExisting -eq "yes") {
        $Snapshot = $existingSnapshots | Sort-Object TimeCreated -Descending | Select-Object -First 1
        Write-Host "[✓] Using existing snapshot: $($Snapshot.Name)" -ForegroundColor Green
    } else {
        Write-Host "[*] Creating new snapshot..."
        $SnapshotName = "$BrokenDiskName-snapshot-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        $SnapshotConfig = New-AzSnapshotConfig -SourceUri $BrokenDisk.Id -Location $Location -CreateOption Copy
        $Snapshot = New-AzSnapshot -Snapshot $SnapshotConfig -SnapshotName $SnapshotName -ResourceGroupName $ResourceGroup
        Write-Host "[✓] Snapshot created: $SnapshotName" -ForegroundColor Green
    }
} else {
    Write-Host "[*] Creating snapshot of OS disk (Azure limitation: cannot detach OS disk)..."
    $SnapshotName = "$BrokenDiskName-snapshot-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $SnapshotConfig = New-AzSnapshotConfig -SourceUri $BrokenDisk.Id -Location $Location -CreateOption Copy
    $Snapshot = New-AzSnapshot -Snapshot $SnapshotConfig -SnapshotName $SnapshotName -ResourceGroupName $ResourceGroup
    Write-Host "[✓] Snapshot created: $SnapshotName" -ForegroundColor Green
}

# ----------------------------
# Create Copy Disk from Snapshot to Attach to Rescue VM
# ----------------------------
Write-Host "[*] Checking for existing copy disks..."

# Check and clean up old copy disks
$oldCopyDisks = Get-AzDisk -ResourceGroupName $ResourceGroup | Where-Object { $_.Name -like "$BrokenDiskName-copy-*" }
if ($oldCopyDisks) {
    Write-Host "[!] Found $($oldCopyDisks.Count) old copy disk(s)" -ForegroundColor Yellow
    $cleanupOld = Read-Host "Delete old copy disks? (yes/no)"
    if ($cleanupOld -eq "yes") {
        foreach ($oldDisk in $oldCopyDisks) {
            Write-Host "[*] Deleting old copy disk: $($oldDisk.Name)..."
            Remove-AzDisk -ResourceGroupName $ResourceGroup -DiskName $oldDisk.Name -Force -ErrorAction SilentlyContinue | Out-Null
        }
        Write-Host "[✓] Old copy disks deleted" -ForegroundColor Green
    }
}

Write-Host "[*] Creating copy of OS disk from snapshot..."

$CopyDiskName = "$BrokenDiskName-copy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$DiskConfig = New-AzDiskConfig -Location $Location -SourceResourceId $Snapshot.Id -CreateOption Copy
$CopyDisk = New-AzDisk -Disk $DiskConfig -ResourceGroupName $ResourceGroup -DiskName $CopyDiskName

Write-Host "[✓] Copy disk created: $CopyDiskName" -ForegroundColor Green

# ----------------------------
# Networking for Rescue VM (private IP only, no public IP)
# ----------------------------
$Vnet   = Get-AzVirtualNetwork -Name $VnetName -ResourceGroupName $VnetNamerg
$Subnet = Get-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $Vnet

$NICName = "$RescueVM-NIC"
# Create NIC without a public IP address
$NIC = New-AzNetworkInterface -Name $NICName `
    -ResourceGroupName $ResourceGroup `
    -Location $Location `
    -Subnet $Subnet

# ----------------------------
# Create Rescue VM (private only, no public IP, Standard Security)
# ----------------------------
Write-Host "[*] Creating Rescue VM with Standard SSD (no public IP)..."
Write-Host "[*] Generated Password: $RescuePassword" -ForegroundColor Yellow
$cred = New-Object System.Management.Automation.PSCredential ($RescueAdminUser,(ConvertTo-SecureString $RescuePassword -AsPlainText -Force))

$vmConfig = New-AzVMConfig -VMName $RescueVM -VMSize $RescueVMSize |
    Set-AzVMOperatingSystem -Linux -ComputerName $RescueVM -Credential $cred |
    Set-AzVMSourceImage -PublisherName "Canonical" -Offer "0001-com-ubuntu-server-jammy" -Skus "22_04-lts-gen2" -Version "latest" |
    Set-AzVMOSDisk -CreateOption FromImage -StorageAccountType StandardSSD_LRS -DiskSizeInGB 30 |
    Add-AzVMNetworkInterface -Id $NIC.Id

Write-Host "[*] OS Disk: Standard SSD (StandardSSD_LRS) - 30GB" -ForegroundColor Cyan

New-AzVM -ResourceGroupName $ResourceGroup -Location $Location -VM $vmConfig

# ----------------------------
# Attach Broken Disk Copy to Rescue VM
# ----------------------------
Write-Host "[*] Attaching OS disk copy to Rescue VM as data disk..."
$RescueVMObj = Get-AzVM -ResourceGroupName $ResourceGroup -Name $RescueVM
Add-AzVMDataDisk -VM $RescueVMObj -Name $CopyDisk.Name -ManagedDiskId $CopyDisk.Id -Lun 1 -CreateOption Attach
Update-AzVM -ResourceGroupName $ResourceGroup -VM $RescueVMObj

# ----------------------------
# Create Snapshots for Data Disks and Attach to Rescue VM
# ----------------------------
Write-Host "[*] Processing data disks for snapshot and attach..."
$DataDisks = $BrokenVMObj.StorageProfile.DataDisks
if ($DataDisks.Count -eq 0) {
    Write-Host "[!] No data disks found on broken VM." -ForegroundColor Yellow
} else {
    $lun = 2  # Start after OS disk (LUN 0) and first copy disk (LUN 1)
    foreach ($dataDisk in $DataDisks) {
        $dataDiskName = $dataDisk.Name
        $dataDiskObj = Get-AzDisk -ResourceGroupName $ResourceGroup -DiskName $dataDiskName
        Write-Host "[*] Creating snapshot for data disk: $dataDiskName..."
        $dataSnapshotName = "$dataDiskName-snapshot-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        $dataSnapshotConfig = New-AzSnapshotConfig -SourceUri $dataDiskObj.Id -Location $Location -CreateOption Copy
        $dataSnapshot = New-AzSnapshot -Snapshot $dataSnapshotConfig -SnapshotName $dataSnapshotName -ResourceGroupName $ResourceGroup
        Write-Host "[✓] Snapshot created: $dataSnapshotName" -ForegroundColor Green

        Write-Host "[*] Creating copy disk from snapshot for data disk: $dataDiskName..."
        $dataCopyDiskName = "$dataDiskName-copy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        $dataDiskConfig = New-AzDiskConfig -Location $Location -SourceResourceId $dataSnapshot.Id -CreateOption Copy
        $dataCopyDisk = New-AzDisk -Disk $dataDiskConfig -ResourceGroupName $ResourceGroup -DiskName $dataCopyDiskName
        Write-Host "[✓] Data disk copy created: $dataCopyDiskName" -ForegroundColor Green

        Write-Host "[*] Attaching data disk copy to Rescue VM (LUN $lun)..."
        $RescueVMObj = Add-AzVMDataDisk -VM $RescueVMObj -Name $dataCopyDisk.Name -ManagedDiskId $dataCopyDisk.Id -Lun $lun -CreateOption Attach
        $lun++
    }
    Update-AzVM -ResourceGroupName $ResourceGroup -VM $RescueVMObj
    Write-Host "[✓] All data disks attached to Rescue VM." -ForegroundColor Green
}

# Get Rescue VM IP Address
$rescueNIC = Get-AzNetworkInterface -ResourceId $RescueVMObj.NetworkProfile.NetworkInterfaces[0].Id
$rescueIP = $rescueNIC.IpConfigurations[0].PrivateIpAddress

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "✓ Rescue VM Setup Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Rescue VM Details:" -ForegroundColor Cyan
Write-Host "  Name:           $RescueVM"
Write-Host "  Private IP:     $rescueIP" -ForegroundColor Yellow
Write-Host "  Admin User:     $RescueAdminUser"
Write-Host "  Password:       $RescuePassword" -ForegroundColor Yellow
Write-Host ""
Write-Host "Disk Information:" -ForegroundColor Cyan
Write-Host "  Original Disk:  $($BrokenDisk.Name) (still on broken VM - safe)"
Write-Host "  Snapshot:       $($Snapshot.Name)"
Write-Host "  Copy Disk:      $($CopyDisk.Name) (attached to rescue VM)"
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "  1. Connect via Bastion or jumpbox:"
Write-Host "     ssh $RescueAdminUser@$rescueIP"
Write-Host ""
Write-Host "  2. Copy and run repair script:"
Write-Host "     scp fix-rhel-boot-azure.sh $RescueAdminUser@${rescueIP}:/tmp/"
Write-Host "     ssh $RescueAdminUser@$rescueIP"
Write-Host "     sudo bash /tmp/fix-rhel-boot-azure.sh"
Write-Host ""
Write-Host "  3. After repair completes, run restore script:"
Write-Host "     .\restore-vm-from-rescue.ps1 -ResourceGroup '$ResourceGroup' -BrokenVM '$BrokenVM' -RescueVM '$RescueVM'"
Write-Host ""
Write-Host "========================================" -ForegroundColor Green