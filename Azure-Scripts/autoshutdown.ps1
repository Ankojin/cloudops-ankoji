# Variables
$ResourceGroup = "bab-dev-mub-swec-rg-01"
$ShutdownTime = "2000"   # 8 PM UTC
$TimeZone = "Arab Standard Time"        # Or "Pacific Standard Time"
#$Email = "alerts@contoso.com" # Optional

# Get all VMs in the resource group
$VMs = Get-AzVM -ResourceGroupName $ResourceGroup

foreach ($vm in $VMs) {
    Write-Host "Configuring auto-shutdown for VM:" $vm.Name

    az vm auto-shutdown `
        --resource-group $ResourceGroup `
        --name $vm.Name `
        --time $ShutdownTime `
        --timezone $TimeZone
}