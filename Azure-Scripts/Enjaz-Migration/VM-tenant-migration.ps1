# function Connect-AzAccountWithSP {
#     param(
#         [string]$TenantId,
#         [string]$ClientId,
#         [string]$ClientSecret,
#         [string]$SubscriptionId
#     )

#     $secureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
#     $cred = New-Object System.Management.Automation.PSCredential($ClientId, $secureSecret)

#     Connect-AzAccount -ServicePrincipal -Credential $cred -Tenant $TenantId -Subscription $SubscriptionId | Out-Null
# }

# Import CSV with migration and SP details
$workingDirectory = "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\Azure-Scripts\Enjaz-Migration"
$csv = Import-Csv -Path "$workingDirectory\vm-migration.csv"

foreach ($row in $csv) {

    Write-Host "Connecting to source tenant subscription $($row.SourceSubscription) using SP..."
    Connect-AzAccountWithSP -TenantId $row.SourceTenantId -ClientId $row.SourceClientId -ClientSecret $row.SourceClientSecret -SubscriptionId $row.SourceSubscription

    # Get source VM object
    $vm = Get-AzVM -Name $row.VMName -ResourceGroupName $row.SourceResourceGroup

    # Snapshot OS disk
    $osDiskId = $vm.StorageProfile.OsDisk.ManagedDisk.Id
    $osDisk = Get-AzDisk -ResourceId $osDiskId
    $osSnapName = $vm.Name + "-osdisk-snap"
    $osSnap = New-AzSnapshot -ResourceGroupName $row.SourceResourceGroup -SnapshotName $osSnapName -SourceUri $osDisk.Id -Location $vm.Location -CreateOption Copy

    # Snapshot data disks (if any)
    $dataSnapshots = @()
    foreach ($dataDisk in $vm.StorageProfile.DataDisks) {
        $dataSnapName = $vm.Name + "-" + $dataDisk.Name + "-snap"
        $disk = Get-AzDisk -ResourceId $dataDisk.ManagedDisk.Id
        $snap = New-AzSnapshot -ResourceGroupName $row.SourceResourceGroup -SnapshotName $dataSnapName -SourceUri $disk.Id -Location $vm.Location -CreateOption Copy
        $dataSnapshots += $snap
    }

    # Connect to target tenant subscription
    Write-Host "Connecting to target tenant subscription $($row.TargetSubscription) using SP..."
    Connect-AzAccountWithSP -TenantId $row.TargetTenantId -ClientId $row.TargetClientId -ClientSecret $row.TargetClientSecret -SubscriptionId $row.TargetSubscription

    # Determine target VM name (optional override)
    $targetVmName = if ($row.TargetVMName) { $row.TargetVMName } else { $vm.Name }

    # Create managed OS disk from snapshot
    $targetOsDiskConfig = New-AzDiskConfig -AccountType Premium_LRS -Location $vm.Location -CreateOption Copy -SourceResourceId $osSnap.Id
    $targetOsDisk = New-AzDisk -ResourceGroupName $row.TargetResourceGroup -DiskName ($targetVmName + "-osdisk") -Disk $targetOsDiskConfig

    # Create managed data disks from snapshots
    $targetDataDisks = @()
    for ($i=0; $i -lt $dataSnapshots.Count; $i++) {
        $dataDiskConfig = New-AzDiskConfig -AccountType Premium_LRS -Location $vm.Location -CreateOption Copy -SourceResourceId $dataSnapshots[$i].Id
        $dataDisk = New-AzDisk -ResourceGroupName $row.TargetResourceGroup -DiskName ($targetVmName + "-datadisk" + $i) -Disk $dataDiskConfig
        $targetDataDisks += $dataDisk
    }

    # Create NIC with static IP on target VNet/subnet
    $vnet = Get-AzVirtualNetwork -ResourceGroupName $row.TargetVNetResourceGroup -Name $row.TargetVNetName
    $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $row.TargetSubnetName }
    $nicName = $targetVmName + "-nic"

    $ipConfig = New-AzNetworkInterfaceIpConfig -Name "ipconfig1" -SubnetId $subnet.Id -PrivateIpAddress $row.TargetStaticIP
    $nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $row.TargetResourceGroup -Location $vm.Location -IpConfiguration $ipConfig

    # Prepare VM config
    $vmConfig = New-AzVMConfig -VMName $targetVmName -VMSize $row.TargetVMSize

    if ($row.OSType -eq "Windows") {
        $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Windows -ComputerName $targetVmName -ProvisionVMAgent -EnableAutoUpdate
    }
    elseif ($row.OSType -eq "Linux") {
        if (-not [string]::IsNullOrEmpty($row.LinuxAdminUsername) -and -not [string]::IsNullOrEmpty($row.LinuxAdminPassword)) {
            $securePass = ConvertTo-SecureString $row.LinuxAdminPassword -AsPlainText -Force
            $cred = New-Object System.Management.Automation.PSCredential($row.LinuxAdminUsername, $securePass)
            $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $targetVmName -Credential $cred -DisablePasswordAuthentication:$false
        }
        else {
            # Enable password authentication without password - you may want to customize this behavior
            $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $targetVmName -DisablePasswordAuthentication:$false
        }
    }

    # Attach OS disk (existing managed disk)
    $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $targetOsDisk.Id -CreateOption Attach -Linux:($row.OSType -eq "Linux") -Windows:($row.OSType -eq "Windows")

    # Attach data disks (if any)
    for ($i=0; $i -lt $targetDataDisks.Count; $i++) {
        $vmConfig = Add-AzVMDataDisk -VM $vmConfig -Name $targetDataDisks[$i].Name -ManagedDiskId $targetDataDisks[$i].Id -Lun $i -Caching ReadWrite -DiskSizeInGB $targetDataDisks[$i].DiskSizeGB
    }

    # Attach NIC
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id

    # Create the VM on target subscription/resource group
    New-AzVM -ResourceGroupName $row.TargetResourceGroup -Location $vm.Location -VM $vmConfig

    Write-Host "Migrated VM '$($vm.Name)' as '$targetVmName' successfully!"
}