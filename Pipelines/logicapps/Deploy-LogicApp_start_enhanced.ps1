<#
Deploy Logic Apps for VM automation
Supports single deployment or bulk from CSV
TODO: Add stop functionality in future version
Author: CloudOps Team
#>

param(
    [string]$SubscriptionId,
    [string]$LogicAppResourceGroup,
    [string]$DeploymentMode = "Single", # Single or CSV
    [string]$VMSubscriptionId,
    [string]$WeekDays = "Sunday,Monday,Tuesday,Wednesday,Thursday",
    [string]$CsvFilePath,
    [string]$LogicAppName,
    [string]$DefinitionFile,
    [string]$VMResourceGroup,
    [string]$VMNames,
    [int]$StartHour = 7,
    [int]$StartMinute = 0,
    [string]$LogPath = ".\deployment-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
)

$ErrorActionPreference = "Stop"

function Log($msg, $level = "INFO") {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMsg = "[$timestamp] [$level] $msg"
    Write-Host $logMsg
    Add-Content -Path $LogPath -Value $logMsg -ErrorAction SilentlyContinue  # ignore log errors
}

function Deploy-LogicApp($name, $defFile, $vmRg, $vms, $hour, $min, $days) {
    Log "Deploying $name..."
    
    # Build VM resource IDs
    $vmArray = @()
    $vmList = $vms -split ',' | % { $_.Trim() }
    foreach ($vm in $vmList) {
        if($vm) {  # skip empty entries
            $vmArray += "/subscriptions/$VMSubscriptionId/resourceGroups/$vmRg/providers/Microsoft.Compute/virtualMachines/$vm"
        }
    }
    
    # Load JSON template
    $definition = Get-Content $defFile -Raw | ConvertFrom-Json
    
    # Update schedule 
    $weekDaysArray = $days -split ',' | % { $_.Trim() }
    $definition.definition.triggers.ScheduledStartTriggers.recurrence.schedule.hours = @($hour)
    $definition.definition.triggers.ScheduledStartTriggers.recurrence.schedule.minutes = @($min)
    $definition.definition.triggers.ScheduledStartTriggers.recurrence.schedule.weekDays = $weekDaysArray
    
    # Set VM list
    $definition.definition.actions.StartFunction.actions.ScheduledStartFunction.inputs.body.RequestScopes.VMLists = $vmArray
    
    # Deploy
    $tempFile = [System.IO.Path]::GetTempFileName() + ".json"
    $definition | ConvertTo-Json -Depth 50 | Out-File -Encoding utf8 $tempFile
    
    # TODO: add error handling for az cli
    az logic workflow create --resource-group "$LogicAppResourceGroup" --name "$name" --definition "@$tempFile" --only-show-errors
    
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    Log "Deployed $name successfully"
}

# Main logic
Log "Starting deployment - $DeploymentMode mode"

# Set context - assume user is already logged in
az account set --subscription "$SubscriptionId"

if ($DeploymentMode -eq "CSV") {
    # CSV mode - added this later for bulk operations
    if(!(Test-Path $CsvFilePath)) {
        Log "CSV file not found: $CsvFilePath" "ERROR"
        exit 1
    }
    
    $csvData = Import-Csv -Path $CsvFilePath
    $count = 0
    $errors = 0
    
    foreach ($row in $csvData) {
        $count++
        try {
            # basic validation
            if(!$row.LogicAppName -or !$row.VmNames) {
                Log "Skipping row $count - missing required fields" "WARN"
                continue
            }
            Deploy-LogicApp $row.LogicAppName $row.DefinitionFile $row.ResourceGroup $row.VmNames $row.StartHour $row.StartMinute $row.WeekDays
        } catch {
            $errors++
            Log "Failed to deploy $($row.LogicAppName): $_" "ERROR"
        }
    }
    
    Log "CSV deployment complete: $($count - $errors) successful, $errors failed"
} else {
    # Single mode - original functionality
    if(!$LogicAppName -or !$VMNames) {
        Log "Missing required parameters for single mode" "ERROR"
        exit 1
    }
    Deploy-LogicApp $LogicAppName $DefinitionFile $VMResourceGroup $VMNames $StartHour $StartMinute $WeekDays
    Log "Single deployment complete"
}

Log "Done"