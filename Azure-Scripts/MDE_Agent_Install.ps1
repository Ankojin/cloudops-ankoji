
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId = "43cc4f11-ffb1-4a0d-8420-0ba3746b4248",
    [string[]]$ExcludedResourceGroups = @("aro-infra-lx29kz5c-bab-dev-aro-01"),
    [string]$ErrorLogPath = ".\MDEAgentInstallErrors.log"
)

# Standard logging function with levels (Info, Warning, Error, Success)
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info','Warning','Error','Success')]
        [string]$Level = 'Info'
    )
    $prefix = "[$Level]"
    Write-Output "$prefix $Message"
}

# Login to Azure if not already logged in

if (-not (Get-AzContext)) {
    Write-Log "Logging in to Azure..." 'Info'
    Connect-AzAccount
}

Set-AzContext -SubscriptionId $SubscriptionId

# Get all VMs in the subscription
$vms = Get-AzVM -Status

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
        Write-Log "Skipping VM in excluded resource group: $resourceGroupName" 'Warning'
        $skipped++
        continue
    }

    # Check if VM is running
    if ($vm.PowerState -ne "VM running") {
        Write-Log "Skipping VM not in running state: $vmName" 'Warning'
        $skipped++
        continue
    }

    $osType = $vm.StorageProfile.OSDisk.OSType
    $updatedThisVM = $false

    try {
        if ($osType -eq "Windows") {
            # Ensure MDE.Windows extension is installed
            $existingMDE = Get-AzVMExtension -ResourceGroupName $resourceGroupName -VMName $vmName -Name "MDE.Windows" -ErrorAction SilentlyContinue
            if (-not $existingMDE) {
                Write-Log "Installing MDE.Windows extension on VM: $vmName" 'Info'
                try {
                    Set-AzVMExtension -ResourceGroupName $resourceGroupName `
                                      -VMName $vmName `
                                      -Name "MDE.Windows" `
                                      -Publisher "Microsoft.Azure.AzureDefenderForServers" `
                                      -ExtensionType "MDE.Windows" `
                                      -TypeHandlerVersion "1.0" `
                                      -ErrorAction Stop
                    $updatedThisVM = $true
                }
                catch {
                    $errors++
                    $errorMsg = "Error installing MDE.Windows on VM $vmName in ${resourceGroupName}: $_"
                    Write-Log $errorMsg 'Error'
                    Add-Content -Path $ErrorLogPath -Value $errorMsg
                }
            } else {
                Write-Log "MDE.Windows extension already installed on VM: $vmName" 'Info'
            }
        }
        elseif ($osType -eq "Linux") {
            # Pre-check for Python on Linux VM
            $pythonCheck = Invoke-AzVMRunCommand -ResourceGroupName $resourceGroupName -VMName $vmName -CommandId 'RunShellScript' -ScriptString 'python3 --version || python --version' -ErrorAction SilentlyContinue
            $pythonFound = $false
            if ($pythonCheck.Value[0].Message -match 'Python') {
                $pythonFound = $true
            }
            if (-not $pythonFound) {
                Write-Log "Python not found on Linux VM: $vmName. Skipping MDE.Linux extension install." 'Warning'
                $skipped++
                continue
            }
            # Ensure MDE.Linux extension is installed
            $existingMDE = Get-AzVMExtension -ResourceGroupName $resourceGroupName -VMName $vmName -Name "MDE.Linux" -ErrorAction SilentlyContinue
            if (-not $existingMDE) {
                Write-Log "Installing MDE.Linux extension on VM: $vmName" 'Info'
                try {
                    Set-AzVMExtension -ResourceGroupName $resourceGroupName `
                                      -VMName $vmName `
                                      -Name "MDE.Linux" `
                                      -Publisher "Microsoft.Azure.AzureDefenderForServers" `
                                      -ExtensionType "MDE.Linux" `
                                      -TypeHandlerVersion "1.0" `
                                      -Settings @{} `
                                      -ErrorAction Stop
                    $updatedThisVM = $true
                }
                catch {
                    $errors++
                    $errorMsg = "Error installing MDE.Linux on VM $vmName in ${resourceGroupName}: $_"
                    Write-Log $errorMsg 'Error'
                    Add-Content -Path $ErrorLogPath -Value $errorMsg
                }
            } else {
                Write-Log "MDE.Linux extension already installed on VM: $vmName" 'Info'
            }
        }
        else {
            Write-Log "OS type not recognized for VM: $vmName" 'Warning'
            $skipped++
            continue
        }
        $processed++
        if ($updatedThisVM) { $updated++ }
    }
    catch {
        $errors++
        $errorMsg = "Error processing VM $vmName in ${resourceGroupName}: $_"
        Write-Log $errorMsg 'Error'
        Add-Content -Path $ErrorLogPath -Value $errorMsg
    }
}

Write-Log "---------------------------------------------" 'Info'
Write-Log "Summary for subscription: $SubscriptionId" 'Info'
Write-Log "Total VMs processed: $processed" 'Info'
Write-Log "Total VMs updated: $updated" 'Success'
Write-Log "Total VMs skipped: $skipped" 'Warning'
Write-Log "Total errors: $errors" 'Error'
if ($errors -gt 0) {
    Write-Log "See $ErrorLogPath for error details." 'Error'
}
Write-Log "MDE Agent installation script completed." 'Success'
