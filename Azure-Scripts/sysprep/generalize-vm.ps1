# -----------------------
# CONFIGURATION
# -----------------------
$ResourceGroupName = "bab-vdi-avd-weeu-rg-01"
$VMName = "BABAVDSHDTA-2-Clone"
$Location = "westeurope"  # Same as the VM
$RunSysprep = $true


# -----------------------
# RUN SYSPREP (AVD FLAGS)
# -----------------------
if ($RunSysprep) {
    Write-Host "Running Sysprep on AVD image VM..."

    $script = @'
Start-Process -FilePath "C:\Windows\System32\Sysprep\Sysprep.exe" `
  -ArgumentList "/oobe /generalize /shutdown /mode:vm /quiet" -Wait
'@

    Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName `
        -CommandId 'RunPowerShellScript' -ScriptString $script

    Write-Host "Sysprep running. Waiting for shutdown..."
    Start-Sleep -Seconds 60
}

# -----------------------
# DEALLOCATE VM
# -----------------------
Write-Host "Deallocating VM..."
Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force -NoWait

# Wait for VM to be deallocated
Write-Host "Waiting for VM to reach 'StoppedDeallocated' state..."
do {
    Start-Sleep -Seconds 10
    $vmStatus = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status).Statuses |
        Where-Object { $_.Code -like 'PowerState/*' } |
        Select-Object -ExpandProperty Code
    Write-Host "Current VM status: $vmStatus"
} while ($vmStatus -ne 'PowerState/deallocated')

# -----------------------
# GENERALIZE VM
# -----------------------
Write-Host "Generalizing AVD VM in Azure..."
Set-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Generalized

Write-Host "`n✅ VM is generalized and ready to create a host pool image!"
