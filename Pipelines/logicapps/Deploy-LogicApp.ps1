param(
    [Parameter(Mandatory=$true)][string]$SubscriptionId,
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$LogicAppName,
    [Parameter(Mandatory=$true)][string]$Location,
    [Parameter(Mandatory=$true)][string]$DefinitionFile,
    [Parameter(Mandatory=$true)][string]$VMResourceGroup,
    [Parameter(Mandatory=$true)][string]$VMNames,
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

# Build full VM Resource IDs - Fixed the bug here
$vmArray = @()
$vmList = $VMNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

foreach ($vm in $vmList) {
    $vmResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$VMResourceGroup/providers/Microsoft.Compute/virtualMachines/$vm"
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
$definition.definition.triggers.StartTrigger.recurrence.schedule.hours = @($StartHour)
$definition.definition.triggers.StartTrigger.recurrence.schedule.minutes = @($StartMinute)
$definition.definition.triggers.StopTrigger.recurrence.schedule.hours = @($StopHour)
$definition.definition.triggers.StopTrigger.recurrence.schedule.minutes = @($StopMinute)

# Inject VM lists
$definition.definition.actions.StartFunction.actions.Scheduled.inputs.body.RequestScopes.VMLists = $vmArray
$definition.definition.actions.StopFunction.actions.Scheduled.inputs.body.RequestScopes.VMLists = $vmArray

# Save temporary JSON file
$tempFile = Join-Path $env:TEMP "temp-$($LogicAppName).json"
try {
    $definition | ConvertTo-Json -Depth 100 | Out-File $tempFile -Encoding utf8
    Write-Host "Temporary Logic App definition saved to: $tempFile"
} catch {
    Write-Error "Failed to create temporary file: $_"
    exit 1
}

# Deploy Logic App
Write-Host "Deploying Logic App '$LogicAppName' in resource group '$ResourceGroupName'..."
$deployResult = az logic workflow create `
  --name $LogicAppName `
  --resource-group $ResourceGroupName `
  --location $Location `
  --definition "@$tempFile" `
  --subscription $SubscriptionId `
  --only-show-errors 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to deploy Logic App: $deployResult"
    # Clean up temp file
    if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
    exit 1
}

# Clean up temp file
if (Test-Path $tempFile) { 
    Remove-Item $tempFile -Force 
    Write-Host "Cleaned up temporary file"
}

Write-Host "✅ Logic App '$LogicAppName' deployed successfully."