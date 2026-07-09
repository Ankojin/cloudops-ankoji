param(
    [string]$SubscriptionId         = "43cc4f11-ffb1-4a0d-8420-0ba3746b4248",
    [string]$DcrName                = "MSVMI-bab-dev-vm-monitoring-dcr",
    [string]$DcrResourceGroup       = "bab-dev-wrkspace-swec-rg-01",
    [string[]]$ExcludedResourceGroups = @("aro-infra-lx29kz5c-bab-dev-aro-01"),
    [string]$ErrorLogPath           = ".\AgentInstallErrors-devlog"
)

# RHEL SKU patterns where Dependency Agent is NOT supported.
# Covers: RHEL 9.2 (Plow), RHEL 9.8 (Plow) and any other RHEL 9.x variant.
$UnsupportedDepAgentSkuPatterns = @("9_2", "9.2", "9_8", "9.8")

# Returns $true when the VM is a RedHat publisher image with an RHEL 9.x SKU.
function Test-IsUnsupportedDepAgentLinux {
    param([object]$Vm)
    $ref = $Vm.StorageProfile.ImageReference
    if (-not $ref) { return $false }
    if ($ref.Publisher -ine "RedHat") { return $false }
    foreach ($pattern in $UnsupportedDepAgentSkuPatterns) {
        if ($ref.Sku -like "*$pattern*") { return $true }
    }
    # Catch any other RHEL 9.x SKU not in the explicit list (9-lvm, 9-gen2, etc.)
    if ($ref.Sku -match "^9[\._\-]|^9$") { return $true }
    return $false
}

# Thin wrapper so both OS branches call the same cmdlet the same way.
function Install-AgentExtension {
    param(
        [string]$ResourceGroupName,
        [string]$VMName,
        [string]$Name,
        [string]$Publisher,
        [string]$ExtensionType,
        [string]$TypeHandlerVersion,
        [hashtable]$Settings = $null
    )
    $params = @{
        ResourceGroupName  = $ResourceGroupName
        VMName             = $VMName
        Name               = $Name
        Publisher          = $Publisher
        ExtensionType      = $ExtensionType
        TypeHandlerVersion = $TypeHandlerVersion
    }
    if ($Settings) { $params["Settings"] = $Settings }
    Set-AzVMExtension @params
}

# Login to Azure if not already logged in
if (-not (Get-AzContext)) {
    Write-Output "Logging in to Azure..."
    #Connect-AzAccount
}

Set-AzContext -SubscriptionId $SubscriptionId

$vms = Get-AzVM -Status
$dcr = Get-AzDataCollectionRule -ResourceGroupName $DcrResourceGroup -Name $DcrName

$processed = 0
$skipped   = 0
$updated   = 0
$errors    = 0

if (Test-Path $ErrorLogPath) { Remove-Item $ErrorLogPath }

