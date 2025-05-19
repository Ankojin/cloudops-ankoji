param (
    [string]$ResourceGroupName,
    [string]$VMName,
    [string]$Location,
    [string]$UnattendUrl # e.g., https://<storageaccount>.blob.core.windows.net/scripts/unattend.xml
)

$clonedVM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
if ($clonedVM.StorageProfile.OsDisk.OsType -eq "Windows") {
    Write-Host "Preparing to generalize cloned VM '$VMName' with Sysprep and unattend.xml..."

    $vmStatus = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status).Statuses | Where-Object { $_.Code -like "PowerState*" }
    if ($vmStatus.DisplayStatus -ne "VM running") {
        Write-Host "Starting cloned VM..."
        Start-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName | Out-Null
        Start-Sleep -Seconds 60
    }

    $sysprepScript = @"
Invoke-WebRequest -Uri '$UnattendUrl' -OutFile 'C:\unattend.xml'
Start-Process -FilePath 'C:\Windows\System32\Sysprep\Sysprep.exe' -ArgumentList '/generalize /oobe /shutdown /unattend:C:\unattend.xml /quiet' -Wait
"@
    $scriptFile = "sysprep-unattend.ps1"
    Set-Content -Path $scriptFile -Value $sysprepScript

    Set-AzVMCustomScriptExtension -ResourceGroupName $ResourceGroupName `
        -VMName $VMName `
        -Name "SysprepUnattendExtension" `
        -Location $Location `
        -FileUri "" `
        -Run "powershell -ExecutionPolicy Unrestricted -Command `$sysprepScript" `
        -ForceRerun (New-Guid).Guid
        
    Write-Host "Waiting for VM to shutdown after Sysprep..."
    do {
        Start-Sleep -Seconds 15
        $vmStatus = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status).Statuses | Where-Object { $_.Code -like "PowerState*" }
    } while ($vmStatus.DisplayStatus -ne "VM deallocated")

    Write-Host "Sysprep with unattend.xml complete. VM is deallocated and generalized."
} else {
    Write-Host "Sysprep is only applicable to Windows VMs. Skipping for OS type: $($clonedVM.StorageProfile.OsDisk.OsType)"
}