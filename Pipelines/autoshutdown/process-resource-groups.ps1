param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,
    
    [Parameter(Mandatory = $true)]
    [string]$FunctionsPath,
    
    [Parameter(Mandatory = $true)]
    [string]$TimeZone
)

# Load functions
Write-Host "Loading helper functions from: $FunctionsPath"
. $FunctionsPath

# Load configuration
Write-Host "Loading configuration from: $ConfigPath"
$config = Get-Content $ConfigPath | ConvertFrom-Json

Write-Host "========================================="
Write-Host "[INFO] Processing $($config.Count) Resource Group(s)"
Write-Host "Time Zone: $TimeZone"
Write-Host "=========================================`n"

$totalErrors = 0
$processedCount = 0

foreach ($rg in $config) {
    $processedCount++
    Write-Host "[$processedCount/$($config.Count)] Processing: $($rg.subscription)/$($rg.name)"
    Write-Host "=================================================="
    
    try {
        # Set up state file path
        $stateBaseDir = "C:\TerraformState\autoshutdown"
        $stateFileName = "$($rg.subscription)-$($rg.name).tfstate"
        $stateFilePath = "$stateBaseDir\$stateFileName"
        
        Write-Host "[FILE] State file: $stateFilePath"
        
        # Create working directory for this resource group
        $workingDir = "$(Agent.TempDirectory)\terraform-$($rg.subscription)-$($rg.name)"
        if (Test-Path $workingDir) {
            Remove-Item $workingDir -Recurse -Force
        }
        New-Item -ItemType Directory -Path $workingDir -Force | Out-Null
        Write-Host "[DIR] Working directory: $workingDir"
        
        # Set Azure subscription
        Write-Host "[INFO] Setting Azure subscription to: $($rg.subscription_id)"
        az account set --subscription $rg.subscription_id
        if ($LASTEXITCODE -ne 0) {
            Write-Error "[ERROR] Failed to set Azure subscription"
            $totalErrors++
            continue
        }
        
        # Create Terraform configuration for this resource group
        $terraformConfig = @"
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.0"
    }
  }
  backend "local" {
    path = "$($stateFilePath.Replace('\', '/'))"
  }
}

