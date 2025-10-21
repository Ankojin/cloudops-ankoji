param(
    [Parameter(Mandatory=$true)][string]$SubscriptionName,
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
Write-Host "Setting context to subscription: $SubscriptionName"
az account set --subscription "$SubscriptionName" --only-show-errors

# Get subscription ID dynamically
$SubscriptionId = az account show --query "id" -o tsv
Write-Host "Resolved Subscription ID: $SubscriptionId"

# Build full VM Resource IDs
$vmArray = @()
foreach ($vm in $VMNames -split ',') {
    $vmArray += "/subscriptions/$SubscriptionId/resourceGroups/$VMResourceGroup/providers/Microsoft.Compute/virtualMachines/$($_.Trim())"
}

# Print VM IDs for verification
Write-Host "VMs to be included in Logic App:"
$vmArray | ForEach-Object { Write-Host " - $_" }

# Load Logic App JSON
$definition = Get-Content $DefinitionFile -Raw | ConvertFrom-Json

# Update start/stop schedules
$definition.definition.triggers.StartTrigger.recurrence.schedule.hours = @("$StartHour")
$definition.definition.triggers.StartTrigger.recurrence.schedule.minutes = @($StartMinute)
$definition.definition.triggers.StopTrigger.recurrence.schedule.hours = @("$StopHour")
$definition.definition.triggers.StopTrigger.recurrence.schedule.minutes = @($StopMinute)

# Inject VM lists
$definition.definition.actions.StartFunction.actions.Scheduled.inputs.body.RequestScopes.VMLists = $vmArray
$definition.definition.actions.StopFunction.actions.Scheduled.inputs.body.RequestScopes.VMLists = $vmArray

# Save temporary JSON file
$tempFile = "temp-$($LogicAppName).json"
$definition | ConvertTo-Json -Depth 100 | Out-File $tempFile -Encoding utf8
Write-Host "Temporary Logic App definition saved to: $tempFile"

# Deploy Logic App
Write-Host "Deploying Logic App '$LogicAppName' in resource group '$ResourceGroupName'..."
az logic workflow create `
  --name $LogicAppName `
  --resource-group $ResourceGroupName `
  --location $Location `
  --definition @$tempFile `
  --subscription $SubscriptionId `
  --only-show-errors `
  --output none

Write-Host "✅ Logic App '$LogicAppName' deployed successfully."