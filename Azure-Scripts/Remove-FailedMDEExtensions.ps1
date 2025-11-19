<#
.SYNOPSIS
Uninstalls only FAILED MDE Windows & Linux VM extensions across multiple Azure subscriptions.
Adds skip logic when MDE extension is NOT present or already removed.

.PARAMETER SubscriptionIds
List of subscription IDs to process.

#>

param(
    [Parameter(Mandatory = $true)]
    [string[]]$SubscriptionIds
)

Write-Host "`n=== MDE FAILED Extension Removal Tool ===" -ForegroundColor Cyan
#Connect-AzAccount -ErrorAction Stop | Out-Null

$log = @()

foreach ($sub in $SubscriptionIds) {

    Write-Host "`n=== Subscription: $sub ===" -ForegroundColor Yellow
    Set-AzContext -SubscriptionId $sub -ErrorAction Stop | Out-Null

    $vms = Get-AzVM -ErrorAction SilentlyContinue

    foreach ($vm in $vms) {

        $vmName = $vm.Name
        $rg = $vm.ResourceGroupName

        # Retrieve extensions
        $extensions = Get-AzVMExtension -ResourceGroupName $rg -VMName $vmName -ErrorAction SilentlyContinue

        # Detect valid MDE extensions
        $mdeExtensions = $extensions | Where-Object {
            $_.ExtensionType -eq "MDE.Windows" -or
            $_.ExtensionType -eq "MDE.Linux"
        }

        # No MDE extension? Skip.
        if ($mdeExtensions.Count -eq 0) {

            Write-Host "[$vmName] No MDE extension found — skipping..." -ForegroundColor DarkYellow

            $log += [PSCustomObject]@{
                SubscriptionId    = $sub
                VMName            = $vmName
                ResourceGroup     = $rg
                ExtensionType     = "None"
                ProvisioningState = "N/A"
                Result            = "Skipped (No extension)"
            }

            continue
        }

        # Process each detected MDE extension on this VM
        foreach ($ext in $mdeExtensions) {

            # Skip clean or succeeded extensions
            if ($ext.ProvisioningState -ne "Failed") {
                Write-Host "[$vmName] MDE extension OK — skipping." -ForegroundColor Green

                $log += [PSCustomObject]@{
                    SubscriptionId    = $sub
                    VMName            = $vmName
                    ResourceGroup     = $rg
                    ExtensionType     = $ext.ExtensionType
                    ProvisioningState = $ext.ProvisioningState
                    Result            = "Skipped (Healthy)"
                }

                continue
            }

            # Remove failed extensions
            Write-Host "[$vmName] Removing FAILED MDE extension: $($ext.ExtensionType)" -ForegroundColor Red

            try {
                Remove-AzVMExtension `
                    -ResourceGroupName $rg `
                    -VMName $vmName `
                    -Name $ext.Name `
                    -Force `
                    -ErrorAction Stop

                $result = "Removed"
            }
            catch {
                Write-Host "ERROR removing extension on VM {$vmName}: $_" -ForegroundColor Red
                $result = "RemoveFailed: $_"
            }

            # Log result
            $log += [PSCustomObject]@{
                SubscriptionId    = $sub
                VMName            = $vmName
                ResourceGroup     = $rg
                ExtensionType     = $ext.ExtensionType
                ProvisioningState = $ext.ProvisioningState
                Result            = $result
            }
        }
    }
}

# Export results
$outFile = "MDE-Failed-Extension-Removal-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
$log | Export-Csv $outFile -NoTypeInformation

Write-Host "`nCompleted! Log saved to: $outFile" -ForegroundColor Green
$log | Format-Table -AutoSize