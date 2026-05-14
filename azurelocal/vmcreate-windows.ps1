#Requires -Version 5.1
# Create-ArcWindowsVM-WithProxy.ps1

# --------------------- Configuration ---------------------
$resourceGroup    = "bab-srvai-swec-rg-01"                  # ← YOUR RG
$location         = "eastus"                                # ← YOUR REGION
$vmName           = "MyWinArcVM"
$computerName     = $vmName
$adminUsername    = "azureadmin"
$adminPassword    = "ComplexP@ssw0rd123!ChangeMeNow"       # ← CHANGE THIS (secure in prod)

# IDs - replace with yours
$customLocationId = "/subscriptions/YOUR-SUB-ID/resourceGroups/$resourceGroup/providers/Microsoft.ExtendedLocation/customLocations/YOUR-CUSTOM-LOCATION-NAME"
$imageId          = "/subscriptions/YOUR-SUB-ID/resourceGroups/$resourceGroup/providers/Microsoft.AzureStackHCI/marketplaceGalleryImages/WindowsServer2022Datacenter"  # ← YOUR WINDOWS IMAGE
$nicId            = "/subscriptions/YOUR-SUB-ID/resourceGroups/$resourceGroup/providers/Microsoft.Network/networkInterfaces/your-nic-name"

# Optional
$storagePathId    = ""  # e.g. "/subscriptions/.../storagePaths/YourPath" or leave empty

# Proxy (for agent onboarding)
$proxyHttp        = "http://proxyuser:proxypass@proxy.contoso.com:8080"
$proxyHttps       = "http://proxyuser:proxypass@proxy.contoso.com:8080"
$proxyNoProxy     = "localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.contoso.com"
$proxyCertPath    = ""  # Optional: "C:\ClusterStorage\...\proxy-ca.crt"

# Hardware
$processors       = 4
$memoryMB         = 8192

# --------------------- Create VM ---------------------
Write-Host "Creating Windows Arc-enabled VM: $vmName" -ForegroundColor Cyan

az stack-hci-vm create `
    --name $vmName `
    --resource-group $resourceGroup `
    --location $location `
    --admin-username $adminUsername `
    --admin-password $adminPassword `
    --computer-name $computerName `
    --image $imageId `
    --nics $nicId `
    --custom-location $customLocationId `
    --hardware-profile "memory-mb=$memoryMB" "processors=$processors" `
    --storage-path-id $storagePathId `
    --enable-secure-boot true `
    --enable-vtpm true `
    --security-type TrustedLaunch `
    --authentication-type password `
    --enable-agent true `
    --proxy-configuration `
        http_proxy="$proxyHttp" `
        https_proxy="$proxyHttps" `
        no_proxy="$proxyNoProxy" `
        cert_file_path="$proxyCertPath" `
    --output table

# --------------------- Monitor ---------------------
Write-Host "Waiting for provisioning (may take 5-15 min)..." -ForegroundColor Yellow

do {
    Start-Sleep -Seconds 30
    $status = az stack-hci-vm show --name $vmName --resource-group $resourceGroup --query "provisioningState" --output tsv
    Write-Host "State: $status"
} while ($status -notin @("Succeeded", "Failed", $null))

if ($status -eq "Succeeded") {
    Write-Host "Success! VM ready." -ForegroundColor Green
    az stack-hci-vm show --name $vmName --resource-group $resourceGroup --output table
} else {
    Write-Host "Failed - check details:" -ForegroundColor Red
    az stack-hci-vm show --name $vmName --resource-group $resourceGroup --output json
}