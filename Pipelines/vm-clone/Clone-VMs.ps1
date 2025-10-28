<#
.SYNOPSIS
    Clone Azure VMs from CSV with idempotency support and NIC management
.DESCRIPTION
    Clones VMs across subscriptions with snapshot, disk, and NIC lifecycle management
    Follows Azure best practices for resource management and idempotency
.NOTES
    Version: 2.0
    Author: CloudOps Team
    Requires: Azure CLI, PowerShell 7+
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SourceSubscription,
    
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$TargetSubscription,
    
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [ValidateLength(1,90)]
    [string]$SourceResourceGroup,
    
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [ValidateLength(1,90)]
    [string]$TargetResourceGroup,
    
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$VnetName,
    
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$VnetRg,
    
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$NsgName,
    
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$NsgRg,
    
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [ValidateLength(3,24)]
    [ValidatePattern('^[a-z0-9]+$')]
    [string]$BootDiagStorage,
    
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({Test-Path $_ -PathType Leaf})]
    [string]$CsvPath,
    
    [Parameter(Mandatory=$true)]
    [ValidateSet('BAB_DEV', 'BAB_SIT', 'BAB_CORE')]
    [string]$TargetEnvironment
)

#Requires -Version 7.0

$ErrorActionPreference = "Continue"
$global:ErrorCount = 0
$global:SuccessCount = 0

# Log file on Windows agent
$LogFile = "C:\log\clone_log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
if (-not (Test-Path "C:\log")) {
    New-Item -Path "C:\log" -ItemType Directory -Force | Out-Null
}

#region Helper Functions

function Log-Error {
    param(
        [Parameter(Mandatory=$true)]
        [string]$msg
    )
    
    Write-Error $msg
    "[ERROR] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $msg" | Out-File -FilePath $LogFile -Append -Encoding utf8
    $global:ErrorCount++
}

function Log-Info {
    param(
        [Parameter(Mandatory=$true)]
        [string]$msg
    )
    
    Write-Host $msg
    "[INFO] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $msg" | Out-File -FilePath $LogFile -Append -Encoding utf8
}

function Test-CsvData {
    param(
        [Parameter(Mandatory=$true)]
        [array]$VmList
    )
    
    $validationErrors = @()
    
    foreach ($vm in $VmList) {
        # Validate VM names follow Azure naming conventions
        if ($vm.NewVMName -notmatch '^[a-zA-Z0-9][-a-zA-Z0-9]{0,62}[a-zA-Z0-9]?$') {
            $validationErrors += "Invalid VM name: $($vm.NewVMName). Must be 1-64 chars, alphanumeric and hyphens only."
        }
        
        # Validate static IP format if provided
        if ($vm.StaticIp -and $vm.StaticIp.Trim() -ne "") {
            if ($vm.StaticIp -notmatch '^((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.?\b){4}$') {
                $validationErrors += "Invalid IP format for VM $($vm.NewVMName): $($vm.StaticIp)"
            }
        }
        
        # Validate VM size format
        if ($vm.VMSize -notmatch '^Standard_[A-Z]+\d+[a-z]*_v?\d+$') {
            $validationErrors += "Invalid VM size for $($vm.NewVMName): $($vm.VMSize). Must follow Azure VM size naming convention."
        }
        
        # Validate required fields
        if (-not $vm.SourceVMName -or $vm.SourceVMName.Trim() -eq "") {
            $validationErrors += "SourceVMName is required but empty for row with NewVMName: $($vm.NewVMName)"
        }
        
        if (-not $vm.SubnetName -or $vm.SubnetName.Trim() -eq "") {
            $validationErrors += "SubnetName is required but empty for VM: $($vm.NewVMName)"
        }
    }
    
    if ($validationErrors.Count -gt 0) {
        $validationErrors | ForEach-Object { Log-Error $_ }
        throw "CSV validation failed with $($validationErrors.Count) error(s)"
    }
    
    Log-Info "✅ CSV validation passed for $($VmList.Count) VM(s)"
}

