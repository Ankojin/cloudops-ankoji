# ============================================================================
# Verify Image Generalization Status
# ============================================================================
#
# This script verifies if a VM or image is properly generalized
# Use this to troubleshoot "OS Provisioning did not finish" errors
#
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$VMName,
    
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "bab-vdi-avd-weeu-rg-01",
    
    [Parameter(Mandatory = $false)]
    [string]$GalleryName = "bab_avd_shared_win10_gallery",
    
    [Parameter(Mandatory = $false)]
    [string]$ImageDefinitionName = "bab-w10-avd-img",
    
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId = "cb801de6-404a-4e76-8e9a-475206cbc2e5",
    
    [Parameter(Mandatory = $false)]
    [switch]$DeleteFailedImage
)

Write-Host "=== Image Generalization Verification Tool ===" -ForegroundColor Cyan
Write-Host ""

# Connect to Azure
$context = Get-AzContext
if (-not $context -or $context.Subscription.Id -ne $SubscriptionId) {
    Write-Host "Connecting to Azure subscription: $SubscriptionId" -ForegroundColor Yellow
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

Write-Host "✅ Connected to subscription: $($context.Subscription.Name)" -ForegroundColor Green
Write-Host ""

# Check VM generalization status
if ($VMName) {
    Write-Host "=== Checking VM: $VMName ===" -ForegroundColor Cyan
    
    try {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop
        
        Write-Host "VM Status:" -ForegroundColor Yellow
        Write-Host "  Name: $($vm.Name)"
        Write-Host "  Location: $($vm.Location)"
        Write-Host "  Size: $($vm.HardwareProfile.VmSize)"
        
        # Check if VM has OSProfile (indicates NOT generalized)
        if ($vm.OSProfile) {
            Write-Host "  ❌ OSProfile exists: VM is NOT GENERALIZED" -ForegroundColor Red
            Write-Host "  Computer Name: $($vm.OSProfile.ComputerName)" -ForegroundColor Red
            Write-Host "  Admin Username: $($vm.OSProfile.AdminUsername)" -ForegroundColor Red
            Write-Host ""
            Write-Host "⚠️  This VM cannot be used for image creation!" -ForegroundColor Red
            Write-Host ""
            Write-Host "To fix:" -ForegroundColor Yellow
            Write-Host "  1. Run sysprep manually on the VM" -ForegroundColor Yellow
            Write-Host "  2. Deallocate the VM: Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force" -ForegroundColor Yellow
            Write-Host "  3. Generalize: Set-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Generalized" -ForegroundColor Yellow
        }
        else {
            Write-Host "  ✅ OSProfile is NULL: VM IS GENERALIZED" -ForegroundColor Green
            Write-Host ""
            Write-Host "This VM can be used for image creation!" -ForegroundColor Green
        }
        
        # Check power state
        $vmStatus = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status
        $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).Code
        $provisioningState = ($vmStatus.Statuses | Where-Object { $_.Code -like "ProvisioningState/*" }).DisplayStatus
        
        Write-Host ""
        Write-Host "Power State: $powerState" -ForegroundColor Yellow
        Write-Host "Provisioning State: $provisioningState" -ForegroundColor Yellow
        
    }
    catch {
        Write-Host "❌ Error checking VM: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Check gallery images
Write-Host ""
Write-Host "=== Checking Gallery Images ===" -ForegroundColor Cyan

try {
    $gallery = Get-AzGallery -ResourceGroupName $ResourceGroupName -Name $GalleryName -ErrorAction Stop
    Write-Host "✅ Gallery found: $($gallery.Name)" -ForegroundColor Green
    
    $imageDef = Get-AzGalleryImageDefinition -ResourceGroupName $ResourceGroupName `
        -GalleryName $GalleryName `
        -Name $ImageDefinitionName `
        -ErrorAction Stop
    
    Write-Host "✅ Image definition found: $($imageDef.Name)" -ForegroundColor Green
    Write-Host "  OS Type: $($imageDef.OsType)"
    Write-Host "  OS State: $($imageDef.OsState)" # Should be "Generalized"
    Write-Host "  Hyper-V Generation: $($imageDef.HyperVGeneration)"
    Write-Host ""
    
    if ($imageDef.OsState -ne "Generalized") {
        Write-Host "  ❌ OS State is NOT Generalized!" -ForegroundColor Red
    }
    
    # List all versions
    Write-Host "Image Versions:" -ForegroundColor Cyan
    $versions = Get-AzGalleryImageVersion -ResourceGroupName $ResourceGroupName `
        -GalleryName $GalleryName `
        -GalleryImageDefinitionName $ImageDefinitionName `
        -ErrorAction Stop |
        Sort-Object -Property PublishingProfile.PublishedDate -Descending
    
    if ($versions.Count -eq 0) {
        Write-Host "  No versions found" -ForegroundColor Yellow
    }
    else {
        foreach ($version in $versions) {
            $publishedDate = $version.PublishingProfile.PublishedDate
            $sourceVMId = $version.StorageProfile.Source.Id
            $sourceVMName = if ($sourceVMId) { ($sourceVMId -split '/')[-1] } else { "Unknown" }
            
            Write-Host ""
            Write-Host "  Version: $($version.Name)" -ForegroundColor Yellow
            Write-Host "    Published: $publishedDate"
            Write-Host "    Source VM: $sourceVMName"
            Write-Host "    Provisioning State: $($version.ProvisioningState)"
            Write-Host "    Replication Status: $($version.ReplicationStatus.AggregatedState)"
            
            # Check if this version has been used
            $regions = $version.PublishingProfile.TargetRegions
            Write-Host "    Replicated to: $($regions.Name -join ', ')"
        }
    }
    
}
catch {
    Write-Host "❌ Error checking gallery: $($_.Exception.Message)" -ForegroundColor Red
}

# Check for VMs deployed from the image that failed
Write-Host ""
Write-Host "=== Checking for Failed VM Deployments ===" -ForegroundColor Cyan

try {
    $allVMs = Get-AzVM -ResourceGroupName $ResourceGroupName -Status
    $failedVMs = $allVMs | Where-Object {
        $_.Statuses | Where-Object {
            $_.Code -like "*ProvisioningState/failed*" -or
            $_.Code -like "*OSProvisioningClientError*" -or
            $_.Code -like "*OSProvisioningTimedOut*"
        }
    }
    
    if ($failedVMs.Count -eq 0) {
        Write-Host "✅ No failed VMs found" -ForegroundColor Green
    }
    else {
        Write-Host "⚠️  Found $($failedVMs.Count) failed VM(s):" -ForegroundColor Red
        
        foreach ($failedVM in $failedVMs) {
            Write-Host ""
            Write-Host "  VM: $($failedVM.Name)" -ForegroundColor Yellow
            
            $errorStatus = $failedVM.Statuses | Where-Object {
                $_.Code -like "*failed*" -or $_.Code -like "*Error*"
            }
            
            foreach ($status in $errorStatus) {
                Write-Host "    Code: $($status.Code)" -ForegroundColor Red
                Write-Host "    Message: $($status.Message)" -ForegroundColor Red
            }
            
            # Check if deployed from our gallery
            $vmDetail = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $failedVM.Name
            $imageRef = $vmDetail.StorageProfile.ImageReference
            
            if ($imageRef.Id -like "*$GalleryName*") {
                Write-Host "    ⚠️  This VM was deployed from gallery: $GalleryName" -ForegroundColor Red
                Write-Host "    Image: $($imageRef.Id)" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "    Recommended action:" -ForegroundColor Yellow
                Write-Host "    1. Delete this VM: Remove-AzVM -ResourceGroupName $ResourceGroupName -Name $($failedVM.Name) -Force" -ForegroundColor Yellow
                Write-Host "    2. Recreate image from properly generalized source" -ForegroundColor Yellow
            }
        }
    }
}
catch {
    Write-Host "Warning: Could not check for failed VMs: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Option to delete failed image version
if ($DeleteFailedImage) {
    Write-Host ""
    Write-Host "=== Delete Failed Image Version ===" -ForegroundColor Red
    
    Write-Host "⚠️  WARNING: This will delete image versions!" -ForegroundColor Red
    Write-Host ""
    
    $versions = Get-AzGalleryImageVersion -ResourceGroupName $ResourceGroupName `
        -GalleryName $GalleryName `
        -GalleryImageDefinitionName $ImageDefinitionName |
        Sort-Object -Property PublishingProfile.PublishedDate -Descending
    
    Write-Host "Available versions to delete:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $versions.Count; $i++) {
        Write-Host "  [$i] Version: $($versions[$i].Name) - Published: $($versions[$i].PublishingProfile.PublishedDate)"
    }
    
    Write-Host ""
    $versionIndex = Read-Host "Enter version number to delete (or 'q' to quit)"
    
    if ($versionIndex -ne 'q' -and $versionIndex -match '^\d+$') {
        $versionToDelete = $versions[$versionIndex]
        
        if ($versionToDelete) {
            Write-Host "Deleting version: $($versionToDelete.Name)..." -ForegroundColor Yellow
            
            Remove-AzGalleryImageVersion `
                -ResourceGroupName $ResourceGroupName `
                -GalleryName $GalleryName `
                -GalleryImageDefinitionName $ImageDefinitionName `
                -Name $versionToDelete.Name `
                -Force
            
            Write-Host "✅ Version deleted" -ForegroundColor Green
        }
    }
}

# Summary and recommendations
Write-Host ""
Write-Host "=== Summary & Recommendations ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Common Issues & Fixes:" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. 'OS Provisioning did not finish' error:" -ForegroundColor White
Write-Host "   Cause: Image was not properly generalized" -ForegroundColor Gray
Write-Host "   Fix: Re-run Clone-And-Generalize-AVD.ps1 with FIXED sysprep step" -ForegroundColor Green
Write-Host ""
Write-Host "2. VM still has OSProfile:" -ForegroundColor White
Write-Host "   Cause: Set-AzVM -Generalized was not run or failed" -ForegroundColor Gray
Write-Host "   Fix: Manually generalize: Set-AzVM -ResourceGroupName <rg> -Name <vm> -Generalized" -ForegroundColor Green
Write-Host ""
Write-Host "3. Sysprep didn't complete:" -ForegroundColor White
Write-Host "   Cause: Sysprep process was interrupted or timed out" -ForegroundColor Gray
Write-Host "   Fix: Check C:\Windows\System32\Sysprep\Panther\setuperr.log on source VM" -ForegroundColor Green
Write-Host ""
Write-Host "4. Image works but VMs fail to provision:" -ForegroundColor White
Write-Host "   Cause: Image contains AVD agents or domain membership" -ForegroundColor Gray
Write-Host "   Fix: Ensure clone VM prep removes AVD agents BEFORE sysprep" -ForegroundColor Green
Write-Host ""

Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "1. Delete any failed VMs" -ForegroundColor White
Write-Host "2. Delete the bad image version (use -DeleteFailedImage)" -ForegroundColor White
Write-Host "3. Re-run Clone-And-Generalize-AVD.ps1 with the FIXED script" -ForegroundColor White
Write-Host "4. Verify new image with this script before deploying VMs" -ForegroundColor White
Write-Host ""
