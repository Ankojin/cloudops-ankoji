param(
    [Parameter(Mandatory=$true)][string]$SubscriptionId,
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$LogicAppName,
    # [Parameter(Mandatory=$false)][string]$Location,
    [Parameter(Mandatory=$true)][string]$DefinitionFile,
    [Parameter(Mandatory=$true)][string]$VMResourceGroup,
    [Parameter(Mandatory=$true)][string]$VMNames,
    [Parameter(Mandatory=$true)][string]$VMSubscriptionId, # <-- Add this line
    [int]$StartHour = 8,
    [int]$StartMinute = 0,
    [int]$StopHour = 19,
    [int]$StopMinute = 0
)

# Set Azure context
Write-Host "Setting context to subscription: $SubscriptionId"
$setContextResult = az account set --subscription "$SubscriptionId" --only-show-errors 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to set Azure context: $setContextResult"
    exit 1
}

# Get subscription ID dynamically
$SubscriptionId = az account show --query "id" -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($SubscriptionId)) {
    Write-Error "Failed to retrieve subscription ID"
    exit 1
}
Write-Host "Resolved Subscription ID: $SubscriptionId"

# Build full VM Resource IDs using VMSubscriptionId
$vmArray = @()
$vmList = $VMNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

foreach ($vm in $vmList) {
    $vmResourceId = "/subscriptions/$VMSubscriptionId/resourceGroups/$VMResourceGroup/providers/Microsoft.Compute/virtualMachines/$vm"
    $vmArray += $vmResourceId
}

# Validate we have VMs to process
if ($vmArray.Count -eq 0) {
    Write-Error "No valid VM names provided"
    exit 1
}

# Print VM IDs for verification
Write-Host "VMs to be included in Logic App:"
$vmArray | ForEach-Object { Write-Host " - $_" }

# Validate definition file exists
if (-not (Test-Path $DefinitionFile)) {
    Write-Error "Logic App definition file not found: $DefinitionFile"
    exit 1
}

# Load Logic App JSON
try {
    $definition = Get-Content $DefinitionFile -Raw | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse Logic App definition file: $_"
    exit 1
}

# Update start/stop schedules
$definition.definition.triggers.ScheduledStart.recurrence.schedule.hours = @($StartHour)
$definition.definition.triggers.ScheduledStart.recurrence.schedule.minutes = @($StartMinute)
$definition.definition.triggers.ScheduledStop.recurrence.schedule.hours = @($StopHour)
$definition.definition.triggers.ScheduledStop.recurrence.schedule.minutes = @($StopMinute)

# Inject VM lists
$definition.definition.actions.StartFunction.actions.Scheduled.inputs.body.RequestScopes.VMLists = $vmArray
$definition.definition.actions.StopFunction.actions.Scheduled.inputs.body.RequestScopes.VMLists = $vmArray

# Save the updated definition to a temp file
$tempDefFile = [System.IO.Path]::GetTempFileName().Replace('.tmp', "-$LogicAppName.json")
$definition | ConvertTo-Json -Depth 100 | Out-File -Encoding utf8 $tempDefFile
Write-Host "Temporary Logic App definition saved to: $tempDefFile"

# Deploy the Logic App using the temp file
Write-Host "Deploying Logic App '$LogicAppName' in resource group '$ResourceGroupName'..."
$deployResult = az logic workflow create `
    --resource-group "$ResourceGroupName" `
    --name "$LogicAppName" `
    --definition "@$tempDefFile" `
    --only-show-errors 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to deploy Logic App: $deployResult"
    exit 1
}

Write-Host "✅ Logic App '$LogicAppName' deployed successfully."