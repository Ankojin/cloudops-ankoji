[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,
    
    [Parameter(Mandatory=$true)]
    [string]$BrokenVM,
    
    [Parameter(Mandatory=$true)]
    [string]$RescueVM,
    
    [switch]$CleanupRescueVM = $false
)

################################################################################
# Azure VM Restore Script - After Boot Repair
# Purpose: Restore repaired OS disk back to original VM
################################################################################

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "SUCCESS" { "Green" }
        default { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

try {
    Write-Log "Starting VM restore process..." "INFO"
    
    # ----------------------------
    # Step 1: Get VM and disk info
    # ----------------------------
    Write-Log "Getting VM and disk information..." "INFO"
    
    $BrokenVMObj = Get-AzVM -ResourceGroupName $ResourceGroup -Name $BrokenVM -ErrorAction Stop
    $OriginalOSDiskName = $BrokenVMObj.StorageProfile.OsDisk.Name
    $OriginalOSDisk = Get-AzDisk -ResourceGroupName $ResourceGroup -DiskName $OriginalOSDiskName
    
    $RescueVMObj = Get-AzVM -ResourceGroupName $ResourceGroup -Name $RescueVM -ErrorAction Stop
    
    # Find the attached data disk (copy of OS disk with "-copy-" in name)
    $RepairedCopyDisk = $null
    $RescueDataDisks = @()
    foreach ($disk in $RescueVMObj.StorageProfile.DataDisks) {
        $diskObj = Get-AzDisk -ResourceGroupName $ResourceGroup -DiskName $disk.Name
        # Look for the copy disk (has "-copy-" in name)
        if ($diskObj.Name -like "*-copy-*") {
            $RepairedCopyDisk = $diskObj
        } else {
            $RescueDataDisks += $diskObj
        }
    }
    
    if (-not $RepairedCopyDisk) {
        Write-Log "Could not find copy disk, checking for original disk..." "WARN"
        # Fallback: look for original disk name
        foreach ($disk in $RescueVMObj.StorageProfile.DataDisks) {
            $diskObj = Get-AzDisk -ResourceGroupName $ResourceGroup -DiskName $disk.Name
            if ($diskObj.Name -eq $OriginalOSDiskName) {
                $RepairedCopyDisk = $diskObj
            } else {
                $RescueDataDisks += $diskObj
            }
        }
    }
    
    if (-not $RepairedCopyDisk) {
        throw "Could not find repaired disk attached to rescue VM. Expected disk with '-copy-' in name."
    }
    
    Write-Log "Found repaired copy disk: $($RepairedCopyDisk.Name)" "SUCCESS"
    Write-Log "Original OS disk: $($OriginalOSDisk.Name)" "INFO"
    if ($RescueDataDisks.Count -gt 0) {
        Write-Log "Found $($RescueDataDisks.Count) additional data disk(s) attached to rescue VM." "INFO"
    }
    
    # ----------------------------
    # Step 2: Stop both VMs
    # ----------------------------
    Write-Log "Stopping both VMs..." "INFO"
    
    Stop-AzVM -ResourceGroupName $ResourceGroup -Name $BrokenVM -Force -ErrorAction SilentlyContinue
    Stop-AzVM -ResourceGroupName $ResourceGroup -Name $RescueVM -Force -ErrorAction Stop
    
    Write-Log "VMs stopped successfully" "SUCCESS"
    
    # ----------------------------
    # Step 3: Detach copy disk and all data disks from rescue VM
    # ----------------------------
    Write-Log "Detaching repaired copy disk and all data disks from rescue VM..." "INFO"
    
    Remove-AzVMDataDisk -VM $RescueVMObj -Name $RepairedCopyDisk.Name | Out-Null
    foreach ($dataDisk in $RescueDataDisks) {
        Remove-AzVMDataDisk -VM $RescueVMObj -Name $dataDisk.Name | Out-Null
    }
    Update-AzVM -ResourceGroupName $ResourceGroup -VM $RescueVMObj | Out-Null
    
    Write-Log "Copy disk and data disks detached from rescue VM" "SUCCESS"
    
    # ----------------------------
    # Step 4: Swap OS disk and attach all data disks to broken VM
    # ----------------------------
    Write-Log "Swapping OS disk on broken VM with repaired copy..." "INFO"
    
    # Remove old OS disk reference
    Write-Log "Removing old OS disk reference..." "INFO"
    $BrokenVMObj.StorageProfile.OsDisk = $null
    
    # Set the repaired copy disk as new OS disk
    Write-Log "Setting repaired copy disk as new OS disk..." "INFO"
    Set-AzVMOSDisk -VM $BrokenVMObj -ManagedDiskId $RepairedCopyDisk.Id -Name $RepairedCopyDisk.Name -CreateOption Attach -Linux | Out-Null
    
    # Attach all data disks from rescue VM
    if ($RescueDataDisks.Count -gt 0) {
        Write-Log "Attaching $($RescueDataDisks.Count) data disk(s) to broken VM..." "INFO"
        $lun = 0
        foreach ($dataDisk in $RescueDataDisks) {
            Add-AzVMDataDisk -VM $BrokenVMObj -Name $dataDisk.Name -ManagedDiskId $dataDisk.Id -Lun $lun -CreateOption Attach | Out-Null
            $lun++
        }
    }
    
    # Update VM configuration
    try {
        Update-AzVM -ResourceGroupName $ResourceGroup -VM $BrokenVMObj -ErrorAction Stop | Out-Null
        Write-Log "OS disk and data disks swapped/attached successfully" "SUCCESS"
    } catch {
        Write-Log "Error swapping disk: $($_.Exception.Message)" "ERROR"
        Write-Log "Attempting alternative method..." "WARN"
        
        # Alternative: Use Set-AzVMOSDisk with DiskSizeGB parameter
        $diskSize = $RepairedCopyDisk.DiskSizeGB
        Set-AzVMOSDisk -VM $BrokenVMObj -ManagedDiskId $RepairedCopyDisk.Id -Name $RepairedCopyDisk.Name -CreateOption Attach -Linux -DiskSizeGB $diskSize | Out-Null
        if ($RescueDataDisks.Count -gt 0) {
            $lun = 0
            foreach ($dataDisk in $RescueDataDisks) {
                Add-AzVMDataDisk -VM $BrokenVMObj -Name $dataDisk.Name -ManagedDiskId $dataDisk.Id -Lun $lun -CreateOption Attach | Out-Null
                $lun++
            }
        }
        Update-AzVM -ResourceGroupName $ResourceGroup -VM $BrokenVMObj | Out-Null
        Write-Log "OS disk and data disks swapped/attached successfully (alternative method)" "SUCCESS"
    }
    
    # ----------------------------
    # Step 5: (SKIPPED) Do not start the repaired VM automatically
    # ----------------------------
    Write-Log "Not starting the repaired VM automatically. Please verify configuration before starting manually." "WARN"
    
    # ----------------------------
    # Step 6: Handle Old OS Disk and Snapshot
    # ----------------------------
    Write-Log "Checking for old OS disk and snapshot..." "INFO"
    
    # Find snapshot (created by rescue script)
    $snapshots = Get-AzSnapshot -ResourceGroupName $ResourceGroup | Where-Object { $_.Name -like "$OriginalOSDiskName-snapshot-*" }
    if ($snapshots) {
        Write-Log "Found $($snapshots.Count) snapshot(s) for backup" "INFO"
    }
    
    Write-Log "" "INFO"
    Write-Log "Old OS Disk: $($OriginalOSDisk.Name) - Keeping as backup" "INFO"
    Write-Log "New OS Disk: $($RepairedCopyDisk.Name) - Now attached to VM" "INFO"
    
    # ----------------------------
    # Step 7: Check VM status
    # ----------------------------
    Write-Log "Checking VM status..." "INFO"
    
    $vmStatus = Get-AzVM -ResourceGroupName $ResourceGroup -Name $BrokenVM -Status
    $powerState = $vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" } | Select-Object -ExpandProperty DisplayStatus
    
    Write-Log "VM Power State: $powerState" "INFO"
    
    # Get private IP
    $nic = Get-AzNetworkInterface -ResourceId $BrokenVMObj.NetworkProfile.NetworkInterfaces[0].Id
    $privateIP = $nic.IpConfigurations[0].PrivateIpAddress
    
    Write-Log "VM Private IP: $privateIP" "INFO"
    
    # ----------------------------
    # Step 8: Cleanup rescue VM (optional)
    # ----------------------------
    if ($CleanupRescueVM) {
        Write-Log "Cleaning up rescue VM resources..." "WARN"
        
        $confirmation = Read-Host "Delete rescue VM and its resources? (yes/no)"
        if ($confirmation -eq "yes") {
            # Delete rescue VM
            Write-Log "Deleting rescue VM..." "INFO"
            Remove-AzVM -ResourceGroupName $ResourceGroup -Name $RescueVM -Force
            Write-Log "Rescue VM deleted" "SUCCESS"
            
            # Delete NIC
            $rescueNIC = Get-AzNetworkInterface -ResourceGroupName $ResourceGroup | Where-Object { $_.Name -like "*$RescueVM*" }
            if ($rescueNIC) {
                Write-Log "Deleting rescue VM NIC..." "INFO"
                Remove-AzNetworkInterface -ResourceGroupName $ResourceGroup -Name $rescueNIC.Name -Force
                Write-Log "Rescue VM NIC deleted" "SUCCESS"
            }
            
            # Delete rescue VM OS disk
            $rescueDisk = Get-AzDisk -ResourceGroupName $ResourceGroup | Where-Object { $_.Name -like "*$RescueVM*" }
            if ($rescueDisk) {
                Write-Log "Deleting rescue VM OS disk..." "INFO"
                Remove-AzDisk -ResourceGroupName $ResourceGroup -DiskName $rescueDisk.Name -Force
                Write-Log "Rescue VM OS disk deleted" "SUCCESS"
            }
            
            Write-Log "" "INFO"
            Write-Log "After verifying VM boots correctly, you can clean up:" "WARN"
            Write-Log "  1. Old OS Disk: $($OriginalOSDisk.Name)" "WARN"
            Write-Log "  2. Snapshots: $($OriginalOSDiskName)-snapshot-*" "WARN"
            Write-Log "" "INFO"
            Write-Log "To delete old disk and snapshot after verification:" "INFO"
            Write-Log "  Remove-AzDisk -ResourceGroupName $ResourceGroup -DiskName '$($OriginalOSDisk.Name)' -Force" "INFO"
            if ($snapshots) {
                foreach ($snap in $snapshots) {
                    Write-Log "  Remove-AzSnapshot -ResourceGroupName $ResourceGroup -SnapshotName '$($snap.Name)' -Force" "INFO"
                }
            }
        }
    }
    
    # ----------------------------
    # Final Summary
    # ----------------------------
    Write-Log "========================================" "SUCCESS"
    Write-Log "VM RESTORE COMPLETED SUCCESSFULLY!" "SUCCESS"
    Write-Log "========================================" "SUCCESS"
    Write-Log "VM Name: $BrokenVM" "INFO"
    Write-Log "Resource Group: $ResourceGroup" "INFO"
    Write-Log "Private IP: $privateIP" "INFO"
    Write-Log "" "INFO"
    Write-Log "Next Steps:" "INFO"
    Write-Log "1. Connect via Bastion or jumpbox: ssh user@$privateIP" "INFO"
    Write-Log "2. Verify system boots correctly: uname -r" "INFO"
    Write-Log "3. Check logs: journalctl -xb" "INFO"
    Write-Log "4. Monitor serial console for any boot issues" "INFO"
    Write-Log "========================================" "SUCCESS"
    
    # Get boot diagnostics
    Write-Log "" "INFO"
    Write-Log "Fetching boot diagnostics (wait 2-3 minutes for boot)..." "INFO"
    Start-Sleep -Seconds 120
    
    try {
        $bootLog = Get-AzVMBootDiagnosticsData -ResourceGroupName $ResourceGroup -Name $BrokenVM -Windows:$false
        Write-Log "Boot diagnostics available at: $($bootLog.ConsoleScreenshotBlobUri)" "INFO"
    } catch {
        Write-Log "Boot diagnostics not yet available. Check Azure portal in a few minutes." "WARN"
    }
    
} catch {
    Write-Log "ERROR: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack Trace: $($_.Exception.StackTrace)" "ERROR"
    exit 1
}
