# Variables
$ResourceGroup   = "bab-sit-cortex-swec-rg-01"        # Resource Group where VMs live
$Location        = "swedencentral"                 # Region
$BrokenVM        = "DAFISDBORILV3"             # Name of the failed VM
$RescueVM        = "rescuevm-linux"             # New Rescue VM name
$RescueVMSize    = "Standard_D2s_v5"        # Size of Rescue VM
$RescueAdminUser = "azureuser"              # Admin username
$RescuePassword  = "P@ssw0rd12345!"         # Strong password
$VnetName        = "bab-sit-nw-swec-vnet-nonpci-01" 
$VnetNamerg      = "bab-sit-nw-swec-rg-01"      # Existing VNET (must be reachable by Bastion/jumpbox)
$SubnetName      = "snet-sit-nonpci-db-02"                # Existing Subnet

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
#Stop-AzVM -Name $BrokenVM -ResourceGroupName $ResourceGroup -Force

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
# Create Rescue VM (private only, no public IP, disable Trusted Launch)
# ----------------------------
Write-Host "[*] Creating Rescue VM with private IP only (no public IP)..."
$cred = New-Object System.Management.Automation.PSCredential ($RescueAdminUser,(ConvertTo-SecureString $RescuePassword -AsPlainText -Force))

$vmConfig = New-AzVMConfig -VMName $RescueVM -VMSize $RescueVMSize -SecurityType "TrustedLaunch" |
    Set-AzVMOperatingSystem -Linux -ComputerName $RescueVM -Credential $cred |
    Set-AzVMSourceImage -PublisherName "OpenLogic" -Offer "CentOS" -Skus "7_9" -Version "latest" |
    Add-AzVMNetworkInterface -Id $NIC.Id

New-AzVM -ResourceGroupName $ResourceGroup -Location $Location -VM $vmConfig

# ----------------------------
# Attach Broken Disk to Rescue VM
# ----------------------------
Write-Host "[*] Attaching broken OS disk to Rescue VM..."
$RescueVMObj = Get-AzVM -ResourceGroupName $ResourceGroup -Name $RescueVM
Add-AzVMDataDisk -VM $RescueVMObj -Name $BrokenDisk.Name -ManagedDiskId $BrokenDisk.Id -Lun 1 -CreateOption Attach
Update-AzVM -ResourceGroupName $ResourceGroup -VM $RescueVMObj

Write-Host ""
Write-Host "[*] Rescue VM $RescueVM created with private IP only."
Write-Host "[*] Broken VM OS disk '$($BrokenDisk.Name)' is now attached to Rescue VM as a data disk."
Write-Host "[*] Connect via Azure Bastion or a jumpbox and run your grub fix script."