function Remove-OrphanedNic {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResourceGroup,
        
        [Parameter(Mandatory=$true)]
        [string]$NicName,
        
        [Parameter(Mandatory=$true)]
        [bool]$WasCreatedInThisRun
    )
    
    if (-not $WasCreatedInThisRun) {
        Log-Info "NIC '$NicName' existed before this run. Skipping deletion to preserve existing infrastructure."
        return
    }
    
    try {
        Log-Info "Cleaning up orphaned NIC: $NicName"
        
        # Check if NIC is attached to any VM (safety check)
        $nicDetails = az network nic show -g $ResourceGroup -n $NicName -o json 2>$null | ConvertFrom-Json
        if ($nicDetails.virtualMachine) {
            Log-Info "NIC '$NicName' is attached to VM $($nicDetails.virtualMachine.id). Cannot delete."
            return
        }
        
        # Delete the NIC asynchronously
        az network nic delete -g $ResourceGroup -n $NicName --no-wait 2>$null
        
        # Wait for deletion confirmation (max 30 seconds)
        $maxWait = 30
        $waited = 0
        while ((az network nic show -g $ResourceGroup -n $NicName 2>$null) -and ($waited -lt $maxWait)) {
            Start-Sleep -Seconds 2
            $waited += 2
        }
        
        if ($waited -lt $maxWait) {
            Log-Info "✅ Successfully deleted orphaned NIC: $NicName"
        } else {
            Log-Info "⚠️ NIC deletion timeout for: $NicName (deletion may still be in progress)"
        }
    } catch {
        Log-Error "Failed to delete orphaned NIC '$NicName': $_"
    }
}

function Test-NicConnectivity {
    param(
        [Parameter(Mandatory=$true)]
        [string]$SubnetId,
        
        [Parameter(Mandatory=$true)]
        [string]$NsgId
    )
    
    # Validate subnet exists and is accessible
    $subnet = az network vnet subnet show --ids $SubnetId -o json 2>$null
    if (-not $subnet) {
        Log-Error "Subnet validation failed. Subnet ID: $SubnetId not found or inaccessible."
        return $false
    }
    
    # Validate NSG exists
    $nsg = az network nsg show --ids $NsgId -o json 2>$null
    if (-not $nsg) {
        Log-Error "NSG validation failed. NSG ID: $NsgId not found or inaccessible."
        return $false
    }
    
    return $true
}

function Invoke-AzCommand {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Command,
        
        [Parameter(Mandatory=$false)]
        [string]$ErrorMessage = "Azure CLI command failed"
    )
    
    $output = Invoke-Expression $Command 2>&1
    $exitCode = $LASTEXITCODE
    
    # Check for errors in output or exit code
    $hasError = ($exitCode -ne 0) -or ($output -match "ERROR|Error|error" -and $output -notmatch "No error")
    
    if ($hasError) {
        Log-Error "$ErrorMessage : $output"
        return $null
    }
    
    return $output
}

#endregion

# Hardcoded SKUs following Azure best practices
$snapshotSku = "Standard_LRS"      # Cost-optimized for temporary snapshots
$targetDiskSku = "StandardSSD_LRS" # Balanced performance for cloned VMs

"=" * 80 | Tee-Object -FilePath $LogFile -Append
Log-Info "Starting VM Cloning Process"
Log-Info "Target Environment: $TargetEnvironment"
Log-Info "Target Snapshot SKU: $snapshotSku | Target Disk SKU: $targetDiskSku"
Log-Info "Log File: $LogFile"
"=" * 80 | Tee-Object -FilePath $LogFile -Append

# Import and validate CSV
try {
    $vmList = Import-Csv -Path $CsvPath
    Log-Info "Imported $($vmList.Count) VM definition(s) from CSV"
    
    Test-CsvData -VmList $vmList
} catch {
    Log-Error "Failed to import or validate CSV: $_"
    exit 1
}

