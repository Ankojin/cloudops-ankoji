# Connect to Azure
Connect-AzAccount

# Select your subscription (replace with your Subscription ID)
$SubscriptionId = "43cc4f11-ffb1-4a0d-8420-0ba3746b4248"
Select-AzSubscription -SubscriptionId $SubscriptionId

# Set the desired storage account for boot diagnostics (replace with your Storage Account name and Resource Group)
$StorageAccountName = "babdevvmbootdiag02"
$StorageResourceGroup = "bab-dev-vm-boot-diag-swec-rg-01"
$StorageAccount = Get-AzStorageAccount -ResourceGroupName $StorageResourceGroup -Name $StorageAccountName
$StorageUri = $StorageAccount.PrimaryEndpoints.Blob

# Define the resource group and VMs to exclude
$ExcludedResourceGroup = "aro-infra-lx29kz5c-bab-dev-aro-01"
$ExcludedVMs = @("bab-dev-aro-01-zm4qv-master-1", "bab-dev-aro-01-zm4qv-master-0", "bab-dev-aro-01-zm4qv-master-2", "bab-dev-aro-01-zm4qv-worker-swedencentral1-q2jck", "bab-dev-aro-01-zm4qv-worker-swedencentral2-49j6r", "bab-dev-aro-01-zm4qv-worker-swedencentral3-fxh7g", "bab-dev-aro-01-zm4qv-worker-swedencentral4-kgvll", "bab-dev-aro-01-zm4qv-worker-swedencentral5-54rpk")

# Get all VMs in the subscription
$VMs = Get-AzVM

# Loop through all VMs and update boot diagnostics, even if different storage accounts are configured
foreach ($VM in $VMs) {
    # Skip excluded VMs in the specified resource group
    if ($VM.ResourceGroupName -eq $ExcludedResourceGroup -and $ExcludedVMs -contains $VM.Name) {
        Write-Output "Skipping VM: $($VM.Name) in Resource Group: $ExcludedResourceGroup"
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
        $VM.DiagnosticsProfile.BootDiagnostics.StorageUri = $StorageUri
        Update-AzVM -ResourceGroupName $VM.ResourceGroupName -VM $VM
    }
    elseif (-not $CurrentDiagnostics.Enabled) {
        Write-Output "Enabling boot diagnostics for VM: $($VM.Name)"
        $VM.DiagnosticsProfile.BootDiagnostics.Enabled = $true
        $VM.DiagnosticsProfile.BootDiagnostics.StorageUri = $StorageUri
        Update-AzVM -ResourceGroupName $VM.ResourceGroupName -VM $VM
    }
    else {
        Write-Output "No changes needed for VM: $($VM.Name)"
    }
}