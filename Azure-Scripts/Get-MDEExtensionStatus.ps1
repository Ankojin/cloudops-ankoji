param(
    [Parameter(Mandatory = $true)]
    [string[]]$SubscriptionIds
)

Write-Host "`n=== Azure VM Guest Agent + MDE Extension Verification Tool ===" -ForegroundColor Cyan

#Connect-AzAccount -ErrorAction Stop | Out-Null

$results = @()

foreach ($sub in $SubscriptionIds) {

    Write-Host "`n--- Subscription: $sub ---" -ForegroundColor Yellow
    Set-AzContext -SubscriptionId $sub -ErrorAction Stop | Out-Null

    # Get VM list INCLUDING statuses
    $vms = Get-AzVM -Status -ErrorAction SilentlyContinue

    foreach ($vm in $vms) {

        $vmName = $vm.Name
        $rg     = $vm.ResourceGroupName
        $osType = $vm.StorageProfile.OSDisk.OSType

        # -----------------------------
        # GET POWER STATE (from instance view)
        # -----------------------------
        $powerStateObj = $instance.Statuses | Where-Object { $_.Code -like "PowerState*" }
        $powerState = if ($powerStateObj) { $powerStateObj.DisplayStatus } else { "Unknown" }

            # -----------------------------
            # CHECK IF VM IS STOPPED OR DEALLOCATED
            # -----------------------------
            $isStoppedOrDeallocated = $false
            if ($powerState -eq "VM stopped" -or $powerState -eq "VM deallocated") {
                $isStoppedOrDeallocated = $true
            }

        # -----------------------------
        # GET GUEST AGENT STATUS (Correct)
        # Must be pulled from INSTANCE VIEW ONLY
        # -----------------------------
        $instance = Get-AzVM -ResourceGroupName $rg -Name $vmName -Status -ErrorAction SilentlyContinue
        
        $agent = $instance.VMAgent
        $guestAgentState = "Missing"
        $guestAgentVersion = "N/A"

        if ($agent) {
            $gaDisplay = ($agent.Statuses | Select-Object -ExpandProperty DisplayStatus -ErrorAction SilentlyContinue)

            if ($gaDisplay -match "Ready") {
                $guestAgentState = "Ready"
            } else {
                $guestAgentState = $gaDisplay
            }

            $guestAgentVersion = $agent.VmAgentVersion
        }

        # -----------------------------
        # GET MDE EXTENSION STATUS (Correct)
        # -----------------------------
        $extensions = Get-AzVMExtension -ResourceGroupName $rg -VMName $vmName -ErrorAction SilentlyContinue

        $mde = $extensions | Where-Object {
            $_.ExtensionType -eq "MDE.Windows" -or
            $_.ExtensionType -eq "MDE.Linux"
        }

        if ($mde) {
            $mdeExt = $mde.ExtensionType
            $mdeState = $mde.ProvisioningState
        } else {
            $mdeExt = "Not Installed"
            $mdeState = "N/A"
        }
        $vmName = $vm.Name
        $rg     = $vm.ResourceGroupName
        $osType = $vm.StorageProfile.OSDisk.OSType

        # -----------------------------
        # GET INSTANCE VIEW
        # -----------------------------
        $instance = Get-AzVM -ResourceGroupName $rg -Name $vmName -Status -ErrorAction SilentlyContinue

        # -----------------------------
        # GET POWER STATE (from instance view)
        # -----------------------------
        $powerStateObj = $instance.Statuses | Where-Object { $_.Code -like "PowerState*" }
        $powerState = if ($powerStateObj) { $powerStateObj.DisplayStatus } else { "Unknown" }

        # -----------------------------
        # CHECK IF VM IS STOPPED OR DEALLOCATED
        # -----------------------------
        $isStoppedOrDeallocated = $false
        if ($powerState -eq "VM stopped" -or $powerState -eq "VM deallocated") {
            $isStoppedOrDeallocated = $true
        }

        # -----------------------------
        # GET GUEST AGENT STATUS (Correct)
        # Must be pulled from INSTANCE VIEW ONLY
        # -----------------------------
        $agent = $instance.VMAgent
        $guestAgentState = "Missing"
        $guestAgentVersion = "N/A"

        if ($agent) {
            $gaDisplay = ($agent.Statuses | Select-Object -ExpandProperty DisplayStatus -ErrorAction SilentlyContinue)

            if ($gaDisplay -match "Ready") {
                $guestAgentState = "Ready"
            } else {
                $guestAgentState = $gaDisplay
            }

            $guestAgentVersion = $agent.VmAgentVersion
        }

        # -----------------------------
        # GET MDE EXTENSION STATUS (Correct)
        # -----------------------------
        $extensions = Get-AzVMExtension -ResourceGroupName $rg -VMName $vmName -ErrorAction SilentlyContinue

        $mde = $extensions | Where-Object {
            $_.ExtensionType -eq "MDE.Windows" -or
            $_.ExtensionType -eq "MDE.Linux"
        }

        if ($mde) {
            $mdeExt = $mde.ExtensionType
            $mdeState = $mde.ProvisioningState
        } else {
            $mdeExt = "Not Installed"
            $mdeState = "N/A"
        }

        # -----------------------------
        # SAVE RESULTS (NO SKIPPING)
        # -----------------------------
        $results += [PSCustomObject]@{
            VMName            = $vmName
            ResourceGroup     = $rg
            OS                = $osType
            PowerState        = $powerState
            StoppedOrDeallocated = $isStoppedOrDeallocated
            GuestAgentState   = $guestAgentState
            GuestAgentVersion = $guestAgentVersion
            MDE_Extension     = $mdeExt
            MDE_State         = $mdeState
            Result            = "Checked"
        }
    }
}

# Export CSV
$outFile = "MDE-GuestAgent-Status-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
$results | Export-Csv $outFile -NoTypeInformation

Write-Host "`nVerification Complete! CSV saved to: $outFile" -ForegroundColor Green

$results | Format-Table -AutoSize