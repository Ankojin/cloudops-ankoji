<#
.SYNOPSIS
    Add tags to multiple VMs across different Azure subscriptions from CSV file.

.DESCRIPTION
    This script reads a CSV file containing VM information and applies tags to VMs
    across multiple Azure subscriptions with proper error handling and logging.

.PARAMETER CsvPath
    Path to the CSV file containing VM information

.PARAMETER TagsFilePath
    Path to JSON file containing tags to apply (optional)

.PARAMETER LogPath
    Path for the log file (optional)

.EXAMPLE
    .\Add-VMTags-MultiSub.ps1 -CsvPath ".\vm-list.csv"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,
    
    [Parameter(Mandatory = $false)]
    [string]$TagsFilePath,
    
    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\vm-tagging-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
)

# Function to write log messages
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Console output with colors
    switch ($Level) {
        'Info'    { Write-Host $logMessage -ForegroundColor Cyan }
        'Warning' { Write-Host $logMessage -ForegroundColor Yellow }
        'Error'   { Write-Host $logMessage -ForegroundColor Red }
        'Success' { Write-Host $logMessage -ForegroundColor Green }
    }
    
    # File output
    Add-Content -Path $LogPath -Value $logMessage
}

# Start script
Write-Log "Starting VM tagging process" -Level Info
Write-Log "Log file: $LogPath" -Level Info

# Check if CSV file exists
if (-not (Test-Path $CsvPath)) {
    Write-Log "CSV file not found: $CsvPath" -Level Error
    exit 1
}

# Connect to Azure
try {
    Write-Log "Connecting to Azure..." -Level Info
    $context = Get-AzContext
    
    if (-not $context) {
        Connect-AzAccount
        Write-Log "Successfully connected to Azure" -Level Success
    }
    else {
        Write-Log "Already connected to Azure as $($context.Account.Id)" -Level Info
    }
}
catch {
    Write-Log "Failed to connect to Azure: $_" -Level Error
    exit 1
}

# Import VM list from CSV
try {
    $vmList = Import-Csv -Path $CsvPath
    Write-Log "Imported $($vmList.Count) VMs from CSV" -Level Info
}
catch {
    Write-Log "Failed to import CSV: $_" -Level Error
    exit 1
}

# Load tags from JSON file or define here
if ($TagsFilePath -and (Test-Path $TagsFilePath)) {
    try {
        $tagsToAdd = Get-Content $TagsFilePath | ConvertFrom-Json -AsHashtable
        Write-Log "Loaded tags from $TagsFilePath" -Level Info
    }
    catch {
        Write-Log "Failed to load tags from JSON: $_" -Level Error
        exit 1
    }
}
else {
    # Default tags - modify as needed
    $tagsToAdd = @{
        "Company" = "ABIC"
        "Cost center"  = "ABIC IT"
        "UpdatedBy"   = $env:USERNAME
        "UpdatedDate" = (Get-Date -Format 'yyyy-MM-dd')
    }
    Write-Log "Using default tags" -Level Info
}

# Display tags to be applied
Write-Log "Tags to be applied:" -Level Info
$tagsToAdd.GetEnumerator() | ForEach-Object {
    Write-Log "  $($_.Key): $($_.Value)" -Level Info
}

# Summary variables
$successCount = 0
$failureCount = 0
$skippedCount = 0

# Get unique subscriptions
$subscriptions = $vmList | Select-Object -Property SubscriptionId -Unique

Write-Log "`nProcessing VMs across $($subscriptions.Count) subscription(s)" -Level Info

# Process each VM
foreach ($vmEntry in $vmList) {
    $vmName = $vmEntry.VMName
    $resourceGroup = $vmEntry.ResourceGroupName
    $subscriptionId = $vmEntry.SubscriptionId
    
    Write-Log "`n----------------------------------------" -Level Info
    Write-Log "Processing VM: $vmName" -Level Info
    Write-Log "Resource Group: $resourceGroup" -Level Info
    Write-Log "Subscription: $subscriptionId" -Level Info
    
    try {
        # Switch to the correct subscription
        $currentContext = Get-AzContext
        if ($currentContext.Subscription.Id -ne $subscriptionId) {
            Write-Log "Switching to subscription: $subscriptionId" -Level Info
            Set-AzContext -SubscriptionId $subscriptionId | Out-Null
        }
        
        # Get the VM
        Write-Log "Retrieving VM details..." -Level Info
        $azureVM = Get-AzVM -ResourceGroupName $resourceGroup -Name $vmName -ErrorAction Stop
        
        if ($azureVM) {
            # Get existing tags
            $existingTags = if ($azureVM.Tags) { $azureVM.Tags } else { @{} }
            
            Write-Log "Existing tags: $($existingTags.Count)" -Level Info
            
            # Update tags using Update-AzTag (merge operation)
            Write-Log "Applying tags..." -Level Info
            Update-AzTag -ResourceId $azureVM.Id -Tag $tagsToAdd -Operation Merge | Out-Null
            
            Write-Log "✓ Successfully tagged VM: $vmName" -Level Success
            $successCount++
        }
        else {
            Write-Log "✗ VM not found: $vmName" -Level Warning
            $skippedCount++
        }
    }
    catch {
        Write-Log "✗ Error processing VM $vmName : $($_.Exception.Message)" -Level Error
        $failureCount++
    }
}

# Summary report
Write-Log "`n========================================" -Level Info
Write-Log "TAGGING SUMMARY" -Level Info
Write-Log "========================================" -Level Info
Write-Log "Total VMs processed: $($vmList.Count)" -Level Info
Write-Log "Successfully tagged: $successCount" -Level Success
Write-Log "Failed: $failureCount" -Level $(if ($failureCount -gt 0) { 'Error' } else { 'Info' })
Write-Log "Skipped: $skippedCount" -Level $(if ($skippedCount -gt 0) { 'Warning' } else { 'Info' })
Write-Log "========================================" -Level Info
Write-Log "Log file saved: $LogPath" -Level Info