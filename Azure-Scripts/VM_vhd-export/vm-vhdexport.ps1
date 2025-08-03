# CONFIGURATION
$ResourceGroup = "MyResourceGroup"
$StorageAccountName = "mystorageacct"
$ContainerName = "vhds"
$SasDurationHours = 4
$LogFile = "C:\AzureVMExports\ExportLog.csv"

# Ensure export folder exists
$logFolder = Split-Path $LogFile
if (!(Test-Path $logFolder)) {
    New-Item -ItemType Directory -Path $logFolder | Out-Null
}

# Get storage account context
$StorageKey = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroup -Name $StorageAccountName)[0].Value
$Context = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageKey

# Ensure container exists
if (-not (Get-AzStorageContainer -Name $ContainerName -Context $Context -ErrorAction SilentlyContinue)) {
    New-AzStorageContainer -Name $ContainerName -Context $Context | Out-Null
    Write-Host "Created container: $ContainerName"
}

# Prepare log structure
$logResults = @()

# Get all VMs
$VMs = Get-AzVM -ResourceGroupName $ResourceGroup

foreach ($vm in $VMs) {
    $vmName = $vm.Name
    Write-Host "`nProcessing VM: $vmName" -ForegroundColor Cyan

    # === OS DISK ===
    $osDisk = Get-AzDisk -ResourceGroupName $ResourceGroup -DiskName $vm.StorageProfile.OsDisk.Name
    $osSas = Grant-AzDiskAccess -ResourceGroupName $ResourceGroup -DiskName $osDisk.Name -Access Read -DurationInSecond ($SasDurationHours * 3600)
    $osBlobName = "$vmName-OSDisk.vhd"

    $copy = Start-AzStorageBlobCopy -AbsoluteUri $osSas.AccessSAS -DestContainer $ContainerName -DestBlob $osBlobName -Context $Context
    Revoke-AzDiskAccess -ResourceGroupName $ResourceGroup -DiskName $osDisk.Name

    $logResults += [PSCustomObject]@{
        VMName         = $vmName
        DiskType       = "OS"
        DiskName       = $osDisk.Name
        BlobName       = $osBlobName
        CopyId         = $copy.CopyId
        StartTime      = (Get-Date)
        Status         = "Pending"
    }

    # === DATA DISKS ===
    foreach ($dataDisk in $vm.StorageProfile.DataDisks) {
        $disk = Get-AzDisk -ResourceGroupName $ResourceGroup -DiskName $dataDisk.Name
        $sas = Grant-AzDiskAccess -ResourceGroupName $ResourceGroup -DiskName $disk.Name -Access Read -DurationInSecond ($SasDurationHours * 3600)
        $blobName = "$vmName-DataDisk-LUN$($dataDisk.Lun).vhd"

        $copy = Start-AzStorageBlobCopy -AbsoluteUri $sas.AccessSAS -DestContainer $ContainerName -DestBlob $blobName -Context $Context
        Revoke-AzDiskAccess -ResourceGroupName $ResourceGroup -DiskName $disk.Name

        $logResults += [PSCustomObject]@{
            VMName         = $vmName
            DiskType       = "Data"
            DiskName       = $disk.Name
            BlobName       = $blobName
            CopyId         = $copy.CopyId
            StartTime      = (Get-Date)
            Status         = "Pending"
        }
    }
}

# === Wait for Copy Completion ===
Write-Host "`nWaiting for all blob copies to complete..." -ForegroundColor Yellow
$stillPending = $true
do {
    $stillPending = $false
    foreach ($entry in $logResults) {
        if ($entry.Status -ne "Success" -and $entry.Status -ne "Failed") {
            $copyState = Get-AzStorageBlobCopyState -Container $ContainerName -Blob $entry.BlobName -Context $Context
            $entry.Status = $copyState.Status
            if ($copyState.Status -eq "Success") {
                $entry.EndTime = (Get-Date)
                $entry.TotalBytesCopied = $copyState.TotalBytesCopied
            }
            elseif ($copyState.Status -eq "Pending") {
                $stillPending = $true
            }
            elseif ($copyState.Status -eq "Failed") {
                $entry.EndTime = (Get-Date)
            }
        }
    }

    Start-Sleep -Seconds 10
} while ($stillPending)

# === Export Log ===
$logResults | Export-Csv -Path $LogFile -NoTypeInformation
Write-Host "`n✅ Export complete. Log written to $LogFile" -ForegroundColor Green
