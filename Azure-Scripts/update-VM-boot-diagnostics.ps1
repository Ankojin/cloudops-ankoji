# Connect to Azure
#Connect-AzAccount

# Select your subscription (replace with your Subscription ID)
$SubscriptionId = "e48414cd-f96d-4414-ae9e-da7fec844f77"
Select-AzSubscription -SubscriptionId $SubscriptionId

# Set the desired storage account for boot diagnostics (replace with your Storage Account name and Resource Group)
$StorageAccountName = "babsitvmbootdiag02"
$StorageResourceGroup = "bab-sit-vm-boot-diag-swec-rg-01"
$StorageAccount = Get-AzStorageAccount -ResourceGroupName $StorageResourceGroup -Name $StorageAccountName
$StorageUri = $StorageAccount.PrimaryEndpoints.Blob

# Define the resource group to exclude (skip all VMs in ARO resource group)
$ExcludedResourceGroup = "aro-infra-lybja3b0-bab-sit-aro-01"

# Get all VMs in the subscription
$VMs = Get-AzVM

# Loop through all VMs and update boot diagnostics, even if different storage accounts are configured
foreach ($VM in $VMs) {
    # Skip all VMs in the ARO resource group (case-insensitive comparison)
    if ($VM.ResourceGroupName -eq $ExcludedResourceGroup) {
        Write-Output "Skipping ARO VM: $($VM.Name) in Resource Group: $($VM.ResourceGroupName)"
        continue
    }

    # Ensure BootDiagnostics object is initialized
    if (-not $VM.DiagnosticsProfile) {
        $VM.DiagnosticsProfile = New-Object Microsoft.Azure.Management.Compute.Models.DiagnosticsProfile
    }
    if (-not $VM.DiagnosticsProfile.BootDiagnostics) {
        $VM.DiagnosticsProfile.BootDiagnostics = New-Object Microsoft.Azure.Management.Compute.Models.BootDiagnostics
    }

    $CurrentDiagnostics = $VM.DiagnosticsProfile.BootDiagnostics

    # Check if boot diagnostics is enabled and using a different storage account
    if ($CurrentDiagnostics.Enabled -and $CurrentDiagnostics.StorageUri -ne $StorageUri) {
        Write-Output "Updating storage account for VM: $($VM.Name)"
        try {
            # Use Azure REST API to PATCH only the diagnosticsProfile
            $body = @{
                properties = @{
                    diagnosticsProfile = @{
                        bootDiagnostics = @{
                            enabled = $true
                            storageUri = $StorageUri
                        }
                    }
                }
            } | ConvertTo-Json -Depth 10
            
            $uri = "$($VM.Id)?api-version=2023-09-01"
            Invoke-AzRestMethod -Method PATCH -Path $uri -Payload $body | Out-Null
            Write-Output "Successfully updated VM: $($VM.Name)"
        }
        catch {
            Write-Warning "Failed to update VM $($VM.Name): $($_.Exception.Message)"
        }
    }
    elseif (-not $CurrentDiagnostics.Enabled) {
        Write-Output "Enabling boot diagnostics for VM: $($VM.Name)"
        try {
            # Use Azure REST API to PATCH only the diagnosticsProfile
            $body = @{
                properties = @{
                    diagnosticsProfile = @{
                        bootDiagnostics = @{
                            enabled = $true
                            storageUri = $StorageUri
                        }
                    }
                }
            } | ConvertTo-Json -Depth 10
            
            $uri = "$($VM.Id)?api-version=2023-09-01"
            Invoke-AzRestMethod -Method PATCH -Path $uri -Payload $body | Out-Null
            Write-Output "Successfully enabled for VM: $($VM.Name)"
        }
        catch {
            Write-Warning "Failed to enable for VM $($VM.Name): $($_.Exception.Message)"
        }
    }
    else {
        Write-Output "No changes needed for VM: $($VM.Name)"
    }
}