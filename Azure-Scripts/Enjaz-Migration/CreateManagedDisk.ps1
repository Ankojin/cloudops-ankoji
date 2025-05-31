# Variables
$resourceGroup = "enj-vdi-avd-weeu-rg-01"
$diskName = "MyManagedDisk"
$location = "westeurope"
$storageAccountName = "enjvdivmbootdiagweeu01"
$containerName = "migration"
$blobName = "ENJAVDPHEA-10-osdisk.vhd"
$diskSizeGB = 128
$osType = "Windows"  # Or "Linux"
$skuName = "Standard_LRS"

# Get storage account
$storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroup -Name $storageAccountName

# Build full blob URI (without SAS)
$blobUri = "https://$storageAccountName.blob.core.windows.net/$containerName/$blobName"

# Create disk config using IMPORT method
$diskConfig = New-AzDiskConfig `
    -Location $location `
    -CreateOption Import `
    -SourceUri $blobUri `
    -StorageAccountId $storageAccount.Id `
    -OsType $osType `
    -SkuName $skuName `
    -DiskSizeGB $diskSizeGB

# Create the managed disk
New-AzDisk -ResourceGroupName $resourceGroup -DiskName $diskName -Disk $diskConfig
