param(
    [Parameter(Mandatory = $true)]
    [string[]]$SubscriptionIds
)

Write-Host "`n=== Bulk Install: MDE.Windows Extension ===" -ForegroundColor Cyan

Connect-AzAccount -ErrorAction Stop | Out-Null
$results = @()

foreach ($sub in $SubscriptionIds) {

    Write-Host "`n--- Subscription: $sub ---" -ForegroundColor Yellow
    Set-AzContext -SubscriptionId $sub -ErrorAction Stop | Out-Null

    $vms = Get-AzVM -Status | Where-Object {
        $_.StorageProfile.OSDisk.OSType -eq "Windows"
    }

    foreach ($vm in $vms) {

        # Skip deallocated VMs
        if ($vm.Statuses[1].DisplayStatus -eq "VM deallocated") {
            Write-Host "Skipping $($vm.Name): VM Deallocated" -ForegroundColor DarkYellow
            continue
        }

        # Get current extensions
        $ext = Get-AzVMExtension -VMName $vm.Name -ResourceGroupName $vm.ResourceGroupName -ErrorAction SilentlyContinue

        $mde = $ext | Where-Object { $_.ExtensionType -eq "MDE.Windows" }

        if ($mde) {
            Write-Host "Skipping $($vm.Name): Already Installed" -ForegroundColor Green
            continue
        }

        Write-Host "Installing MDE.Windows on $($vm.Name)..." -ForegroundColor Cyan

        try {
            Set-AzVMExtension `
                -ResourceGroupName $vm.ResourceGroupName `
                -VMName $vm.Name `
                -Name "MDE.Windows" `
                -Publisher "Microsoft.Azure.AzureDefenderForServers" `
                -ExtensionType "MDE.Windows" `
                -TypeHandlerVersion "1.0" `
                -AutoUpgradeMinorVersion $true `
                -ErrorAction Stop

            $results += [PSCustomObject]@{
                SubscriptionId = $sub
                VMName         = $vm.Name
                OS             = "Windows"
                Status         = "Installed"
            }

            Write-Host "Installed successfully." -ForegroundColor Green
        }
        catch {
            $results += [PSCustomObject]@{
                SubscriptionId = $sub
                VMName         = $vm.Name
                OS             = "Windows"
                Status         = "Failed: $($_.Exception.Message)"
            }

            Write-Host "Failed installing on $($vm.Name)" -ForegroundColor Red
        }
    }
}

$csv = "MDE-Windows-Install-Report-$(Get-Date -Format yyyyMMddHHmm).csv"
$results | Export-Csv $csv -NoTypeInformation
Write-Host "`nReport saved to: $csv" -ForegroundColor Yellow