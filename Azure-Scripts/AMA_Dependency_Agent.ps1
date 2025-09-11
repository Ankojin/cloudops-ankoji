param(
    [string]$SubscriptionId = "43cc4f11-ffb1-4a0d-8420-0ba3746b4248",
    [string]$DcrName = "MSVMI-bab-dev-vm-monitoring-dcr",
    [string]$DcrResourceGroup = "bab-dev-wrkspace-swec-rg-01",
    [string[]]$ExcludedResourceGroups = @("aro-infra-lx29kz5c-bab-dev-aro-01"),
    [string]$ErrorLogPath = ".\AgentInstallErrors.log"
)

# Login to Azure if not already logged in
if (-not (Get-AzContext)) {
    Write-Output "Logging in to Azure..."
    Connect-AzAccount
}

Set-AzContext -SubscriptionId $SubscriptionId

# Get all VMs in the subscription
$vms = Get-AzVM -Status

# Get DCR info
$dcr = Get-AzDataCollectionRule -ResourceGroupName $DcrResourceGroup -Name $DcrName

# Summary counters
$processed = 0
$skipped = 0
$updated = 0
$errors = 0

# Clear previous error log
if (Test-Path $ErrorLogPath) { Remove-Item $ErrorLogPath }

foreach ($vm in $vms) {
    $vmName = $vm.Name
    $resourceGroupName = $vm.ResourceGroupName

    # Skip excluded resource groups
    if ($ExcludedResourceGroups -contains $resourceGroupName) {
        Write-Output "Skipping VM in excluded resource group: $resourceGroupName"
        $skipped++
        continue
    }

    # Check if VM is running
    if ($vm.PowerState -ne "VM running") {
        Write-Output "Skipping VM not in running state: $vmName"
        $skipped++
        continue
    }

    $osType = $vm.StorageProfile.OSDisk.OSType
    $settings = @{ "enableAMA" = $true }
    $updatedThisVM = $false

    try {
        if ($osType -eq "Windows") {
            # Ensure Azure Monitor Agent (AMA) is installed
            $existingAMA = Get-AzVMExtension -ResourceGroupName $resourceGroupName -VMName $vmName -Name "AzureMonitorWindowsAgent" -ErrorAction SilentlyContinue
            if (-not $existingAMA) {
                Write-Output "Installing Azure Monitor Windows Agent on VM: $vmName"
                Set-AzVMExtension -ResourceGroupName $resourceGroupName `
                                  -VMName $vmName `
                                  -Name "AzureMonitorWindowsAgent" `
                                  -Publisher "Microsoft.Azure.Monitor" `
                                  -ExtensionType "AzureMonitorWindowsAgent" `
                                  -TypeHandlerVersion "1.10"
                $updatedThisVM = $true
            } else {
                Write-Output "Azure Monitor Windows Agent already installed on VM: $vmName"
            }

            # Ensure Dependency Agent is installed
            $existingDA = Get-AzVMExtension -ResourceGroupName $resourceGroupName -VMName $vmName -Name "DependencyAgentWindows" -ErrorAction SilentlyContinue
            if (-not $existingDA) {
                Write-Output "Installing Dependency Agent (Windows) on VM: $vmName"
                Set-AzVMExtension -ResourceGroupName $resourceGroupName `
                                  -VMName $vmName `
                                  -Name "DependencyAgentWindows" `
                                  -Publisher "Microsoft.Azure.Monitoring.DependencyAgent" `
                                  -ExtensionType "DependencyAgentWindows" `
                                  -TypeHandlerVersion "9.10" `
                                  -Settings $settings
                $updatedThisVM = $true
            } else {
                Write-Output "Dependency Agent already installed on VM: $vmName"
            }

            # Associate VM with DCR if not already associated
            $existingAssoc = Get-AzDataCollectionRuleAssociation -TargetResourceId $vm.Id -ErrorAction SilentlyContinue | Where-Object { $_.RuleId -eq $dcr.Id }
            if (-not $existingAssoc) {
                Write-Output "Associating VM with DCR: $DcrName"
                New-AzDataCollectionRuleAssociation -TargetResourceId $vm.Id -RuleId $dcr.Id -AssociationName "${vmName}-DCRAssoc" -ErrorAction SilentlyContinue
                $updatedThisVM = $true
            } else {
                Write-Output "VM already associated with correct DCR: $vmName"
            }
        }
        elseif ($osType -eq "Linux") {
            # Ensure Azure Monitor Agent (AMA) is installed
            $existingAMA = Get-AzVMExtension -ResourceGroupName $resourceGroupName -VMName $vmName -Name "AzureMonitorLinuxAgent" -ErrorAction SilentlyContinue
            if (-not $existingAMA) {
                Write-Output "Installing Azure Monitor Linux Agent on VM: $vmName"
                Set-AzVMExtension -ResourceGroupName $resourceGroupName `
                                  -VMName $vmName `
                                  -Name "AzureMonitorLinuxAgent" `
                                  -Publisher "Microsoft.Azure.Monitor" `
                                  -ExtensionType "AzureMonitorLinuxAgent" `
                                  -TypeHandlerVersion "1.10"
                $updatedThisVM = $true
            } else {
                Write-Output "Azure Monitor Linux Agent already installed on VM: $vmName"
            }

            # Ensure Dependency Agent is installed
            $existingDA = Get-AzVMExtension -ResourceGroupName $resourceGroupName -VMName $vmName -Name "DependencyAgentLinux" -ErrorAction SilentlyContinue
            if (-not $existingDA) {
                Write-Output "Installing Dependency Agent (Linux) on VM: $vmName"
                Set-AzVMExtension -ResourceGroupName $resourceGroupName `
                                  -VMName $vmName `
                                  -Name "DependencyAgentLinux" `
                                  -Publisher "Microsoft.Azure.Monitoring.DependencyAgent" `
                                  -ExtensionType "DependencyAgentLinux" `
                                  -TypeHandlerVersion "9.10" `
                                  -Settings $settings
                $updatedThisVM = $true
            } else {
                Write-Output "Dependency Agent already installed on VM: $vmName"
            }

            # Associate VM with DCR if not already associated
            $existingAssoc = Get-AzDataCollectionRuleAssociation -TargetResourceId $vm.Id -ErrorAction SilentlyContinue | Where-Object { $_.RuleId -eq $dcr.Id }
            if (-not $existingAssoc) {
                Write-Output "Associating VM with DCR: $DcrName"
                New-AzDataCollectionRuleAssociation -TargetResourceId $vm.Id -RuleId $dcr.Id -AssociationName "${vmName}-DCRAssoc" -ErrorAction SilentlyContinue
                $updatedThisVM = $true
            } else {
                Write-Output "VM already associated with correct DCR: $vmName"
            }
        }
        else {
            Write-Output "OS type not recognized for VM: $vmName"
            $skipped++
            continue
        }
        $processed++
        if ($updatedThisVM) { $updated++ }
    }
    catch {
        $errors++
        $errorMsg = "Error processing VM $vmName in ${resourceGroupName}: $_"
        Write-Output $errorMsg
        Add-Content -Path $ErrorLogPath -Value $errorMsg
    }
}

Write-Output "---------------------------------------------"
Write-Output "Summary for subscription: $SubscriptionId"
Write-Output "Total VMs processed: $processed"
Write-Output "Total VMs updated: $updated"
Write-Output "Total VMs skipped: $skipped"
Write-Output "Total errors: $errors"
if ($errors -gt 0) {
    Write-Output "See $ErrorLogPath for error details."
}
Write-Output "Dependency Agent, AMA, and DCR association script completed."
