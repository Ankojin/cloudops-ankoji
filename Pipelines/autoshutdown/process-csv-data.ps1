param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,
    
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,
    
    [Parameter(Mandatory = $true)]
    [string]$FunctionsPath
)

# Load functions
. $FunctionsPath

# Load CSV data
$rows = Get-Content $InputPath | ConvertFrom-Json

Write-Host "🔄 Processing CSV data into resource group configurations..."

# Group and process VMs by subscription and resource group
$resourceGroups = @{}
$skippedRows = @()

foreach ($row in $rows) {
    Write-Host "Processing CSV row: Subscription='$($row.Subscription)', ResourceGroup='$($row.ResourceGroupName)'"
    
    # Validate critical required fields only
    if ([string]::IsNullOrWhiteSpace($row.Subscription)) {
        Write-Warning "⚠️ Skipping row - Subscription is empty (this is required)"
        $skippedRows += "Row with empty Subscription"
        continue
    }
    
    if ([string]::IsNullOrWhiteSpace($row.ResourceGroupName)) {
        Write-Warning "⚠️ Skipping row - ResourceGroupName is empty (this is required)"
        $skippedRows += "Row with empty ResourceGroupName"
        continue
    }
    
    # Get subscription ID
    Write-Host "  🔍 Looking up subscription: '$($row.Subscription)'"
    $subscriptionId = Get-SubscriptionId -SubscriptionName $row.Subscription.Trim()
    if ($null -eq $subscriptionId) {
        Write-Warning "⚠️ Skipping $($row.ResourceGroupName) - Invalid subscription: '$($row.Subscription)'"
        $skippedRows += "$($row.Subscription)/$($row.ResourceGroupName) - Invalid subscription"
        continue
    }
    Write-Host "  ✅ Subscription ID resolved: $subscriptionId"
    
    # Create unique key for grouping
    $rgKey = "$($row.Subscription.Trim())|$($row.ResourceGroupName.Trim())"
    
    # Initialize resource group entry if not exists
    if (-not $resourceGroups.ContainsKey($rgKey)) {
        $resourceGroups[$rgKey] = @{
            subscription = $row.Subscription.Trim()
            subscription_id = $subscriptionId
            name = $row.ResourceGroupName.Trim()
            db_vms = @()
            app_vms = @()
            db_shutdown_times = @()
            app_shutdown_times = @()
        }
    }
    
    # Process DB VMs
    $dbVMsRaw = if ($row.PSObject.Properties.Name -contains 'DBVMs') { 
        if ($null -eq $row.DBVMs) { "" } else { $row.DBVMs.ToString().Trim() }
    } else { "" }
    
    $appVMsRaw = if ($row.PSObject.Properties.Name -contains 'AppVMs') { 
        if ($null -eq $row.AppVMs) { "" } else { $row.AppVMs.ToString().Trim() }
    } else { "" }
    
    # Process shutdown times
    $dbShutdownTime = if ($row.PSObject.Properties.Name -contains 'DBShutdownTime') { 
        if ($null -eq $row.DBShutdownTime) { "" } else { $row.DBShutdownTime.ToString().Trim() }
    } else { "" }
    
    $appShutdownTime = if ($row.PSObject.Properties.Name -contains 'AppShutdownTime') { 
        if ($null -eq $row.AppShutdownTime) { "" } else { $row.AppShutdownTime.ToString().Trim() }
    } else { "" }
    
    # Add VMs to the resource group
    if (-not [string]::IsNullOrWhiteSpace($dbVMsRaw)) {
        $dbVmList = Format-VMNames -vmNamesString $dbVMsRaw
        if (-not [string]::IsNullOrWhiteSpace($dbVmList)) {
            $resourceGroups[$rgKey].db_vms += $dbVmList -split ','
            $resourceGroups[$rgKey].db_shutdown_times += if ([string]::IsNullOrWhiteSpace($dbShutdownTime)) { "2000" } else { $dbShutdownTime }
        }
    }
    
    if (-not [string]::IsNullOrWhiteSpace($appVMsRaw)) {
        $appVmList = Format-VMNames -vmNamesString $appVMsRaw
        if (-not [string]::IsNullOrWhiteSpace($appVmList)) {
            $resourceGroups[$rgKey].app_vms += $appVmList -split ','
            $resourceGroups[$rgKey].app_shutdown_times += if ([string]::IsNullOrWhiteSpace($appShutdownTime)) { "2000" } else { $appShutdownTime }
        }
    }
    
    Write-Host "  ✅ Added to resource group: $rgKey"
}

