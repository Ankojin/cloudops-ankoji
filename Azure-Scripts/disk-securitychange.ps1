# Variables
$rgName      = "bab-dev-mub-swec-rg-01"
$location    = "swedencentral"
$restoredDiskName = "damubscmapwv01-osdisk-20260706-132032"
$newDiskName = "damubscmapwv01-osdisk-20260706-restore"

# Get the restored disk (currently Standard) as the copy source
$restoredDisk = Get-AzDisk -ResourceGroupName $rgName -DiskName $restoredDiskName

# Build a new disk config, copying from the restored disk
$diskConfig = New-AzDiskConfig `
  -Location $location `
  -CreateOption Copy `
  -SourceResourceId $restoredDisk.Id `
  -OsType Windows   # or Linux, matching your OS

# Set the security profile to TrustedLaunch on the config BEFORE creating the disk
$diskConfig = Set-AzDiskSecurityProfile -Disk $diskConfig -SecurityType "TrustedLaunch"

# Now create the actual disk
$newDisk = New-AzDisk -ResourceGroupName $rgName -DiskName $newDiskName -Disk $diskConfig

# Verify
(Get-AzDisk -ResourceGroupName $rgName -DiskName $newDiskName).SecurityProfile