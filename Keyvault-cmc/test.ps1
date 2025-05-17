# -----------------------
# CONFIGURATION
# -----------------------
$location = "westeurope"
$centralSubscriptionId = "6ba165ee-ec4d-4003-ac84-f0e"
$resourceGroup = "sandbox-nw-rg01"
$keyVaultName = "kv-cmk-ankoji-tests-01"
$keyName = "cmk-key"
$identityName = "id-cmk-storage"
$csvPath = Join-Path -Path $PSScriptRoot -ChildPath "strgacct.csv"

# -----------------------
# CONNECT AND SELECT CENTRAL SUBSCRIPTION
# -----------------------
# Connect-AzAccount # Uncomment if not logged in
Select-AzSubscription -SubscriptionId $centralSubscriptionId

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
# GRANT ACCESS POLICY TO MANAGED IDENTITY ON KEYVAULT
# -----------------------
Write-Host "Granting Key Vault access policy to managed identity..."
Set-AzKeyVaultAccessPolicy -VaultName $keyVaultName `
    -ObjectId $identity.PrincipalId `
    -PermissionsToKeys get,wrapKey,unwrapKey

# -----------------------
# READ STORAGE ACCOUNTS FROM CSV AND CONFIGURE CMK
# CSV FORMAT:
# StorageAccountName,ResourceGroup,SubscriptionId
# mystorage01,my-rg-01,xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
# -----------------------
if (-Not (Test-Path $csvPath)) {
    Write-Error "CSV file not found at path: $csvPath"
    exit 1
}

$storageAccounts = Import-Csv -Path $csvPath
foreach ($sa in $storageAccounts) {
    $saName = $sa.StorageAccountName.Trim()
    $rg = $sa.ResourceGroup.Trim()
    $sub = $sa.SubscriptionId.Trim()

    Write-Host "`n🔄 Processing storage account: $saName (subscription: $sub)..."

    # Switch to storage subscription
    Select-AzSubscription -SubscriptionId $sub

    # Get storage account and verify it exists
    $storage = Get-AzStorageAccount -ResourceGroupName $rg -Name $saName -ErrorAction SilentlyContinue
    if (-not $storage) {
        Write-Warning "⚠️ Storage account '$saName' not found in resource group '$rg'. Skipping..."
        continue
    }

    # Assign user-assigned managed identity to storage account
    Write-Host " - Assigning user-assigned managed identity..."
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

Write-Host "`n🎉 Script complete. All storage accounts processed."