provider "azurerm" {
  features {}
}
"@

        # Add DB VMs auto-shutdown if specified
        if (-not [string]::IsNullOrWhiteSpace($rg.db_vms)) {
            $dbVmIds = $rg.db_vms -split ',' | ForEach-Object { 
                $vmName = $_.Trim()
                '"/subscriptions/' + $rg.subscription_id + '/resourceGroups/' + $rg.name + '/providers/Microsoft.Compute/virtualMachines/' + $vmName + '"'
            }
            $dbVmIdsString = "    " + ($dbVmIds -join ",`n    ")
            
            $terraformConfig += @"

resource "azurerm_dev_test_global_vm_shutdown_schedule" "db_shutdown" {
  virtual_machine_id    = "/subscriptions/$($rg.subscription_id)/resourceGroups/$($rg.name)/providers/Microsoft.Compute/virtualMachines/*"
  location              = "centralus"  # This doesn't matter for global schedules
  enabled               = true

  daily_recurrence_time = "$($rg.db_shutdown)"
  timezone              = "$TimeZone"

  notification_settings {
    enabled = false
  }

  target_resource_ids = [
$dbVmIdsString
  ]
}
"@
        }

        # Add App VMs auto-shutdown if specified
        if (-not [string]::IsNullOrWhiteSpace($rg.app_vms)) {
            $appVmIds = $rg.app_vms -split ',' | ForEach-Object { 
                $vmName = $_.Trim()
                '"/subscriptions/' + $rg.subscription_id + '/resourceGroups/' + $rg.name + '/providers/Microsoft.Compute/virtualMachines/' + $vmName + '"'
            }
            $appVmIdsString = "    " + ($appVmIds -join ",`n    ")
            
            $terraformConfig += @"

resource "azurerm_dev_test_global_vm_shutdown_schedule" "app_shutdown" {
  virtual_machine_id    = "/subscriptions/$($rg.subscription_id)/resourceGroups/$($rg.name)/providers/Microsoft.Compute/virtualMachines/*"
  location              = "centralus"  # This doesn't matter for global schedules
  enabled               = true

  daily_recurrence_time = "$($rg.app_shutdown)"
  timezone              = "$TimeZone"

  notification_settings {
    enabled = false
  }

  target_resource_ids = [
$appVmIdsString
  ]
}
"@
        }

        # Write Terraform configuration
        $terraformConfigPath = Join-Path $workingDir "main.tf"
        $terraformConfig | Out-File -FilePath $terraformConfigPath -Encoding UTF8
        Write-Host "[SUCCESS] Terraform config created: $terraformConfigPath"
        
        # Change to working directory
        Push-Location $workingDir
        
        try {
            # Initialize Terraform
            Write-Host "[INFO] Initializing Terraform..."
            $initOutput = terraform init -no-color 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Error "[ERROR] Terraform init failed:`n$initOutput"
                $totalErrors++
                continue
            }
            Write-Host "[SUCCESS] Terraform initialized successfully"
            
            # Import existing schedules if they exist
            Write-Host "[INFO] Checking for existing auto-shutdown schedules..."
            
            $allVMs = @()
            if (-not [string]::IsNullOrWhiteSpace($rg.db_vms)) {
                $allVMs += $rg.db_vms -split ','
            }
            if (-not [string]::IsNullOrWhiteSpace($rg.app_vms)) {
                $allVMs += $rg.app_vms -split ','
            }
            
            foreach ($vmName in $allVMs) {
                $vmName = $vmName.Trim()
                if ([string]::IsNullOrWhiteSpace($vmName)) { continue }
                
                Write-Host "  [INFO] Checking VM: $vmName"
                
                # Check if auto-shutdown schedule exists for this VM
                $scheduleResourceId = "/subscriptions/$($rg.subscription_id)/resourceGroups/$($rg.name)/providers/Microsoft.DevTestLab/schedules/shutdown-computevm-$vmName"
                
                $scheduleExists = $false
                try {
                    $scheduleInfo = az resource show --ids $scheduleResourceId --output json 2>$null
                    if ($LASTEXITCODE -eq 0 -and $scheduleInfo) {
                        $schedule = $scheduleInfo | ConvertFrom-Json
                        $scheduleExists = $true
                        Write-Host "    [SUCCESS] Found existing schedule for $vmName"
                        Write-Host "    [INFO] Status: $($schedule.properties.status)"
                        Write-Host "    [TIME] Time: $($schedule.properties.dailyRecurrence.time)"
                        Write-Host "    [TIMEZONE] Timezone: $($schedule.properties.timeZoneId)"
                    }
                }
                catch {
                    # Schedule doesn't exist, which is fine
                }
                
                if ($scheduleExists) {
                    # Determine which Terraform resource this VM belongs to
                    $resourceName = ""
                    if ($rg.db_vms -and $rg.db_vms.Split(',').Trim() -contains $vmName) {
                        $resourceName = "db_shutdown"
                    } elseif ($rg.app_vms -and $rg.app_vms.Split(',').Trim() -contains $vmName) {
                        $resourceName = "app_shutdown"
                    }
                    
                    if ($resourceName) {
                        Write-Host "    [INFO] Importing existing schedule into Terraform as: azurerm_dev_test_global_vm_shutdown_schedule.$resourceName"
                        
                        $importOutput = terraform import "azurerm_dev_test_global_vm_shutdown_schedule.$resourceName" $scheduleResourceId 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "    [SUCCESS] Import successful"
                        } else {
                            Write-Warning "    [WARNING] Import failed (continuing anyway): $importOutput"
                        }
                    }
                }
            }
            
            # Plan Terraform changes
            Write-Host "[INFO] Planning Terraform changes..."
            $planOutput = terraform plan -out="terraform.tfplan" -no-color 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Error "[ERROR] Terraform plan failed:`n$planOutput"
                $totalErrors++
                continue
            }
            
            # Show plan output
            Write-Host "[INFO] Terraform Plan Output:"
            Write-Host $planOutput
            
            # Apply Terraform changes
            Write-Host "[INFO] Applying Terraform changes..."
            $applyOutput = terraform apply -auto-approve "terraform.tfplan" -no-color 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Error "[ERROR] Terraform apply failed:`n$applyOutput"
                $totalErrors++
                continue
            }
            
            Write-Host "[SUCCESS] Terraform apply completed successfully"
            Write-Host $applyOutput
            
            # Verify state file was created/updated
            if (Test-Path $stateFilePath) {
                $stateFileSize = (Get-Item $stateFilePath).Length
                Write-Host "[SUCCESS] State file saved: $stateFilePath ($($stateFileSize) bytes)"
            } else {
                Write-Warning "[WARNING] State file not found at expected location: $stateFilePath"
            }
            
            Write-Host "[SUCCESS] Resource group $($rg.subscription)/$($rg.name) configured successfully`n"
            
        }
        finally {
            Pop-Location
        }
        
    }
    catch {
        Write-Error "[ERROR] Failed to process resource group $($rg.subscription)/$($rg.name): $_"
        $totalErrors++
    }
}

Write-Host "========================================="
Write-Host "[SUMMARY] Processing Summary"
Write-Host "========================================="
Write-Host "[SUCCESS] Total Resource Groups: $($config.Count)"
Write-Host "[SUCCESS] Successfully Processed: $($config.Count - $totalErrors)"
if ($totalErrors -gt 0) {
    Write-Host "[ERROR] Failed: $totalErrors"
    Write-Host ""
    Write-Warning "Some resource groups failed to process. Check the logs above for details."
    exit 1
} else {
    Write-Host "[SUCCESS] Failed: 0"
    Write-Host ""
    Write-Host "[SUCCESS] All resource groups processed successfully!"
    Write-Host "State files are saved in: C:\TerraformState\autoshutdown\"
}