foreach ($vm in $vms) {
    $vmName            = $vm.Name
    $resourceGroupName = $vm.ResourceGroupName

    if ($ExcludedResourceGroups -contains $resourceGroupName) {
        Write-Output "[$vmName] Skipping — excluded resource group: $resourceGroupName"
        $skipped++
        continue
    }

    if ($vm.PowerState -ne "VM running") {
        Write-Output "[$vmName] Skipping — VM is not running (state: $($vm.PowerState))"
        $skipped++
        continue
    }

    $osType        = $vm.StorageProfile.OSDisk.OSType
    $daSettings    = @{ "enableAMA" = $true }
    $updatedThisVM = $false

    try {
        # ── Windows ────────────────────────────────────────────────────────────
        if ($osType -eq "Windows") {
            $amaName = "AzureMonitorWindowsAgent"
            $daName  = "DependencyAgentWindows"
            $amaPub  = "Microsoft.Azure.Monitor"
            $daPub   = "Microsoft.Azure.Monitoring.DependencyAgent"

            $existingAMA = Get-AzVMExtension -ResourceGroupName $resourceGroupName -VMName $vmName -Name $amaName -ErrorAction SilentlyContinue
            $existingDA  = Get-AzVMExtension -ResourceGroupName $resourceGroupName -VMName $vmName -Name $daName  -ErrorAction SilentlyContinue

            $amaFailed = $existingAMA -and ($existingAMA.ProvisioningState -eq "Failed")
            $daFailed  = $existingDA  -and ($existingDA.ProvisioningState  -eq "Failed")

            if ($amaFailed -or $daFailed) {
                # Failed extension — uninstall both then reinstall both
                Write-Output "[$vmName] Failed extension detected (AMA=$amaFailed, DA=$daFailed) — reinstalling both agents"
                if ($existingAMA) {
                    Write-Output "[$vmName]   Uninstalling $amaName (state: $($existingAMA.ProvisioningState))"
                    Remove-AzVMExtension -ResourceGroupName $resourceGroupName -VMName $vmName -Name $amaName -Force
                }
                if ($existingDA) {
                    Write-Output "[$vmName]   Uninstalling $daName (state: $($existingDA.ProvisioningState))"
                    Remove-AzVMExtension -ResourceGroupName $resourceGroupName -VMName $vmName -Name $daName -Force
                }
                Write-Output "[$vmName]   Installing $amaName"
                Install-AgentExtension -ResourceGroupName $resourceGroupName -VMName $vmName `
                    -Name $amaName -Publisher $amaPub -ExtensionType $amaName -TypeHandlerVersion "1.10"
                Write-Output "[$vmName]   Installing $daName"
                Install-AgentExtension -ResourceGroupName $resourceGroupName -VMName $vmName `
                    -Name $daName -Publisher $daPub -ExtensionType $daName -TypeHandlerVersion "9.10" -Settings $daSettings
                $updatedThisVM = $true
            }
            else {
                # AMA
                if (-not $existingAMA) {
                    Write-Output "[$vmName] Installing $amaName"
                    Install-AgentExtension -ResourceGroupName $resourceGroupName -VMName $vmName `
                        -Name $amaName -Publisher $amaPub -ExtensionType $amaName -TypeHandlerVersion "1.10"
                    $updatedThisVM = $true
                }
                else {
                    Write-Output "[$vmName] $amaName already installed (state: $($existingAMA.ProvisioningState)) — skipping"
                }

                # Dependency Agent
                if (-not $existingDA) {
                    Write-Output "[$vmName] Installing $daName"
                    Install-AgentExtension -ResourceGroupName $resourceGroupName -VMName $vmName `
                        -Name $daName -Publisher $daPub -ExtensionType $daName -TypeHandlerVersion "9.10" -Settings $daSettings
                    $updatedThisVM = $true
                }
                else {
                    Write-Output "[$vmName] $daName already installed (state: $($existingDA.ProvisioningState)) — skipping"
                }
            }
        }
        # ── Linux ──────────────────────────────────────────────────────────────
        elseif ($osType -eq "Linux") {
            $amaName = "AzureMonitorLinuxAgent"
            $daName  = "DependencyAgentLinux"
            $amaPub  = "Microsoft.Azure.Monitor"
            $daPub   = "Microsoft.Azure.Monitoring.DependencyAgent"

            # Detect unsupported distro (RHEL 9.2 / 9.8 / any 9.x)
            $isUnsupportedDA = Test-IsUnsupportedDepAgentLinux -Vm $vm
            if ($isUnsupportedDA) {
                $imgSku = $vm.StorageProfile.ImageReference.Sku
                Write-Output "[$vmName] Unsupported distro for Dependency Agent (Publisher=RedHat, SKU=$imgSku) — DA will be skipped"
            }

            $existingAMA = Get-AzVMExtension -ResourceGroupName $resourceGroupName -VMName $vmName -Name $amaName -ErrorAction SilentlyContinue

            # Only query DA extension if the distro is supported
            if ($isUnsupportedDA) {
                $existingDA = $null
            }
            else {
                $existingDA = Get-AzVMExtension -ResourceGroupName $resourceGroupName -VMName $vmName -Name $daName -ErrorAction SilentlyContinue
            }

            $amaFailed = $existingAMA -and ($existingAMA.ProvisioningState -eq "Failed")
            $daFailed  = $existingDA  -and ($existingDA.ProvisioningState  -eq "Failed")

            if ($amaFailed -or $daFailed) {
                # Failed extension — uninstall then reinstall (DA only if supported)
                Write-Output "[$vmName] Failed extension detected (AMA=$amaFailed, DA=$daFailed) — reinstalling agents"
                if ($existingAMA) {
                    Write-Output "[$vmName]   Uninstalling $amaName (state: $($existingAMA.ProvisioningState))"
                    Remove-AzVMExtension -ResourceGroupName $resourceGroupName -VMName $vmName -Name $amaName -Force
                }
                if ($existingDA) {
                    Write-Output "[$vmName]   Uninstalling $daName (state: $($existingDA.ProvisioningState))"
                    Remove-AzVMExtension -ResourceGroupName $resourceGroupName -VMName $vmName -Name $daName -Force
                }
                Write-Output "[$vmName]   Installing $amaName"
                Install-AgentExtension -ResourceGroupName $resourceGroupName -VMName $vmName `
                    -Name $amaName -Publisher $amaPub -ExtensionType $amaName -TypeHandlerVersion "1.10"
                if (-not $isUnsupportedDA) {
                    Write-Output "[$vmName]   Installing $daName"
                    Install-AgentExtension -ResourceGroupName $resourceGroupName -VMName $vmName `
                        -Name $daName -Publisher $daPub -ExtensionType $daName -TypeHandlerVersion "9.10" -Settings $daSettings
                }
                $updatedThisVM = $true
            }
            else {
                # AMA
                if (-not $existingAMA) {
                    Write-Output "[$vmName] Installing $amaName"
                    Install-AgentExtension -ResourceGroupName $resourceGroupName -VMName $vmName `
                        -Name $amaName -Publisher $amaPub -ExtensionType $amaName -TypeHandlerVersion "1.10"
                    $updatedThisVM = $true
                }
                else {
                    Write-Output "[$vmName] $amaName already installed (state: $($existingAMA.ProvisioningState)) — skipping"
                }

                # Dependency Agent
                if ($isUnsupportedDA) {
                    Write-Output "[$vmName] Skipping $daName — RHEL 9.x is not supported"
                }
                elseif (-not $existingDA) {
                    Write-Output "[$vmName] Installing $daName"
                    Install-AgentExtension -ResourceGroupName $resourceGroupName -VMName $vmName `
                        -Name $daName -Publisher $daPub -ExtensionType $daName -TypeHandlerVersion "9.10" -Settings $daSettings
                    $updatedThisVM = $true
                }
                else {
                    Write-Output "[$vmName] $daName already installed (state: $($existingDA.ProvisioningState)) — skipping"
                }
            }
        }
        # ── Unknown OS ─────────────────────────────────────────────────────────
        else {
            Write-Output "[$vmName] OS type not recognized ($osType) — skipping"
            $skipped++
            continue
        }

        # ── DCR Association ────────────────────────────────────────────────────
        $existingAssoc = Get-AzDataCollectionRuleAssociation -TargetResourceId $vm.Id -ErrorAction SilentlyContinue |
                         Where-Object { $_.RuleId -eq $dcr.Id }
        if (-not $existingAssoc) {
            Write-Output "[$vmName] Associating with DCR: $DcrName"
            New-AzDataCollectionRuleAssociation -TargetResourceId $vm.Id -RuleId $dcr.Id `
                -AssociationName "${vmName}-DCRAssoc" -ErrorAction SilentlyContinue
            $updatedThisVM = $true
        }
        else {
            Write-Output "[$vmName] Already associated with DCR: $DcrName — skipping"
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
Write-Output "Total VMs updated:   $updated"
Write-Output "Total VMs skipped:   $skipped"
Write-Output "Total errors:        $errors"
if ($errors -gt 0) {
    Write-Output "See $ErrorLogPath for error details."
}
Write-Output "Dependency Agent, AMA, and DCR association script completed."