# Process each VM sequentially
foreach ($vm in $vmList) {
    $nicCreatedInThisRun = $false
    $nicName = "$($vm.NewVMName)-nic"
    $nicId = $null
    $privateIp = $null
    $snapshotsToCleanup = @()
    
    try {
        "=" * 80 | Tee-Object -FilePath $LogFile -Append
        Log-Info "Starting clone: $($vm.SourceVMName) -> $($vm.NewVMName)"
        
        # Parse CSV values
        $staticIp = if ($vm.StaticIp -and $vm.StaticIp.Trim() -ne "") { $vm.StaticIp.Trim() } else { $null }
        $subnetName = if ($vm.SubnetName -and $vm.SubnetName.Trim() -ne "") { $vm.SubnetName.Trim() } else { $null }
        
        if (-not $subnetName) {
            Log-Error "SubnetName is required for VM $($vm.NewVMName) but not provided in CSV"
            continue
        }
        
        Log-Info "VM: $($vm.NewVMName) | Subnet: $subnetName | Static IP: $(if($staticIp){"$staticIp"}else{"Dynamic"})"

        #region Source VM Discovery
        
        az account set --subscription $SourceSubscription
        
        # Get OS type
        $osType = az vm show -g $SourceResourceGroup -n $vm.SourceVMName --query storageProfile.osDisk.osType -o tsv 2>$null
        if (-not $osType) {
            Log-Error "Failed to get OS type for source VM: $($vm.SourceVMName). VM may not exist."
            continue
        }
        Log-Info "Detected OS type: $osType"

        # Get disk IDs
        $osDiskId = az vm show -g $SourceResourceGroup -n $vm.SourceVMName --query "storageProfile.osDisk.managedDisk.id" -o tsv 2>$null
        if (-not $osDiskId) {
            Log-Error "Failed to get OS disk ID for source VM: $($vm.SourceVMName)"
            continue
        }
        
        $dataDiskIds = @(az vm show -g $SourceResourceGroup -n $vm.SourceVMName --query "storageProfile.dataDisks[].managedDisk.id" -o tsv 2>$null)
        Log-Info "Source VM has OS disk + $($dataDiskIds.Count) data disk(s)"

        #endregion

        #region Target Environment Validation
        
        az account set --subscription $TargetSubscription
        $location = az group show -n $TargetResourceGroup --query location -o tsv 2>$null
        if (-not $location) {
            Log-Error "Target resource group '$TargetResourceGroup' not found"
            continue
        }

        # Validate boot diagnostics storage
        $storageExists = az storage account show --name $BootDiagStorage -o json 2>$null
        if (-not $storageExists) {
            Log-Error "Boot diagnostics storage account '$BootDiagStorage' not found in target subscription"
            continue
        }

        # Tags for governance
        $clonedDate = Get-Date -Format 'yyyy-MM-dd'
        $tags = "Environment=$TargetEnvironment SourceVM=$($vm.SourceVMName) ClonedDate=$clonedDate ClonedBy=AzureDevOps ManagedBy=CloudOps"

        #endregion

        #region Clone OS Disk
        
        $osDiskName = "$($vm.NewVMName)-osdisk"
        $existingOsDisk = az disk show -g $TargetResourceGroup -n $osDiskName -o json 2>$null
        
        if ($existingOsDisk) {
            Log-Info "⚠️ OS disk '$osDiskName' already exists. Reusing existing disk (idempotency)."
            $osDiskIdNew = az disk show -g $TargetResourceGroup -n $osDiskName --query id -o tsv
        } else {
            # Check for existing snapshot
            $existingOsSnap = az snapshot list -g $TargetResourceGroup --query "[?starts_with(name, '$($vm.NewVMName)-os-snap')].{Name:name, Id:id}" -o json 2>$null | ConvertFrom-Json
            
            if ($existingOsSnap -and $existingOsSnap.Count -gt 0) {
                Log-Info "⚠️ Found existing OS snapshot: $($existingOsSnap[0].Name). Reusing for disk creation."
                $osSnapId = $existingOsSnap[0].Id
            } else {
                # Create new snapshot
                $osSnap = "$($vm.NewVMName)-os-snap-$(Get-Date -Format 'yyyyMMddHHmmss')"
                $osSnapId = az snapshot create -g $TargetResourceGroup -n $osSnap --source $osDiskId --location $location --sku $snapshotSku --tags $tags --query id -o tsv 2>$null
                
                if (-not $osSnapId) {
                    Log-Error "OS snapshot creation failed for $($vm.NewVMName)"
                    continue
                }
                Log-Info "Created OS snapshot: $osSnap"
                $snapshotsToCleanup += $osSnapId
            }
            
            # Create disk from snapshot
            $osDiskIdNew = az disk create -g $TargetResourceGroup -n $osDiskName --source $osSnapId --location $location --sku $targetDiskSku --tags $tags --query id -o tsv 2>$null
            
            if (-not $osDiskIdNew) {
                Log-Error "OS disk creation failed for $($vm.NewVMName)"
                
                # Cleanup snapshot if disk creation failed
                if ($osSnapId -and -not $existingOsSnap) {
                    az snapshot delete --ids $osSnapId --no-wait 2>$null
                }
                continue
            }
            Log-Info "✅ Created OS disk: $osDiskName (SKU: $targetDiskSku)"
        }

        #endregion

        #region Clone Data Disks
        
        $newDataDisks = @()
        $lun = 0
        
        if ($dataDiskIds -and $dataDiskIds[0] -ne "") {
            Log-Info "Processing $($dataDiskIds.Count) data disk(s)..."
            
            foreach ($dd in $dataDiskIds) {
                az account set --subscription $SourceSubscription
                $dataDiskSize = az disk show --ids $dd --query "diskSizeGb" -o tsv 2>$null
                az account set --subscription $TargetSubscription
                
                $dataDiskName = "$($vm.NewVMName)-data$lun-disk"
                $existingDataDisk = az disk show -g $TargetResourceGroup -n $dataDiskName -o json 2>$null
                
                if ($existingDataDisk) {
                    Log-Info "⚠️ Data disk '$dataDiskName' already exists. Reusing (idempotency)."
                    $dataDiskIdNew = az disk show -g $TargetResourceGroup -n $dataDiskName --query id -o tsv
                    $newDataDisks += [PSCustomObject]@{Id=$dataDiskIdNew; Lun=$lun}
                } else {
                    # Check for existing snapshot
                    $existingDataSnap = az snapshot list -g $TargetResourceGroup --query "[?starts_with(name, '$($vm.NewVMName)-data$lun-snap')].{Name:name, Id:id}" -o json 2>$null | ConvertFrom-Json
                    
                    if ($existingDataSnap -and $existingDataSnap.Count -gt 0) {
                        Log-Info "⚠️ Found existing data snapshot: $($existingDataSnap[0].Name)"
                        $dataSnapId = $existingDataSnap[0].Id
                    } else {
                        # Create new snapshot
                        $snapName = "$($vm.NewVMName)-data$lun-snap-$(Get-Date -Format 'yyyyMMddHHmmss')"
                        $dataSnapId = az snapshot create -g $TargetResourceGroup -n $snapName --source $dd --location $location --sku $snapshotSku --tags $tags --query id -o tsv 2>$null
                        
                        if (-not $dataSnapId) {
                            Log-Error "Data disk snapshot creation failed for LUN $lun"
                            $lun++
                            continue
                        }
                        Log-Info "Created data snapshot: $snapName"
                        $snapshotsToCleanup += $dataSnapId
                    }
                    
                    # Create disk from snapshot
                    $dataDiskIdNew = az disk create -g $TargetResourceGroup -n $dataDiskName --source $dataSnapId --location $location --sku $targetDiskSku --tags $tags --query id -o tsv 2>$null
                    
                    if (-not $dataDiskIdNew) {
                        Log-Error "Data disk creation failed for LUN $lun"
                        
                        # Cleanup snapshot if disk creation failed
                        if ($dataSnapId -and -not $existingDataSnap) {
                            az snapshot delete --ids $dataSnapId --no-wait 2>$null
                        }
                        $lun++
                        continue
                    }
                    
                    $newDataDisks += [PSCustomObject]@{Id=$dataDiskIdNew; Lun=$lun}
                    Log-Info "✅ Created data disk: $dataDiskName at LUN $lun (Size: $dataDiskSize GB)"
                }
                $lun++
            }
        }

        #endregion

        #region Network Infrastructure Validation and NIC Creation
        
        # Validate subnet
        $subnetId = az network vnet subnet show -g $VnetRg --vnet-name $VnetName -n $subnetName --query id -o tsv 2>$null
        if (-not $subnetId) {
            Log-Error "Subnet '$subnetName' not found in VNet '$VnetName' (RG: $VnetRg)"
            continue
        }
        Log-Info "✅ Validated subnet: $subnetName"
        
        # Validate NSG
        $nsgId = az network nsg show -g $NsgRg -n $NsgName --query id -o tsv 2>$null
        if (-not $nsgId) {
            Log-Error "NSG '$NsgName' not found in resource group '$NsgRg'"
            continue
        }
        Log-Info "✅ Validated NSG: $NsgName"

        # Test network connectivity
        if (-not (Test-NicConnectivity -SubnetId $subnetId -NsgId $nsgId)) {
            Log-Error "Network connectivity validation failed for subnet '$subnetName'"
            continue
        }

        # Check if NIC already exists
        $existingNic = az network nic show -g $TargetResourceGroup -n $nicName -o json 2>$null
        
        if ($existingNic) {
            Log-Info "⚠️ NIC '$nicName' already exists. Reusing existing NIC (idempotency)."
            $nicId = az network nic show -g $TargetResourceGroup -n $nicName --query id -o tsv
            $privateIp = az network nic show --ids $nicId --query "ipConfigurations[0].privateIpAddress" -o tsv
            $ipAllocation = az network nic show --ids $nicId --query "ipConfigurations[0].privateIpAllocationMethod" -o tsv
            Log-Info "Existing NIC | Name: $nicName | IP: $privateIp | Allocation: $ipAllocation"
            $nicCreatedInThisRun = $false
        } else {
            Log-Info "Creating new NIC: $nicName"
            
            if ($staticIp) {
                $subnetPrefix = az network vnet subnet show -g $VnetRg --vnet-name $VnetName -n $subnetName --query "addressPrefix" -o tsv
                Log-Info "Attempting static IP: $staticIp in subnet: $subnetPrefix"
                
                # Try static IP first
                $nicCreateOutput = az network nic create -g $TargetResourceGroup -n $nicName --subnet $subnetId --network-security-group $nsgId --private-ip-address $staticIp --tags $tags --query 'NewNIC.id' -o tsv 2>&1
                $createExitCode = $LASTEXITCODE
                
                # Check for errors
                $hasError = ($createExitCode -ne 0) -or ($nicCreateOutput -match "ERROR|Error|error" -and $nicCreateOutput -notmatch "No error")
                
                if ($hasError) {
                    Log-Error "Static IP $staticIp assignment failed: $nicCreateOutput"
                    Log-Info "Retrying NIC creation with dynamic IP allocation..."
                    
                    # Retry with dynamic IP
                    $nicId = az network nic create -g $TargetResourceGroup -n $nicName --subnet $subnetId --network-security-group $nsgId --tags $tags --query 'NewNIC.id' -o tsv 2>&1
                    $retryExitCode = $LASTEXITCODE
                    
                    if ($retryExitCode -ne 0 -or ($nicId -match "ERROR|Error|error")) {
                        Log-Error "NIC creation with dynamic IP also failed: $nicId"
                        continue
                    }
                } else {
                    $nicId = $nicCreateOutput
                }
            } else {
                Log-Info "Creating NIC with dynamic IP allocation"
                $nicId = az network nic create -g $TargetResourceGroup -n $nicName --subnet $subnetId --network-security-group $nsgId --tags $tags --query 'NewNIC.id' -o tsv 2>&1
                
                if ($LASTEXITCODE -ne 0 -or ($nicId -match "ERROR|Error|error")) {
                    Log-Error "NIC creation failed: $nicId"
                    continue
                }
            }
            
            if (-not $nicId -or $nicId.Trim() -eq "") {
                Log-Error "NIC creation returned empty ID"
                continue
            }
            
            $nicId = $nicId.Trim()
            $nicCreatedInThisRun = $true
            
            # Validate NIC creation
            $nicValidation = az network nic show --ids $nicId -o json 2>$null
            if (-not $nicValidation) {
                Log-Error "NIC creation succeeded but NIC not found in Azure"
                continue
            }
            
            $privateIp = az network nic show --ids $nicId --query "ipConfigurations[0].privateIpAddress" -o tsv
            $ipAllocation = az network nic show --ids $nicId --query "ipConfigurations[0].privateIpAllocationMethod" -o tsv
            Log-Info "✅ Created NIC successfully | Name: $nicName | IP: $privateIp | Allocation: $ipAllocation"
        }

        #endregion

        #region VM Creation and Data Disk Attachment
        
        $existingVm = az vm show -g $TargetResourceGroup -n $vm.NewVMName -o json 2>$null
        
        if ($existingVm) {
            Log-Info "⚠️ VM '$($vm.NewVMName)' already exists. Checking data disk configuration..."
            
            $attachedDisks = az vm show -g $TargetResourceGroup -n $vm.NewVMName --query "storageProfile.dataDisks[].name" -o tsv
            $attachedCount = if ($attachedDisks) { ($attachedDisks -split "`r?`n").Count } else { 0 }
            
            if ($newDataDisks.Count -gt $attachedCount) {
                Log-Info "Attaching $($newDataDisks.Count - $attachedCount) missing data disk(s)..."
                
                az vm deallocate -g $TargetResourceGroup -n $vm.NewVMName --no-wait
                az vm wait -g $TargetResourceGroup -n $vm.NewVMName --custom "instanceView.statuses[?code=='PowerState/deallocated']" --timeout 300
                
                foreach ($disk in $newDataDisks) {
                    $existingLun = az vm show -g $TargetResourceGroup -n $vm.NewVMName --query "storageProfile.dataDisks[?lun==$($disk.Lun)].lun" -o tsv
                    if (-not $existingLun) {
                        az vm disk attach -g $TargetResourceGroup --vm-name $vm.NewVMName --name $disk.Id --lun $disk.Lun 2>$null
                        if ($LASTEXITCODE -eq 0) {
                            Log-Info "Attached data disk at LUN $($disk.Lun)"
                        } else {
                            Log-Error "Failed to attach data disk at LUN $($disk.Lun)"
                        }
                    }
                }
                
                az vm start -g $TargetResourceGroup -n $vm.NewVMName --no-wait
                Log-Info "VM started after data disk attachment"
            } else {
                Log-Info "All data disks already attached. No changes needed."
            }
        } else {
            Log-Info "Creating VM: $($vm.NewVMName) | Size: $($vm.VMSize) | OS: $osType"
            
            $vmCreateResult = az vm create -g $TargetResourceGroup -n $vm.NewVMName --nics $nicId --attach-os-disk $osDiskIdNew --os-type $osType --size $vm.VMSize --boot-diagnostics-storage "https://$BootDiagStorage.blob.core.windows.net/" --tags $tags 2>&1
            $vmCreateExitCode = $LASTEXITCODE
            
            if ($vmCreateExitCode -ne 0 -or ($vmCreateResult -match "ERROR|Error|error")) {
                Log-Error "VM creation failed: $vmCreateResult"
                Remove-OrphanedNic -ResourceGroup $TargetResourceGroup -NicName $nicName -WasCreatedInThisRun $nicCreatedInThisRun
                continue
            }
            
            Log-Info "✅ VM created successfully"

            # Attach data disks
            if ($newDataDisks.Count -gt 0) {
                Log-Info "Attaching $($newDataDisks.Count) data disk(s) to new VM..."
                
                az vm deallocate -g $TargetResourceGroup -n $vm.NewVMName --no-wait
                az vm wait -g $TargetResourceGroup -n $vm.NewVMName --custom "instanceView.statuses[?code=='PowerState/deallocated']" --timeout 300
                
                foreach ($disk in $newDataDisks) {
                    $attachResult = az vm disk attach -g $TargetResourceGroup --vm-name $vm.NewVMName --name $disk.Id --lun $disk.Lun 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        Log-Error "Failed to attach data disk at LUN $($disk.Lun): $attachResult"
                    } else {
                        Log-Info "Attached data disk at LUN $($disk.Lun)"
                    }
                }
                
                az vm start -g $TargetResourceGroup -n $vm.NewVMName --no-wait
                Log-Info "VM started after data disk attachment"
            }
        }

        #endregion

        #region Cleanup Temporary Snapshots
        
        if ($snapshotsToCleanup.Count -gt 0) {
            Log-Info "Cleaning up $($snapshotsToCleanup.Count) temporary snapshot(s)..."
            foreach ($snapId in $snapshotsToCleanup) {
                az snapshot delete --ids $snapId --no-wait 2>$null
            }
        }

        #endregion

        Log-Info "✅ Clone completed successfully: $($vm.SourceVMName) -> $($vm.NewVMName) | IP: $privateIp"
        $global:SuccessCount++
        
    } catch {
        $errorMsg = $_.Exception.Message
        Log-Error "❌ Failed cloning $($vm.SourceVMName): $errorMsg"
        
        # Cleanup orphaned NIC on exception
        if ($nicName -and $nicCreatedInThisRun) {
            Remove-OrphanedNic -ResourceGroup $TargetResourceGroup -NicName $nicName -WasCreatedInThisRun $nicCreatedInThisRun
        }
    }
}

# Final summary
"=" * 80 | Tee-Object -FilePath $LogFile -Append
Log-Info "VM Cloning Process Completed"
Log-Info "Total VMs: $($vmList.Count) | Successful: $global:SuccessCount | Failed: $global:ErrorCount"
Log-Info "Detailed logs available at: $LogFile"
"=" * 80 | Tee-Object -FilePath $LogFile -Append

if ($global:ErrorCount -gt 0) {
    Write-Warning "⚠️ Process completed with $global:ErrorCount error(s)"
    exit 1
} else {
    Write-Host "✅ All VM cloning operations completed successfully"
    exit 0
}