# ==========================================
# Configuration
# ==========================================

$SubscriptionId = "e48414cd-f96d-4414-ae9e-da7fec844f77"
$ResourceGroup  = "bab-sit-new-bib-swec-rg-01"
$StorageAccount = "babsitnewbibstrgacct01"
$ShareName      = "newbib-fs-nfs-01"

Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

# ==========================================
# Storage Account
# ==========================================

Write-Host "========== Storage Account ==========" -ForegroundColor Cyan

$storage = Get-AzStorageAccount `
    -ResourceGroupName $ResourceGroup `
    -Name $StorageAccount

$storage | Select-Object `
    StorageAccountName,
    Kind,
    SkuName,
    PrimaryLocation,
    ProvisioningState

# ==========================================
# NFS Share
# ==========================================

Write-Host "`n========== NFS Share ==========" -ForegroundColor Cyan

$share = az storage share-rm show `
    --resource-group $ResourceGroup `
    --storage-account $StorageAccount `
    --name $ShareName | ConvertFrom-Json

$share | Select-Object `
    name,
    enabledProtocols,
    rootSquash,
    shareQuota,
    accessTier,
    lastModifiedTime

# ==========================================
# Private Endpoint
# ==========================================

Write-Host "`n========== Private Endpoints ==========" -ForegroundColor Cyan

Get-AzPrivateEndpoint -ResourceGroupName $ResourceGroup |
Select-Object Name, ProvisioningState

# ==========================================
# Firewall Rules
# ==========================================

Write-Host "`n========== Storage Firewall ==========" -ForegroundColor Cyan

$storage.NetworkRuleSet | Format-List

# ==========================================
# Private DNS Zone
# ==========================================

Write-Host "`n========== Private DNS ==========" -ForegroundColor Cyan

Get-AzPrivateDnsZone |
Where-Object {$_.Name -eq "privatelink.file.core.windows.net"}

# ==========================================
# Summary
# ==========================================

Write-Host "`n========== Summary ==========" -ForegroundColor Green

Write-Host "Storage Account :" $storage.StorageAccountName
Write-Host "Kind            :" $storage.Kind
Write-Host "SKU             :" $storage.SkuName
Write-Host "Share           :" $share.name
Write-Host "Protocol        :" $share.enabledProtocols
Write-Host "Root Squash     :" $share.rootSquash
Write-Host "Quota (GiB)     :" $share.shareQuota