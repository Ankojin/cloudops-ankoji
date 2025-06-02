# --------------------------------------------
# CONFIGURE THESE VARIABLES
# --------------------------------------------
$ResourceGroup = "bab-vdi-avd-weeu-rg-01"
$VMName        = "BABAVDsysimg"
$ImageName     = "New-AVD-win10-Image"
$Location      = "westeurope"

# --------------------------------------------
# LOGIN IF NEEDED
# --------------------------------------------
#Connect-AzAccount

# --------------------------------------------
# GENERALIZE THE VM IN AZURE
# --------------------------------------------
Write-Host "Generalizing VM: $VMName..." -ForegroundColor Yellow
Set-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -Generalized

# --------------------------------------------
# GET VM AND OS DISK
# --------------------------------------------
$vm = Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroup
$osDiskId = $vm.StorageProfile.OsDisk.ManagedDisk.Id

# --------------------------------------------
# CREATE IMAGE CONFIGURATION
# --------------------------------------------
$imageConfig = New-AzImageConfig -Location $Location

$imageConfig = Set-AzImageOsDisk -Image $imageConfig `
    -OsState Generalized `
    -OsType Windows `
    -ManagedDiskId $osDiskId

# --------------------------------------------
# CREATE MANAGED IMAGE
# --------------------------------------------
Write-Host "Creating managed image: $ImageName..." -ForegroundColor Green

$image = New-AzImage -ImageName $ImageName `
    -ResourceGroupName $ResourceGroup `
    -Image $imageConfig

Write-Host "✅ Managed image '$ImageName' created successfully in '$ResourceGroup'." -ForegroundColor Cyan