# Convert to final configuration array
$config = @()
foreach ($rgKey in $resourceGroups.Keys) {
    $rg = $resourceGroups[$rgKey]
    
    # Get most common shutdown times (or use defaults)
    $dbShutdownTime = if ($rg.db_shutdown_times.Count -gt 0) { 
        ($rg.db_shutdown_times | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name 
    } else { "2000" }
    
    $appShutdownTime = if ($rg.app_shutdown_times.Count -gt 0) { 
        ($rg.app_shutdown_times | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name 
    } else { "2000" }
    
    # Remove duplicates and join VMs
    $uniqueDbVms = ($rg.db_vms | Sort-Object | Get-Unique) -join ','
    $uniqueAppVms = ($rg.app_vms | Sort-Object | Get-Unique) -join ','
    
    # Skip resource groups with no VMs at all
    if (-not $uniqueDbVms -and -not $uniqueAppVms) {
        Write-Warning "⚠️ Skipping resource group $($rg.subscription)/$($rg.name) - no VMs specified"
        Write-Host "  ℹ️ Resource groups must have at least one DB VM or App VM to configure auto-shutdown"
        continue
    }
    
    $config += @{
        subscription = $rg.subscription
        subscription_id = $rg.subscription_id
        name = $rg.name
        db_vms = $uniqueDbVms
        db_shutdown = $dbShutdownTime
        app_vms = $uniqueAppVms
        app_shutdown = $appShutdownTime
    }
    
    Write-Host "📦 Consolidated Resource Group: $($rg.subscription)/$($rg.name)"
    if ($uniqueDbVms) {
        Write-Host "  🗄️ DB VMs ($($rg.db_vms.Count)): $uniqueDbVms (Shutdown: $dbShutdownTime)"
    }
    if ($uniqueAppVms) {
        Write-Host "  📱 App VMs ($($rg.app_vms.Count)): $uniqueAppVms (Shutdown: $appShutdownTime)"
    }
}

if ($config.Count -eq 0) {
    Write-Warning "⚠️ No resource groups were processed from CSV!"
    Write-Host "This could be due to:"
    Write-Host "  - All rows having invalid subscription names"
    Write-Host "  - All rows missing required Subscription or ResourceGroupName values"
    Write-Host "  - CSV file format issues"
    if ($skippedRows.Count -gt 0) {
        Write-Host "`nSkipped rows:"
        foreach ($skipped in $skippedRows) {
            Write-Host "  ❌ $skipped"
        }
    }
    Write-Host "ℹ️ The pipeline will continue but no resources will be configured."
    exit 1
}

Write-Host "`n✅ Processed $($config.Count) unique resource group(s) from $($rows.Count) CSV rows"
if ($skippedRows.Count -gt 0) {
    Write-Host "⚠️ Skipped $($skippedRows.Count) row(s) due to issues"
}

# Group by subscription for summary
$groupedBySubscription = $config | Group-Object -Property subscription
foreach ($group in $groupedBySubscription) {
    Write-Host "  📦 $($group.Name): $($group.Count) resource group(s)"
}
Write-Host ""

# Save config for next step
$config | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputPath -Encoding UTF8
Write-Host "✅ Configuration saved for Terraform processing"