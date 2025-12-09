param(
    [Parameter(Mandatory = $true)]
    [string[]]$SubscriptionIds
)

Write-Host "`n=== Azure VM Guest Agent + MDE Extension Verification Tool ===" -ForegroundColor Cyan

Connect-AzAccount -ErrorAction Stop | Out-Null

$results = @()

foreach ($sub in $SubscriptionIds) {

    Write-Host "`n--- Subscription: $sub ---" -ForegroundColor Yellow
    Set-AzContext -SubscriptionId $sub -ErrorAction Stop | Out-Null

    # Get all VMs including status and Guest Agent info
    $vms = Get-AzVM -Status -ErrorAction SilentlyContinue

    foreach ($vm in $vms) {

        $vmName = $vm.Name
        $rg     = $vm.ResourceGroupName
        $osType = $vm.StorageProfile.OSDisk.OSType

        # --------------------------------------
        # 1. Skip deallocated VMs
        # --------------------------------------
        $powerState = ($vm.Statuses | Where-Object { $_.Code -like "PowerState*" }).DisplayStatus

        if ($powerState -eq "VM deallocated" -or $powerState -eq "VM stopped") {

            Write-Host "[$vmName] Skipping — VM is deallocated." -ForegroundColor DarkYellow

            $results += [PSCustomObject]@{
                SubscriptionId    = $sub
                VMName            = $vmName
                ResourceGroup     = $rg
                OS                = $osType
                GuestAgentState   = "Skipped (Deallocated)"
                GuestAgentVersion = "N/A"
                MDE_Extension     = "Skipped"
                ProvisioningState = "N/A"
                Result            = "Skipped"
            }

            continue
        }

        # --------------------------------------
        # 2. Check Guest Agent Status
        # --------------------------------------
        $agent = (Get-AzVM -ResourceGroupName $rg -Name $vmName -Status).VMAgent

        if ($null -eq $agent -or $agent.VmAgentVersion -eq $null) {

            Write-Host "[$vmName] Guest Agent NOT READY." -ForegroundColor Red

            $results += [PSCustomObject]@{
                SubscriptionId    = $sub
                VMName            = $vmName
                ResourceGroup     = $rg
                OS                = $osType
                GuestAgentState   = "GuestAgentMissing"
                GuestAgentVersion = "N/A"
                MDE_Extension     = "Skipped"
                ProvisioningState = "N/A"
                Result            = "Skipped (GuestAgentNotReady)"
            }

            continue
        }

        # Guest Agent READY
        $gaStatus = $agent.Statuses | Select-Object -ExpandProperty DisplayStatus -ErrorAction SilentlyContinue
        $guestAgentState = if ($gaStatus -match "Ready") { "Ready" } else { "NotReady" }

        # --------------------------------------
        # 3. Check MDE Extension installation
        # --------------------------------------
        $extensions = Get-AzVMExtension -ResourceGroupName $rg -VMName $vmName -ErrorAction SilentlyContinue

        $mde = $extensions | Where-Object {
            $_.ExtensionType -eq "MDE.Windows" -or
            $_.ExtensionType -eq "MDE.Linux"
        }

        if ($null -eq $mde) {
            $extPresent = "Not Installed"
            $provState  = "N/A"
        }
        else {
            $extPresent = $mde.ExtensionType
            $provState  = $mde.ProvisioningState
        }

        # --------------------------------------
        # Save results
        # --------------------------------------
        $results += [PSCustomObject]@{
            SubscriptionId    = $sub
            VMName            = $vmName
            ResourceGroup     = $rg
            OS                = $osType
            GuestAgentState   = $guestAgentState
            GuestAgentVersion = $agent.VmAgentVersion
            MDE_Extension     = $extPresent
            ProvisioningState = $provState
            Result            = "Checked"
        }
    }
}

# Export CSV
$outFile = "MDE-GuestAgent-Status-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
$results | Export-Csv $outFile -NoTypeInformation

Write-Host "`nVerification Complete! CSV saved to: $outFile" -ForegroundColor Green

$results | Format-Table -AutoSize