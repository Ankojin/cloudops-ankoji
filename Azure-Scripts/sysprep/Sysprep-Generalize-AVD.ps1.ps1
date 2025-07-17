# -----------------------
# CONFIGURATION
# -----------------------
$ResourceGroupName = "bab-vdi-avd-weeu-rg-01"
$VMName = "BABAVDSHDTA-2-Clone"
$Location = "westeurope"
$GalleryName = "bab_avd_shared_win10_gallery"
$ImageDefinitionName = "bab-w10-avd-img"
# Use valid image version format
$ImageVersion = "{0}.{1}.{2}" -f (Get-Date -Format "yyyy"), (Get-Date -Format "MM"), (Get-Date -Format "dd")
$TargetLocation = "swedencentral"
# -----------------------
# CHECK IF GENERALIZED
# -----------------------
$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status
if ($vm.ProvisioningState -eq "Generalized") {
    Write-Host "⚠️ VM $VMName is already generalized. Skipping Sysprep and generalization."
    $alreadyGeneralized = $true
} else {
    $alreadyGeneralized = $false
}

# -----------------------
# SYSPREP (IF NOT GENERALIZED)
# -----------------------
if (-not $alreadyGeneralized) {
    Write-Host "📦 Running Sysprep on VM $VMName..."

    $sysprepScript = @'
REM Enable CD/DVD-ROM
reg add HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\cdrom /v start /t REG_DWORD /d 1 /f

Start-Process -FilePath "C:\Windows\System32\Sysprep\Sysprep.exe" `
  -ArgumentList "/oobe /generalize /shutdown /mode:vm /quiet" -Wait
'@

    $sysprepResult = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName `
        -CommandId 'RunPowerShellScript' -ScriptString $sysprepScript -ErrorAction Stop

    if ($sysprepResult.Value[0].Message -notmatch "ReturnValue = 0") {
        Write-Error "❌ Sysprep may have failed. Skipping image creation."
        exit 1
    }

    Write-Host "⏳ Waiting for VM to shut down after Sysprep..."
    Start-Sleep -Seconds 60

    # -----------------------
    # DEALLOCATE VM
    # -----------------------
    Write-Host "🛑 Deallocating VM..."
    Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force

    Write-Host "⏳ Waiting for 'deallocated' state..."
    do {
        Start-Sleep -Seconds 10
        $vmStatus = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status).Statuses |
            Where-Object { $_.Code -like 'PowerState/*' } |
            Select-Object -ExpandProperty Code
        Write-Host "Current status: $vmStatus"
    } while ($vmStatus -ne 'PowerState/deallocated')

    # -----------------------
    # GENERALIZE VM
    # -----------------------
    Write-Host "🔁 Generalizing VM in Azure..."
    Set-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Generalized
}

# -----------------------
# CREATE IMAGE DEFINITION & VERSION
# -----------------------

# Ensure Shared Image Gallery exists
if (-not (Get-AzGallery -ResourceGroupName $ResourceGroupName -Name $GalleryName -ErrorAction SilentlyContinue)) {
    Write-Host "📁 Creating Shared Image Gallery: $GalleryName"
    New-AzGallery -ResourceGroupName $ResourceGroupName `
        -GalleryName $GalleryName `
        -Location $Location `
        -Description "AVD Shared Image Gallery"
}

# Create Image Definition if not exists
if (-not (Get-AzGalleryImageDefinition -ResourceGroupName $ResourceGroupName -GalleryName $GalleryName -Name $ImageDefinitionName -ErrorAction SilentlyContinue)) {
    Write-Host "📸 Creating Image Definition: $ImageDefinitionName"
    New-AzGalleryImageDefinition `
        -ResourceGroupName $ResourceGroupName `
        -GalleryName $GalleryName `
        -Name $ImageDefinitionName `
        -Location $Location `
        -OsState Generalized `
        -OsType Windows `
        -Publisher "babcloud" `
        -Offer "windows-10-avd" `
        -Sku "20h2-avd" `
        -HyperVGeneration V1
}

# Create Image Version
$sourceVMId = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName).Id

Write-Host "📦 Creating Image Version: $ImageVersion"
New-AzGalleryImageVersion `
    -ResourceGroupName $ResourceGroupName `
    -GalleryName $GalleryName `
    -GalleryImageDefinitionName $ImageDefinitionName `
    -Name $ImageVersion `
    -Location $Location `
    -SourceImageVMId $sourceVMId `
    -TargetRegion @(
        @{Name = $Location; ReplicaCount = 1},
        @{Name = $TargetLocation; ReplicaCount = 1}
    )

Write-Host "`n✅ AVD VM is now fully generalized and published to Shared Image Gallery."