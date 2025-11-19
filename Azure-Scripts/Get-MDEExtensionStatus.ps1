<#
.SYNOPSIS
Checks Microsoft Defender for Endpoint (MDE) extension status 
across multiple Azure subscriptions (Windows + Linux).

.OUTPUT
Exports a unified CSV with correct MDE detection.

.PARAMETER SubscriptionIds
Array of subscription IDs to scan.
#>

param(
    [Parameter(Mandatory = $true)]
    [string[]]$SubscriptionIds
)

Write-Host "`n=== MDE Extension Scanner (Multi-Subscription) ===" -ForegroundColor Cyan

# Connect to Azure
Connect-AzAccount -ErrorAction Stop | Out-Null

$allResults = @()

foreach ($sub in $SubscriptionIds) {

    Write-Host "`n--- Subscription: $sub ---" -ForegroundColor Yellow
    
    try {
        Set-AzContext -SubscriptionId $sub -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Host "ERROR: Unable to set context to $sub" -ForegroundColor Red
        continue
    }

    $vms = Get-AzVM -Status -ErrorAction SilentlyContinue

    foreach ($vm in $vms) {
        
        $extensions = Get-AzVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -ErrorAction SilentlyContinue

        # FINAL detection logic (best for Azure 2024)
        $mde = $extensions | Where-Object {
            $_.ExtensionType -eq "MDE.Windows" -or
            $_.ExtensionType -eq "MDE.Linux"
        }

        if ($null -eq $mde) {
            $allResults += [PSCustomObject]@{
                SubscriptionId    = $sub
                VMName            = $vm.Name
                ResourceGroup     = $vm.ResourceGroupName
                OS                = $vm.StorageProfile.OSDisk.OSType
                ExtensionPresent  = "No"
                ExtensionType     = "Not Installed"
                ProvisioningState = "N/A"
                ExtensionVersion  = "N/A"
            }
        }
        else {
            foreach ($ext in $mde) {
                $allResults += [PSCustomObject]@{
                    SubscriptionId    = $sub
                    VMName            = $vm.Name
                    ResourceGroup     = $vm.ResourceGroupName
                    OS                = $vm.StorageProfile.OSDisk.OSType
                    ExtensionPresent  = "Yes"
                    ExtensionType     = $ext.ExtensionType
                    ProvisioningState = $ext.ProvisioningState
                    ExtensionVersion  = $ext.TypeHandlerVersion
                }
            }
        }
    }
}

# Export CSV
$outFile = "MDE-Extension-Status-MultiSubs-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
$allResults | Export-Csv $outFile -NoTypeInformation

Write-Host "`nScan complete!" -ForegroundColor Green
Write-Host "CSV exported to: $outFile" -ForegroundColor Yellow

# Show on screen
$allResults | Format-Table -AutoSize