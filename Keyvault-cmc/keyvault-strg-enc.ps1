# -----------------------
# CONFIGURATION
# -----------------------
$location = "westeurope"
$centralSubscriptionId = "6ba165ee-ec4d-4003-ac84-f4211cd84f0e"
$resourceGroup = "sandbox-nw-rg01"
$keyVaultName = "kv-cmk-ankoji-tests-01"
$keyName = "cmk-key"
$identityName = "id-cmk-storage"
$csvPath = "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\Keyvault-cmc\strgacct.csv"

# -----------------------
# CONNECT AND SELECT CENTRAL SUBSCRIPTION
# -----------------------
#Connect-AzAccount
Select-AzSubscription -SubscriptionId $centralSubscriptionId -TenantId cd7bd4e0-1364-439d-8dc4-bc0ef1fb2bf5
# -----------------------
# -----------------------
# CHECK OR CREATE KEY VAULT (Access Policy Mode)
# -----------------------
$keyVault = Get-AzKeyVault -VaultName $keyVaultName -ResourceGroupName $resourceGroup -ErrorAction SilentlyContinue
if ($keyVault) {
    Write-Host "✔️ Key Vault '$keyVaultName' already exists. Skipping creation."
} else {
    Write-Host "Creating Key Vault '$keyVaultName' in Access Policy mode..."
    $keyVault = New-AzKeyVault -Name $keyVaultName `
        -ResourceGroupName $resourceGroup `
        -Location $location `
        -Sku Standard `
        -EnablePurgeProtection `
        -DisableRbacAuthorization `
        -SoftDeleteRetentionInDays 10 `
        -PublicNetworkAccess "Enabled"
}

# -----------------------
# CHECK OR CREATE KEY
# -----------------------
$key = Get-AzKeyVaultKey -VaultName $keyVaultName -Name $keyName -ErrorAction SilentlyContinue
if ($key) {
    Write-Host "✔️ Key '$keyName' already exists in Key Vault. Skipping creation."
} else {
    Write-Host "Creating key '$keyName' in Key Vault..."
    $key = Add-AzKeyVaultKey -VaultName $keyVaultName -Name $keyName -Destination 'Software'
}

# -----------------------
# CHECK OR CREATE MANAGED IDENTITY
# -----------------------
$identity = Get-AzUserAssignedIdentity -ResourceGroupName $resourceGroup -Name $identityName -ErrorAction SilentlyContinue
if ($identity) {
    Write-Host "✔️ Managed Identity '$identityName' already exists. Skipping creation."
} else {
    Write-Host "Creating managed identity '$identityName'..."
    $identity = New-AzUserAssignedIdentity -Name $identityName -ResourceGroupName $resourceGroup -Location $location
}

# -----------------------
# GRANT ACCESS POLICY TO MANAGED IDENTITY
# -----------------------
Write-Host "Granting Key Vault access policy to managed identity..."
Set-AzKeyVaultAccessPolicy -VaultName $keyVaultName `
    -ObjectId $identity.PrincipalId `
    -PermissionsToKeys get,wrapKey,unwrapKey

# -----------------------
# READ STORAGE ACCOUNTS FROM CSV AND CONFIGURE CMK
# -----------------------
$storageAccounts = Import-Csv -Path $csvPath
foreach ($sa in $storageAccounts) {
    $saName = $sa.StorageAccountName.Trim()
    $rg = $sa.ResourceGroup.Trim()
    $sub = $sa.SubscriptionId.Trim()

    Write-Host "`n🔄 Processing storage account: $saName (subscription: $sub)..."

    # Switch to storage subscription
    Select-AzSubscription -SubscriptionId $sub  -TenantId cd7bd4e0-1364-439d-8dc4-bc0ef1fb2bf5

    # Get storage account and verify it exists
    $storage = Get-AzStorageAccount -ResourceGroupName $rg -Name $saName -ErrorAction SilentlyContinue
    if (-not $storage) {
        Write-Warning "⚠️ Storage account '$saName' not found in resource group '$rg'. Skipping..."
        continue
    }

    # Assign user-assigned managed identity to storage account

    Write-Host " - Assigning user-assigned managed identity to storage account..."
    Set-AzStorageAccount -ResourceGroupName $rg -Name $saName `
        -IdentityType UserAssigned `
        -UserAssignedIdentityId $identity.Id

   # Configure storage account to use CMK encryption
    Write-Host " - Configuring storage account encryption with CMK..."
    Set-AzStorageAccount -ResourceGroupName $rg -Name $saName `
        -EncryptionKeySource Microsoft.Keyvault `
        -KeyName $keyName `
        -KeyVaultUri $keyVault.VaultUri `
        -KeyVersion $key.Key.kid.Split('/')[-1] `
        -IdentityType UserAssigned `
        -UserAssignedIdentityId $identity.Id

    Write-Host "✅ Storage account '$saName' updated."
}

Write-Host "`n✅ Script complete. Storage accounts updated with CMK and managed identity."