#Requires -Version 5.1
# Create-ArcRhelVM-WithProxy.ps1

# --------------------- Configuration ---------------------
$resourceGroup    = "bab-srvai-swec-rg-01"                  # ← YOUR RG
$location         = "westeurope"                                # ← YOUR REGION
$vmName           = "testvm"
$computerName     = $vmName
$adminUsername    = "azureadmin"

# SSH public key (recommended for Linux)
$sshPublicKeyPath = "C:\Users\AnkojiRaoNagisetty\.ssh\testvm_id_rsa.pub"     # ← PATH TO YOUR .pub FILE
$sshKeyContent    = Get-Content $sshPublicKeyPath -Raw      # Reads key content

# IDs - replace with yours
# Optional
$customLocationId = "/subscriptions/60b0404e-72cf-480e-9c95-bf013fa7ca3c/resourceGroups/bab-Azl-AZSt-weeu-rg-01/providers/Microsoft.ExtendedLocation/customLocations/AlMonisyah_UAT"
$imageId          = "/subscriptions/60b0404e-72cf-480e-9c95-bf013fa7ca3c/resourceGroups/bab-Azl-AZSt-weeu-rg-01/providers/microsoft.azurestackhci/galleryImages/Redhat-Ent-v8-8"  # ← YOUR RHEL IMAGE (e.g. 9.x)
$nicId            = "/subscriptions/YOUR-SUB-ID/resourceGroups/$resourceGroup/providers/Microsoft.Network/networkInterfaces/your-nic-name"

# Optional
$storagePathId    = "/subscriptions/60b0404e-72cf-480e-9c95-bf013fa7ca3c/resourceGroups/bab-Azl-AZSt-weeu-rg-01/providers/Microsoft.AzureStackHCI/storageContainers/UserStorage5-5746cecde9f7485dbf550167b4197c26"  # or full ID

# Proxy (for agent onboarding)
$proxyHttp        = "http://proxyuser:proxypass@proxy.contoso.com:8080"
$proxyHttps       = "http://proxyuser:proxypass@proxy.contoso.com:8080"
$proxyNoProxy     = "localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.contoso.com"
$proxyCertPath    = ""  # Optional: host path to CA cert

# Hardware
$processors       = 4
$memoryMB         = 8192

# --------------------- Create VM ---------------------
Write-Host "Creating RHEL Arc-enabled VM: $vmName" -ForegroundColor Cyan

az stack-hci-vm create `
    --name $vmName `
    --resource-group $resourceGroup `
    --location $location `
    --admin-username $adminUsername `
    --computer-name $computerName `
    --image $imageId `
    --nics $nicId `
    --custom-location $customLocationId `
    --hardware-profile "memory-mb=$memoryMB" "processors=$processors" `
    --storage-path-id $storagePathId `
    --enable-secure-boot true `
    --enable-vtpm true `
    --security-type TrustedLaunch `
    --authentication-type ssh `
    --ssh-key-values $sshKeyContent `
    --enable-agent true `
    --proxy-configuration `
        http_proxy="$proxyHttp" `
        https_proxy="$proxyHttps" `
        no_proxy="$proxyNoProxy" `
        cert_file_path="$proxyCertPath" `
    --output table

# --------------------- Monitor ---------------------
Write-Host "Waiting for provisioning..." -ForegroundColor Yellow

do {
    Start-Sleep -Seconds 30
    $status = az stack-hci-vm show --name $vmName --resource-group $resourceGroup --query "provisioningState" --output tsv
    Write-Host "State: $status"
} while ($status -notin @("Succeeded", "Failed", $null))

if ($status -eq "Succeeded") {
    Write-Host "Success!" -ForegroundColor Green
    az stack-hci-vm show --name $vmName --resource-group $resourceGroup --output table
} else {
    Write-Host "Failed - details:" -ForegroundColor Red
    az stack-hci-vm show --name $vmName --resource-group $resourceGroup --output json
}