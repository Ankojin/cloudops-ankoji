# -----------------------
# CONFIGURATION
# -----------------------
$location = "westeurope"
$centralSubscriptionId = ""
$resourceGroup = ""
$keyVaultName = ""
$keyName = ""
$identityName = ""
$csvPath = "./strgacct.csv"
$tenantId = ""
$logPath = "$(Split-Path -Parent $csvPath)\cmk-encryption-log.txt"
$reportPath = "$(Split-Path -Parent $csvPath)\cmk-encryption-report.csv"

# -----------------------
# INIT LOGGING
# -----------------------
"$(Get-Date -Format o) - Script started." | Out-File -FilePath $logPath -Append
$report = @()

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
    Write-Error "Resource Group '$resourceGroup' not found in subscription $centralSubscriptionId."
    "$(Get-Date -Format o) - ERROR: Resource Group '$resourceGroup' not found." | Out-File -FilePath $logPath -Append
    exit 1
}

# -----------------------
# CHECK OR CREATE KEY VAULT (Access Policy Mode)
# -----------------------
$keyVault = Get-AzKeyVault -VaultName $keyVaultName -ResourceGroupName $resourceGroup -ErrorAction SilentlyContinue
if ($keyVault) {
    Write-Host "✔️ Key Vault '$keyVaultName' already exists. Skipping creation."
} else {
    Write-Host "Creating Key Vault '$keyVaultName'..."
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
    Write-Host "✔️ Key '$keyName' already exists. Skipping creation."
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
# PROCESS STORAGE ACCOUNTS
# -----------------------
$storageAccounts = Import-Csv -Path $csvPath
foreach ($sa in $storageAccounts) {
    $saName = $sa.StorageAccountName.Trim()
    $rg = $sa.ResourceGroup.Trim()
    $sub = $sa.SubscriptionId.Trim()

    Write-Host "`n🔄 Processing storage account: $saName (Subscription: $sub)..."
    "$(Get-Date -Format o) - Processing: $saName in $rg ($sub)" | Out-File -FilePath $logPath -Append

    try {
        az account set --subscription $sub

        $storageExists = az storage account show --name $saName --resource-group $rg --query "name" -o tsv 2>$null
        if (-not $storageExists) {
            throw "Storage account not found."
        }

        Write-Host " - Assigning user-assigned managed identity..."
        az storage account update `
            --name $saName `
            --resource-group $rg `
            --identity-type UserAssigned `
            --user-identity-id $identity.Id `
            | Out-Null

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
        "$(Get-Date -Format o) - SUCCESS: $saName updated." | Out-File -FilePath $logPath -Append
        $report += [PSCustomObject]@{
            StorageAccount = $saName
            ResourceGroup = $rg
            SubscriptionId = $sub
            Status = "Success"
            Message = "Updated with CMK"
        }
    }
    catch {
        Write-Warning "❌ Failed to update storage account '$saName': $_"
        "$(Get-Date -Format o) - ERROR: $saName failed - $_" | Out-File -FilePath $logPath -Append
        $report += [PSCustomObject]@{
            StorageAccount = $saName
            ResourceGroup = $rg
            SubscriptionId = $sub
            Status = "Failed"
            Message = $_.ToString()
        }
    }
}

# -----------------------
# WRITE REPORT
# -----------------------
$report | Export-Csv -Path $reportPath -NoTypeInformation
Write-Host "`n📄 Report saved to: $reportPath"
Write-Host "🎉 All storage accounts processed. Check log and report for details."
"$(Get-Date -Format o) - Script completed." | Out-File -FilePath $logPath -Append