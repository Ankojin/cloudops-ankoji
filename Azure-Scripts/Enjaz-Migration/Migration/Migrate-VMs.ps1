# Set working directory
$WorkingDirectory = "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\Azure-Scripts\Enjaz-Migration\Migration"
$csvPath = "$WorkingDirectory\vm-migration.csv"
$failedLogPath = "$WorkingDirectory\failed.txt"
$logDir = "$WorkingDirectory\Logs"

# Enable or disable dry run
$DryRun = $false  # Set to $true for simulation
#
# Ensure log folder exists
if (-not (Test-Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory | Out-Null
}

# Clear failed log
if (-not $DryRun -and (Test-Path $failedLogPath)) {
    Clear-Content -Path $failedLogPath
}

# Helper: Connect to Azure with Service Principal
function Connect-AzWithSP {
    param (
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$SubscriptionId
    )
    $secureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($ClientId, $secureSecret)
    Connect-AzAccount -ServicePrincipal -Credential $cred -Tenant $TenantId -Subscription $SubscriptionId | Out-Null
}

# Import VM list
$vms = Import-Csv $csvPath

foreach ($row in $vms) {
    $vmName = $row.VMName
    $logFile = "$logDir\$vmName.log"
    $location = ""

    # Resume support
    if ((Test-Path $logFile) -and ((Get-Content $logFile -Raw) -match "✅ Migration completed")) {
        Write-Host "✔️  Skipping $vmName (already migrated)"
        continue
    }

    try {
        Add-Content $logFile "`n>>> Connecting to Source: $($row.SourceSubscription)"
        Connect-AzWithSP -TenantId $row.SourceTenantId -ClientId $row.SourceClientId -ClientSecret $row.SourceClientSecret -SubscriptionId $row.SourceSubscription

        # Get VM
        $vm = Get-AzVM -Name $vmName -ResourceGroupName $row.SourceResourceGroup
        $location = $vm.Location

        # Take OS snapshot
        $osDisk = Get-AzDisk -ResourceId $vm.StorageProfile.OsDisk.ManagedDisk.Id
        $osSnapName = "$vmName-osdisk-snap"
        if (-not $DryRun) {
            $osSnapConfig = New-AzSnapshotConfig -SourceUri $osDisk.Id -Location $location -CreateOption Copy
            $osSnap = New-AzSnapshot -ResourceGroupName $row.SourceResourceGroup -SnapshotName $osSnapName -Snapshot $osSnapConfig
        }

        # Take data disk snapshots
        $dataSnapshots = @()
        foreach ($dataDisk in $vm.StorageProfile.DataDisks) {
            $disk = Get-AzDisk -ResourceId $dataDisk.ManagedDisk.Id
            $snapName = "$vmName-$($dataDisk.Name)-snap"
            if (-not $DryRun) {
                $snapConfig = New-AzSnapshotConfig -SourceUri $disk.Id -Location $location -CreateOption Copy
                $snap = New-AzSnapshot -ResourceGroupName $row.SourceResourceGroup -SnapshotName $snapName -Snapshot $snapConfig
                $dataSnapshots += $snap
            }
        }

        # Connect to target tenant
        Add-Content $logFile "`n>>> Connecting to Target: $($row.TargetSubscription)"
        Connect-AzWithSP -TenantId $row.TargetTenantId -ClientId $row.TargetClientId -ClientSecret $row.TargetClientSecret -SubscriptionId $row.TargetSubscription

        # Resolve target names
        $targetVmName = if ($row.TargetVMName) { $row.TargetVMName } else { $vmName }

        # Create target OS disk
        if (-not $DryRun) {
            $osDiskConfig = New-AzDiskConfig -AccountType StandardSSD_LRS -Location $location -CreateOption Copy -SourceResourceId $osSnap.Id
            $targetOsDisk = New-AzDisk -ResourceGroupName $row.TargetResourceGroup -DiskName "$targetVmName-osdisk" -Disk $osDiskConfig
        }

        # Create target data disks
        $targetDataDisks = @()
        for ($i=0; $i -lt $dataSnapshots.Count; $i++) {
            $snap = $dataSnapshots[$i]
            if (-not $DryRun) {
                $diskConfig = New-AzDiskConfig -AccountType StandardSSD_LRS -Location $location -CreateOption Copy -SourceResourceId $snap.Id
                $disk = New-AzDisk -ResourceGroupName $row.TargetResourceGroup -DiskName "$targetVmName-datadisk$i" -Disk $diskConfig
                $targetDataDisks += $disk
            }
        }

        # Create NIC
        $vnet = Get-AzVirtualNetwork -ResourceGroupName $row.TargetVNetResourceGroup -Name $row.TargetVNetName
        $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $row.TargetSubnetName }
        $nicName = "$targetVmName-nic"
        if (-not $DryRun) {
            $ipConfig = New-AzNetworkInterfaceIpConfig -Name "ipconfig1" -SubnetId $subnet.Id -PrivateIpAddress $row.TargetStaticIP
            $nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $row.TargetResourceGroup -Location $location -IpConfiguration $ipConfig
        }

        # VM config
        $vmConfig = New-AzVMConfig -VMName $targetVmName -VMSize $row.TargetVMSize
        if ($row.OSType -eq "Windows") {
            $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Windows -ComputerName $targetVmName -ProvisionVMAgent -EnableAutoUpdate
        } elseif ($row.OSType -eq "Linux") {
            $securePass = ConvertTo-SecureString $row.LinuxAdminPassword -AsPlainText -Force
            $cred = New-Object PSCredential($row.LinuxAdminUsername, $securePass)
            $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $targetVmName -Credential $cred -DisablePasswordAuthentication:$false
        }

        # Attach disks and NIC
        if (-not $DryRun) {
            $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $targetOsDisk.Id -CreateOption Attach -Linux:($row.OSType -eq "Linux") -Windows:($row.OSType -eq "Windows")
            for ($i=0; $i -lt $targetDataDisks.Count; $i++) {
                $vmConfig = Add-AzVMDataDisk -VM $vmConfig -Name $targetDataDisks[$i].Name -ManagedDiskId $targetDataDisks[$i].Id -Lun $i -Caching ReadWrite -DiskSizeInGB $targetDataDisks[$i].DiskSizeGB
            }
            $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id
            New-AzVM -ResourceGroupName $row.TargetResourceGroup -Location $location -VM $vmConfig
        }

        Add-Content $logFile "✅ Migration completed for $vmName"
        Write-Host "✅ Migrated $vmName" -ForegroundColor Green
    }
    catch {
        $errorMsg = "Migration failed for VM '$vmName' - Error: $_"
        Write-Warning $errorMsg
        Add-Content $logFile "❌ $errorMsg"
        Add-Content $failedLogPath $vmName
    }
}