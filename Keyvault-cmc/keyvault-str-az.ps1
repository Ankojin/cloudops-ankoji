# -----------------------
# CONFIGURATION
# -----------------------
$location = "westeurope"
$centralSubscriptionId = "6ba165ee-ec4d-4003-ac84-f4211cd84f0e"
$resourceGroup = "sandbox-nw-rg01"
$keyVaultName = "kv-cmk-ankoji-tests-02"
$keyName = "cmk-key"
$identityName = "id-cmk-storage"
$csvPath = "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\Keyvault-cmc\strgacct.csv"
$tenantId = "cd7bd4e0-1364-439d-8dc4-bc0ef1fb2bf5"


# -----------------------
# LOGIN & SELECT CENTRAL SUBSCRIPTION
# -----------------------
Write-Host "Logging in to Azure CLI..."
az login --tenant $tenantId | Out-Null
az account set --subscription $centralSubscriptionId --tenant $tenantId

# -----------------------
# VERIFY RESOURCE GROUP EXISTS
# -----------------------
$rgCheck = az group show --name $resourceGroup --output json 2>$null | ConvertFrom-Json
if (-not $rgCheck) {
    Write-Error "Resource Group '$resourceGroup' not found in subscription $centralSubscriptionId. Please check the RG name and subscription."
    exit 1
}

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
# CSV expected columns: StorageAccountName,ResourceGroup,SubscriptionId
# -----------------------
$storageAccounts = Import-Csv -Path $csvPath
foreach ($sa in $storageAccounts) {
    $saName = $sa.StorageAccountName.Trim()
    $rg = $sa.ResourceGroup.Trim()
    $sub = $sa.SubscriptionId.Trim()

    Write-Host "`n🔄 Processing storage account: $saName (Subscription: $sub)..."

    # Switch subscription
    az account set --subscription $sub

    # Check if storage account exists
    $storageExists = az storage account show --name $saName --resource-group $rg --query "name" -o tsv 2>$null
    if (-not $storageExists) {
        Write-Warning "⚠️ Storage account '$saName' not found in resource group '$rg'. Skipping..."
        continue
    }

    # Assign managed identity
    Write-Host " - Assigning user-assigned managed identity..."
    az storage account update `
        --name $saName `
        --resource-group $rg `
        --identity-type UserAssigned `
        --user-identity-id $identity.Id `
        | Out-Null

    # # Get Key Vault URI
    # $keyVaultUri = $keyVault.vaultUri
    
    # Update encryption settings with CMK
    Write-Host " - Updating encryption to use CMK..."
    az storage account update `
        --name $saName `
        --resource-group $rg `
        --encryption-key-vault $keyVault.vaultUri `
        --encryption-key-name $keyName `
        --encryption-key-source Microsoft.Keyvault `
        --key-vault-user-identity-id $identity.Id `
        --identity-type UserAssigned `
        --user-identity-id $identity.Id `
        | Out-Null

    Write-Host "✅ Updated storage account '$saName'."
}

Write-Host "`n🎉 All storage accounts processed successfully."