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
        $workingDir = "$env:AGENT_TEMPDIRECTORY\terraform-$($rg.subscription)-$($rg.name)"
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
            Write-Host "[DEBUG] Processing DB VMs: $($rg.db_vms)"
            $dbVmNames = $rg.db_vms -split ',' | ForEach-Object { 
                $vmName = $_.Trim()
                if ([string]::IsNullOrWhiteSpace($vmName)) {
                    Write-Warning "[WARNING] Empty VM name found in DB VMs list"
                    return $null
                }
                Write-Host "[DEBUG] Found DB VM: $vmName"
                return $vmName
            } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            
            if ($dbVmNames.Count -eq 0) {
                Write-Warning "[WARNING] No valid DB VM names found"
            } else {
                foreach ($vmName in $dbVmNames) {
                    $terraformConfig += @"

resource "azurerm_dev_test_global_vm_shutdown_schedule" "db_shutdown_$($vmName.Replace('-', '_'))" {
  virtual_machine_id    = "/subscriptions/$($rg.subscription_id)/resourceGroups/$($rg.name)/providers/Microsoft.Compute/virtualMachines/$vmName"
  location              = "centralus"
  enabled               = true

  daily_recurrence_time = "$($rg.db_shutdown)"
  timezone              = "$TimeZone"

  notification_settings {
    enabled = false
  }
}
"@
                }
            }
        }

        # Add App VMs auto-shutdown if specified
        if (-not [string]::IsNullOrWhiteSpace($rg.app_vms)) {
            Write-Host "[DEBUG] Processing App VMs: $($rg.app_vms)"
            $appVmNames = $rg.app_vms -split ',' | ForEach-Object { 
                $vmName = $_.Trim()
                if ([string]::IsNullOrWhiteSpace($vmName)) {
                    Write-Warning "[WARNING] Empty VM name found in App VMs list"
                    return $null
                }
                Write-Host "[DEBUG] Found App VM: $vmName"
                return $vmName
            } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            
            if ($appVmNames.Count -eq 0) {
                Write-Warning "[WARNING] No valid App VM names found"
            } else {
                foreach ($vmName in $appVmNames) {
                    $terraformConfig += @"

resource "azurerm_dev_test_global_vm_shutdown_schedule" "app_shutdown_$($vmName.Replace('-', '_'))" {
  virtual_machine_id    = "/subscriptions/$($rg.subscription_id)/resourceGroups/$($rg.name)/providers/Microsoft.Compute/virtualMachines/$vmName"
  location              = "centralus"
  enabled               = true

  daily_recurrence_time = "$($rg.app_shutdown)"
  timezone              = "$TimeZone"

  notification_settings {
    enabled = false
  }
}
"@
                }
            }
        }

        # Write Terraform configuration
        $terraformConfigPath = Join-Path $workingDir "main.tf"
        $terraformConfig | Out-File -FilePath $terraformConfigPath -Encoding UTF8
        Write-Host "[SUCCESS] Terraform config created: $terraformConfigPath"
        
        # Show generated Terraform config for debugging
        Write-Host "[DEBUG] Generated Terraform configuration:"
        Write-Host "=================================================="
        Write-Host $terraformConfig
        Write-Host "=================================================="
        
        # Change to working directory
        Push-Location $workingDir
        
        try {
            # Initialize Terraform
            Write-Host "[INFO] Initializing Terraform..."
            try {
                # Set output encoding to handle Unicode characters from Terraform
                $originalOutputEncoding = [Console]::OutputEncoding
                [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
                
                Write-Host "[DEBUG] Executing Terraform init command..."
                
                # Execute init with proper error handling
                $initResult = Start-Process -FilePath "terraform" -ArgumentList @("init", "-no-color") -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\terraform_init_out.txt" -RedirectStandardError "$env:TEMP\terraform_init_err.txt"
                
                $initStdOut = ""
                $initStdErr = ""
                
                if (Test-Path "$env:TEMP\terraform_init_out.txt") {
                    $initStdOut = Get-Content "$env:TEMP\terraform_init_out.txt" -Raw -ErrorAction SilentlyContinue
                    Remove-Item "$env:TEMP\terraform_init_out.txt" -Force -ErrorAction SilentlyContinue
                }
                
                if (Test-Path "$env:TEMP\terraform_init_err.txt") {
                    $initStdErr = Get-Content "$env:TEMP\terraform_init_err.txt" -Raw -ErrorAction SilentlyContinue
                    Remove-Item "$env:TEMP\terraform_init_err.txt" -Force -ErrorAction SilentlyContinue
                }
                
                Write-Host "[DEBUG] Terraform init exit code: $($initResult.ExitCode)"
                
                if ($initResult.ExitCode -ne 0) {
                    Write-Host "[ERROR] Terraform init failed with exit code: $($initResult.ExitCode)"
                    if (-not [string]::IsNullOrWhiteSpace($initStdOut)) {
                        Write-Host "[ERROR] Terraform init stdout:"
                        Write-Host $initStdOut
                    }
                    if (-not [string]::IsNullOrWhiteSpace($initStdErr)) {
                        Write-Host "[ERROR] Terraform init stderr:"
                        Write-Host $initStdErr
                    }
                    Write-Error "[ERROR] Terraform init failed"
                    $totalErrors++
                    continue
                }
                
                Write-Host "[SUCCESS] Terraform initialized successfully"
                if (-not [string]::IsNullOrWhiteSpace($initStdOut)) {
                    Write-Host "[DEBUG] Terraform init output:"
                    Write-Host $initStdOut
                }
                
                # Restore original output encoding
                [Console]::OutputEncoding = $originalOutputEncoding
            }
            catch {
                # Restore original output encoding in case of exception
                if ($originalOutputEncoding) {
                    [Console]::OutputEncoding = $originalOutputEncoding
                }
                Write-Host "[ERROR] Exception during Terraform init: $($_.Exception.Message)"
                Write-Host "[ERROR] Exception type: $($_.Exception.GetType().FullName)"
                Write-Error "[ERROR] Terraform init failed with exception: $_"
                $totalErrors++
                continue
            }
            
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
                        $resourceName = "db_shutdown_$($vmName.Replace('-', '_'))"
                    } elseif ($rg.app_vms -and $rg.app_vms.Split(',').Trim() -contains $vmName) {
                        $resourceName = "app_shutdown_$($vmName.Replace('-', '_'))"
                    }
                    
                    if ($resourceName) {
                        Write-Host "    [INFO] Importing existing schedule into Terraform as: azurerm_dev_test_global_vm_shutdown_schedule.$resourceName"
                        
                        try {
                            # Set output encoding to handle Unicode characters from Terraform
                            $originalOutputEncoding = [Console]::OutputEncoding
                            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
                            
                            Write-Host "    [DEBUG] Executing Terraform import command..."
                            Write-Host "    [DEBUG] Resource: azurerm_dev_test_global_vm_shutdown_schedule.$resourceName"
                            Write-Host "    [DEBUG] Schedule Resource ID: $scheduleResourceId"
                            
                            # Execute import with proper error handling
                            $importResult = Start-Process -FilePath "terraform" -ArgumentList @("import", "azurerm_dev_test_global_vm_shutdown_schedule.$resourceName", $scheduleResourceId) -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\terraform_import_out.txt" -RedirectStandardError "$env:TEMP\terraform_import_err.txt"
                            
                            $importStdOut = ""
                            $importStdErr = ""
                            
                            if (Test-Path "$env:TEMP\terraform_import_out.txt") {
                                $importStdOut = Get-Content "$env:TEMP\terraform_import_out.txt" -Raw -ErrorAction SilentlyContinue
                                Remove-Item "$env:TEMP\terraform_import_out.txt" -Force -ErrorAction SilentlyContinue
                            }
                            
                            if (Test-Path "$env:TEMP\terraform_import_err.txt") {
                                $importStdErr = Get-Content "$env:TEMP\terraform_import_err.txt" -Raw -ErrorAction SilentlyContinue
                                Remove-Item "$env:TEMP\terraform_import_err.txt" -Force -ErrorAction SilentlyContinue
                            }
                            
                            Write-Host "    [DEBUG] Terraform import exit code: $($importResult.ExitCode)"
                            
                            if ($importResult.ExitCode -eq 0) {
                                Write-Host "    [SUCCESS] Import successful"
                                if (-not [string]::IsNullOrWhiteSpace($importStdOut)) {
                                    Write-Host "    [OUTPUT] $importStdOut"
                                }
                            } else {
                                Write-Warning "    [WARNING] Import failed (continuing anyway)"
                                Write-Host "    [ERROR] Exit code: $($importResult.ExitCode)"
                                if (-not [string]::IsNullOrWhiteSpace($importStdOut)) {
                                    Write-Host "    [STDOUT] $importStdOut"
                                }
                                if (-not [string]::IsNullOrWhiteSpace($importStdErr)) {
                                    Write-Host "    [STDERR] $importStdErr"
                                }
                            }
                        }
                        catch {
                            Write-Warning "    [WARNING] Import failed with exception (continuing anyway): $($_.Exception.Message)"
                            Write-Host "    [DEBUG] Exception type: $($_.Exception.GetType().FullName)"
                        }
                        finally {
                            # Restore original output encoding
                            if ($originalOutputEncoding) {
                                [Console]::OutputEncoding = $originalOutputEncoding
                            }
                        }
                    }
                }
            }
            
            # Plan Terraform changes
            Write-Host "[INFO] Planning Terraform changes..."
            try {
                # Set output encoding to handle Unicode characters from Terraform
                $originalOutputEncoding = [Console]::OutputEncoding
                [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
                
                Write-Host "[DEBUG] Executing Terraform plan command..."
                
                # Execute plan with proper error handling
                $planResult = Start-Process -FilePath "terraform" -ArgumentList @("plan", "-out=terraform.tfplan", "-no-color") -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\terraform_plan_out.txt" -RedirectStandardError "$env:TEMP\terraform_plan_err.txt"
                
                $planStdOut = ""
                $planStdErr = ""
                
                if (Test-Path "$env:TEMP\terraform_plan_out.txt") {
                    $planStdOut = Get-Content "$env:TEMP\terraform_plan_out.txt" -Raw -ErrorAction SilentlyContinue
                    Remove-Item "$env:TEMP\terraform_plan_out.txt" -Force -ErrorAction SilentlyContinue
                }
                
                if (Test-Path "$env:TEMP\terraform_plan_err.txt") {
                    $planStdErr = Get-Content "$env:TEMP\terraform_plan_err.txt" -Raw -ErrorAction SilentlyContinue
                    Remove-Item "$env:TEMP\terraform_plan_err.txt" -Force -ErrorAction SilentlyContinue
                }
                
                Write-Host "[DEBUG] Terraform plan exit code: $($planResult.ExitCode)"
                
                if ($planResult.ExitCode -ne 0) {
                    Write-Host "[ERROR] Terraform plan failed with exit code: $($planResult.ExitCode)"
                    if (-not [string]::IsNullOrWhiteSpace($planStdOut)) {
                        Write-Host "[ERROR] Terraform plan stdout:"
                        Write-Host $planStdOut
                    }
                    if (-not [string]::IsNullOrWhiteSpace($planStdErr)) {
                        Write-Host "[ERROR] Terraform plan stderr:"
                        Write-Host $planStdErr
                    }
                    Write-Error "[ERROR] Terraform plan failed"
                    $totalErrors++
                    continue
                }
                
                # Show plan output for debugging
                Write-Host "[INFO] Terraform Plan Output:"
                if (-not [string]::IsNullOrWhiteSpace($planStdOut)) {
                    Write-Host $planStdOut
                }
                
                # Restore original output encoding
                [Console]::OutputEncoding = $originalOutputEncoding
            }
            catch {
                # Restore original output encoding in case of exception
                if ($originalOutputEncoding) {
                    [Console]::OutputEncoding = $originalOutputEncoding
                }
                Write-Host "[ERROR] Exception during Terraform plan: $($_.Exception.Message)"
                Write-Host "[ERROR] Exception type: $($_.Exception.GetType().FullName)"
                Write-Host "[ERROR] Stack trace: $($_.ScriptStackTrace)"
                Write-Error "[ERROR] Terraform plan failed with exception: $_"
                $totalErrors++
                continue
            }
            
            # Apply Terraform changes
            Write-Host "[INFO] Applying Terraform changes..."
            try {
                # Set output encoding to handle Unicode characters from Terraform
                $originalOutputEncoding = [Console]::OutputEncoding
                [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
                
                Write-Host "[DEBUG] Executing Terraform apply command..."
                
                # Execute apply with proper error handling
                $applyResult = Start-Process -FilePath "terraform" -ArgumentList @("apply", "-auto-approve", "terraform.tfplan", "-no-color") -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\terraform_apply_out.txt" -RedirectStandardError "$env:TEMP\terraform_apply_err.txt"
                
                $applyStdOut = ""
                $applyStdErr = ""
                
                if (Test-Path "$env:TEMP\terraform_apply_out.txt") {
                    $applyStdOut = Get-Content "$env:TEMP\terraform_apply_out.txt" -Raw -ErrorAction SilentlyContinue
                    Remove-Item "$env:TEMP\terraform_apply_out.txt" -Force -ErrorAction SilentlyContinue
                }
                
                if (Test-Path "$env:TEMP\terraform_apply_err.txt") {
                    $applyStdErr = Get-Content "$env:TEMP\terraform_apply_err.txt" -Raw -ErrorAction SilentlyContinue
                    Remove-Item "$env:TEMP\terraform_apply_err.txt" -Force -ErrorAction SilentlyContinue
                }
                
                Write-Host "[DEBUG] Terraform apply exit code: $($applyResult.ExitCode)"
                
                if ($applyResult.ExitCode -ne 0) {
                    Write-Host "[ERROR] Terraform apply failed with exit code: $($applyResult.ExitCode)"
                    if (-not [string]::IsNullOrWhiteSpace($applyStdOut)) {
                        Write-Host "[ERROR] Terraform apply stdout:"
                        Write-Host $applyStdOut
                    }
                    if (-not [string]::IsNullOrWhiteSpace($applyStdErr)) {
                        Write-Host "[ERROR] Terraform apply stderr:"
                        Write-Host $applyStdErr
                    }
                    Write-Error "[ERROR] Terraform apply failed"
                    $totalErrors++
                    continue
                }
                
                Write-Host "[SUCCESS] Terraform apply completed successfully"
                if (-not [string]::IsNullOrWhiteSpace($applyStdOut)) {
                    Write-Host $applyStdOut
                }
                
                # Restore original output encoding
                [Console]::OutputEncoding = $originalOutputEncoding
            }
            catch {
                # Restore original output encoding in case of exception
                if ($originalOutputEncoding) {
                    [Console]::OutputEncoding = $originalOutputEncoding
                }
                Write-Host "[ERROR] Exception during Terraform apply: $($_.Exception.Message)"
                Write-Host "[ERROR] Exception type: $($_.Exception.GetType().FullName)"
                Write-Error "[ERROR] Terraform apply failed with exception: $_"
                $totalErrors++
                continue
            }
            
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
        Write-Host "[ERROR] Exception caught for resource group $($rg.subscription)/$($rg.name):"
        Write-Host "[ERROR] Exception message: $($_.Exception.Message)"
        Write-Host "[ERROR] Exception type: $($_.Exception.GetType().FullName)"
        Write-Host "[ERROR] Category info: $($_.CategoryInfo)"
        Write-Host "[ERROR] Full qualified error ID: $($_.FullyQualifiedErrorId)"
        if ($_.ScriptStackTrace) {
            Write-Host "[ERROR] Script stack trace: $($_.ScriptStackTrace)"
        }
        if ($_.InvocationInfo) {
            Write-Host "[ERROR] Script line: $($_.InvocationInfo.ScriptLineNumber)"
            Write-Host "[ERROR] Position: $($_.InvocationInfo.PositionMessage)"
        }
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

