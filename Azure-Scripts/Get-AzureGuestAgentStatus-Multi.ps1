<#
.SYNOPSIS
Checks Azure Guest Agent health for Windows & Linux VMs across multiple subscriptions.
Uses RunCommand to query OS-level agent status.

.OUTPUT
CSV report of agent health.

.PARAMETER SubscriptionIds
List of subscription IDs.

#>

param(
    [Parameter(Mandatory = $true)]
    [string[]]$SubscriptionIds
)


Write-Host "`n=== Azure Guest Agent Health Scanner (Multi-Subscription) ===" -ForegroundColor Cyan

#Connect-AzAccount -ErrorAction Stop | Out-Null

$results = @()

foreach ($sub in $SubscriptionIds) {

    Write-Host "`n--- Subscription: $sub ---" -ForegroundColor Yellow
    Set-AzContext -SubscriptionId $sub -ErrorAction Stop | Out-Null

    # Get only running VMs (skip deallocated)
    $vms = Get-AzVM -Status | Where-Object { $_.PowerState -eq "VM running" }

    foreach ($vm in $vms) {

        $osType = $vm.StorageProfile.OSDisk.OSType
        $rg     = $vm.ResourceGroupName
        $vmName = $vm.Name

        Write-Host "Checking VM: $vmName ($osType)" -ForegroundColor Cyan

        try {
            if ($osType -eq "Windows") {
                # RunCommand to check Windows Azure agent
                $cmd = @"
Get-Service -Name WindowsAzureGuestAgent, RdAgent -ErrorAction SilentlyContinue | 
Select-Object Name, Status, StartType |
Format-List

(Get-Item 'HKLM:\SOFTWARE\Microsoft\Windows Azure\HandlerState').GetValue('Version')
"@

                $run = Invoke-AzVMRunCommand -ResourceGroupName $rg -Name $vmName `
                    -CommandId "RunPowerShellScript" -ScriptString $cmd -ErrorAction Stop
            }
            else {
                # RunCommand to check Linux waagent
                $cmd = @"
systemctl status walinuxagent 2>&1 | sed -n '1,3p'
waagent --version 2>&1 | head -n 1
"@

                $run = Invoke-AzVMRunCommand -ResourceGroupName $rg -Name $vmName `
                    -CommandId "RunShellScript" -ScriptString $cmd -ErrorAction Stop
            }

            $output = $run.Value[0].Message
            $status = "Success"
        }
        catch {
            $output = $_.Exception.Message
            $status = "Failed"
        }

        $results += [PSCustomObject]@{
            SubscriptionId = $sub
            VMName         = $vmName
            ResourceGroup  = $rg
            OS             = $osType
            AgentStatus    = $status
            Output         = $output.Trim()
        }
    }
}

# Export CSV
$outFile = "Azure-Agent-Health-MultiSubs-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
$results | Export-Csv $outFile -NoTypeInformation

Write-Host "`nScan complete!" -ForegroundColor Green
Write-Host "Results saved to: $outFile" -ForegroundColor Yellow

$results | Format-Table -AutoSize