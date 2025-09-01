      function Write-Log($Message) {
        "[$(Get-Date -Format o)] $Message" | Tee-Object -FilePath $LogFile -Append
      }

      $LogFile = "C:\log\snapshot_log.txt"
      # No need to re-create directory or clear log here

      Write-Log "Starting snapshot process..."

      $ResourceGroup = '${{ parameters.resourceGroupName }}'
      if (-not $ResourceGroup) {
        Write-Log "❌ Resource group name is required."
        exit 1
      }

      $ExcludedVMs = '${{ parameters.excludedVMNames }}'
      $Date = Get-Date -Format "yyyyMMdd-HHmmss"
      $SnapshotPrefix = "snapshot"

      $Excludes = @()
      if ($ExcludedVMs -and $ExcludedVMs.ToLower() -ne "none") {
        $Excludes = $ExcludedVMs -split ',' | ForEach-Object { $_.Trim() }
      }

      $VMs = az vm list --resource-group $ResourceGroup --query "[].name" -o tsv | ForEach-Object { $_.Trim() }
      if (-not $VMs) {
        Write-Log "No VMs found in resource group $ResourceGroup."
        exit 0
      }

      foreach ($VM in $VMs) {
        try {
          if ($Excludes -contains $VM) {
            Write-Log "Skipping excluded VM: $VM"
            continue
          }

          Write-Log "Processing VM: $VM"
          $vmInfo = az vm show -g $ResourceGroup -n $VM | ConvertFrom-Json

          # OS Disk
          $osDiskId = $vmInfo.storageProfile.osDisk.managedDisk.id
          $osDisk = az disk show --ids $osDiskId | ConvertFrom-Json
          $location = $osDisk.location
          $osSnapshotName = "$SnapshotPrefix-$VM-os-$Date"
          az snapshot create -g $ResourceGroup -n $osSnapshotName --source $osDiskId --location $location --sku Standard_LRS | Tee-Object -FilePath $LogFile -Append

          # Data Disks
          $dataDisks = $vmInfo.storageProfile.dataDisks
          if ($dataDisks) {
            foreach ($disk in $dataDisks) {
              $dataDiskId = $disk.managedDisk.id
              $lun = $disk.lun
              $dataDisk = az disk show --ids $dataDiskId | ConvertFrom-Json
              $location = $dataDisk.location
              $dataSnapshotName = "$SnapshotPrefix-$VM-data$lun-$Date"
              az snapshot create -g $ResourceGroup -n $dataSnapshotName --source $dataDiskId --location $location --sku Standard_LRS | Tee-Object -FilePath $LogFile -Append
            }
          }

          Write-Log "Finished VM: $VM"
        } catch {
          $errMsg = $_.Exception.Message
          Write-Log ("❌ Error processing VM " + $VM + ": " + $errMsg)
        }
      }
      Write-Log "🎉 Snapshot process completed."