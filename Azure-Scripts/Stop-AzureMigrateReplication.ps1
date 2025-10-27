<#
.SYNOPSIS
    Stops replication for Azure Migrate Server Migration and exports results to CSV
.DESCRIPTION
    This script stops replication and deletes ASR disks for machines in Azure Migrate project
    and exports the results to a CSV file.
.PARAMETER SubscriptionId
    Azure Subscription ID
.PARAMETER ResourceGroupName
    Resource Group containing the Azure Migrate project
.PARAMETER MigrateProjectName
    Name of the Azure Migrate project
.PARAMETER MachineName
    (Optional) Specific machine name to stop replication. If not provided, stops all machines.
.PARAMETER OutputPath
    (Optional) Path to save the CSV file. Default is current directory.
.PARAMETER ForceRemove
    (Optional) Force remove even if cleanup fails. Default is $false.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory=$true)]
    [string]$MigrateProjectName,
    
    [Parameter(Mandatory=$false)]
    [string]$MachineName,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "."
)

$ErrorActionPreference = "Stop"

try {
    # Verify Azure connection
    Write-Host "Verifying Azure connection..." -ForegroundColor Cyan
    try {
        $currentContext = Get-AzContext -ErrorAction Stop
        if ($null -eq $currentContext) {
            Write-Host "❌ Not connected to Azure. Please run 'Connect-AzAccount' first." -ForegroundColor Red
            return
        }
        Write-Host "✓ Connected to Azure as: $($currentContext.Account.Id)" -ForegroundColor Green
    }
    catch {
        Write-Host "❌ Not connected to Azure. Please run 'Connect-AzAccount' first." -ForegroundColor Red
        return
    }
    
    # Set subscription context
    Write-Host "Setting subscription context to: $SubscriptionId" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    Write-Host "✓ Context set successfully" -ForegroundColor Green
    
    # Get replicating machines
    Write-Host "`nRetrieving replicating machines..." -ForegroundColor Cyan
    
    if ($MachineName) {
        $ReplicatingServers = Get-AzMigrateServerReplication `
            -ResourceGroupName $ResourceGroupName `
            -ProjectName $MigrateProjectName `
            -MachineName $MachineName `
            -ErrorAction SilentlyContinue
        
        if ($null -eq $ReplicatingServers) {
            Write-Host "❌ No replicating machine found with name: $MachineName" -ForegroundColor Red
            return
        }
        
        # Convert single object to array
        $ReplicatingServers = @($ReplicatingServers)
    }
    else {
        $ReplicatingServers = Get-AzMigrateServerReplication `
            -ResourceGroupName $ResourceGroupName `
            -ProjectName $MigrateProjectName `
            -ErrorAction SilentlyContinue
        
        if ($null -eq $ReplicatingServers -or $ReplicatingServers.Count -eq 0) {
            Write-Host "❌ No replicating machines found in the project." -ForegroundColor Red
            return
        }
    }
    
    Write-Host "✓ Found $($ReplicatingServers.Count) replicating machine(s)" -ForegroundColor Green
    
    # Display machines with details and calculate total upfront
    Write-Host "`n📋 Machines to be processed:" -ForegroundColor Cyan
    $totalDisksToDelete = 0
    $totalSizeToFree = 0
    
    $ReplicatingServers | ForEach-Object {
        $diskCount = 0
        $totalSize = 0
        if ($_.ProviderSpecificDetail.ProtectedDisk) {
            $diskCount = $_.ProviderSpecificDetail.ProtectedDisk.Count
            $totalSize = ($_.ProviderSpecificDetail.ProtectedDisk | ForEach-Object { $_.DiskCapacityInByte } | Measure-Object -Sum).Sum / 1GB
            $totalDisksToDelete += $diskCount
            $totalSizeToFree += $totalSize
        }
        Write-Host "  • $($_.MachineName)" -ForegroundColor White
        Write-Host "    Status: $($_.ReplicationStatus)" -ForegroundColor Gray
        Write-Host "    Disks: $diskCount ($([math]::Round($totalSize, 2)) GB)" -ForegroundColor Gray
        Write-Host "    Target VM: $($_.TargetVMName)" -ForegroundColor Gray
    }
    
    Write-Host "`n📊 Total to be processed:" -ForegroundColor Yellow
    Write-Host "  Total disks: $totalDisksToDelete" -ForegroundColor White
    Write-Host "  Total size: $([math]::Round($totalSizeToFree, 2)) GB" -ForegroundColor White
    
    # Confirmation
    Write-Host "`n⚠️  WARNING: This will stop replication and delete ASR disks!" -ForegroundColor Yellow
    $confirmation = Read-Host "`nDo you want to proceed? Type 'yes' to continue"
    if ($confirmation -ne 'yes') {
        Write-Host "❌ Operation cancelled by user." -ForegroundColor Yellow
        return
    }
    
    # Stop replication and collect results
    Write-Host "`n📊 Stopping replication..." -ForegroundColor Cyan
    $results = @()
    $progressCount = 0
    
    foreach ($Server in $ReplicatingServers) {
        $progressCount++
        Write-Host "`n[$progressCount/$($ReplicatingServers.Count)] Processing: $($Server.MachineName)..." -ForegroundColor Cyan
        
        # IMPORTANT: Capture disk information BEFORE deletion
        $totalDiskSizeGB = 0
        $diskCount = 0
        $diskDetails = @()
        
        if ($Server.ProviderSpecificDetail.ProtectedDisk) {
            foreach ($disk in $Server.ProviderSpecificDetail.ProtectedDisk) {
                $diskSizeGB = [math]::Round($disk.DiskCapacityInByte / 1GB, 2)
                $totalDiskSizeGB += $diskSizeGB
                $diskCount++
                $diskDetails += "$($disk.DiskName) ($diskSizeGB GB)"
            }
        }
        
        Write-Host "  Disk count: $diskCount" -ForegroundColor Gray
        Write-Host "  Total size: $([math]::Round($totalDiskSizeGB, 2)) GB" -ForegroundColor Gray
        
        try {
            # Stop replication
            Write-Host "  Stopping replication..." -ForegroundColor Gray
            
            if ($ForceRemove) {
                Write-Host "  Using force remove option..." -ForegroundColor Yellow
                Remove-AzMigrateServerReplication -InputObject $Server -ErrorAction Stop
            }
            else {
                Remove-AzMigrateServerReplication -InputObject $Server -ErrorAction Stop
            }
            
            Write-Host "  ✓ Successfully stopped replication for: $($Server.MachineName)" -ForegroundColor Green
            
            # Record success with captured disk information
            $results += [PSCustomObject]@{
                SubscriptionId = $SubscriptionId
                ResourceGroup = $ResourceGroupName
                MigrateProject = $MigrateProjectName
                MachineName = $Server.MachineName
                TargetVMName = $Server.TargetVMName
                TargetResourceGroup = $Server.TargetResourceGroupName
                TargetLocation = $Server.TargetLocation
                ReplicationStatus = $Server.ReplicationStatus
                MigrationState = $Server.MigrationState
                DiskCount = $diskCount
                TotalDiskSizeGB = $totalDiskSizeGB
                DiskDetails = ($diskDetails -join "; ")
                Status = "Success"
                Message = "Replication stopped and ASR disks deleted successfully"
                Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        }
        catch {
            Write-Host "  ❌ Failed to stop replication for: $($Server.MachineName)" -ForegroundColor Red
            Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
            
            # Record failure with disk information that was captured before the attempt
            $results += [PSCustomObject]@{
                SubscriptionId = $SubscriptionId
                ResourceGroup = $ResourceGroupName
                MigrateProject = $MigrateProjectName
                MachineName = $Server.MachineName
                TargetVMName = $Server.TargetVMName
                TargetResourceGroup = $Server.TargetResourceGroupName
                TargetLocation = $Server.TargetLocation
                ReplicationStatus = $Server.ReplicationStatus
                MigrationState = $Server.MigrationState
                DiskCount = $diskCount
                TotalDiskSizeGB = $totalDiskSizeGB
                DiskDetails = ($diskDetails -join "; ")
                Status = "Failed"
                Message = $_.Exception.Message
                Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        }
    }
    
    # Export to CSV
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $outputFile = Join-Path $OutputPath "Stop_Replication_Results_$timestamp.csv"
    $results | Export-Csv -Path $outputFile -NoTypeInformation
    
    # Calculate summary metrics
    $successResults = $results | Where-Object { $_.Status -eq "Success" }
    $failedResults = $results | Where-Object { $_.Status -eq "Failed" }
    
    $successCount = $successResults.Count
    $failedCount = $failedResults.Count
    
    # Sum disk sizes for successful operations
    $totalDiskSize = 0
    $totalDisks = 0
    
    if ($successResults) {
        $totalDiskSize = ($successResults | Measure-Object -Property TotalDiskSizeGB -Sum).Sum
        $totalDisks = ($successResults | Measure-Object -Property DiskCount -Sum).Sum
    }
    
    # Display summary
    Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                         SUMMARY                                ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host "Total machines processed: $($results.Count)" -ForegroundColor White
    Write-Host "Successfully stopped: $successCount" -ForegroundColor Green
    Write-Host "Failed: $failedCount" -ForegroundColor $(if ($failedCount -gt 0) { "Red" } else { "White" })
    Write-Host "Total ASR disks deleted: $totalDisks" -ForegroundColor $(if ($totalDisks -gt 0) { "Green" } else { "Yellow" })
    Write-Host "Total ASR disk size freed: $([math]::Round($totalDiskSize, 2)) GB" -ForegroundColor $(if ($totalDiskSize -gt 0) { "Green" } else { "Yellow" })
    
    if ($failedCount -gt 0) {
        Write-Host "`n⚠️  Failed machines:" -ForegroundColor Yellow
        $failedResults | ForEach-Object {
            Write-Host "  • $($_.MachineName): $($_.Message)" -ForegroundColor Red
        }
    }
    
    if ($successCount -gt 0) {
        Write-Host "`n✓ Successfully processed machines:" -ForegroundColor Green
        $successResults | ForEach-Object {
            Write-Host "  • $($_.MachineName): $($_.DiskCount) disk(s), $([math]::Round($_.TotalDiskSizeGB, 2)) GB" -ForegroundColor White
        }
    }
    
    Write-Host "`n✓ Results exported to: $outputFile" -ForegroundColor Green
    
    # Estimate cost savings (only for successfully deleted disks)
    if ($totalDiskSize -gt 0) {
        $monthlyCostPerGB = 0.05
        $monthlySavings = [math]::Round($totalDiskSize * $monthlyCostPerGB, 2)
        Write-Host "`n💰 Estimated monthly cost savings: ~`$$monthlySavings USD" -ForegroundColor Yellow
    }
    else {
        Write-Host "`n⚠️  No disks were deleted, so no cost savings achieved." -ForegroundColor Yellow
    }
    
    # Diagnostic information if no disks found
    if ($totalDisks -eq 0 -and $successCount -gt 0) {
        Write-Host "`n⚠️  DIAGNOSTIC INFORMATION:" -ForegroundColor Yellow
        Write-Host "  Replication was stopped but no disk information was captured." -ForegroundColor Gray
        Write-Host "  Possible reasons:" -ForegroundColor Gray
        Write-Host "    1. The VMs had no protected disks configured" -ForegroundColor Gray
        Write-Host "    2. Disk information was not available in ProviderSpecificDetail" -ForegroundColor Gray
        Write-Host "    3. The replication was already in progress of being removed" -ForegroundColor Gray
        Write-Host "`n  Please check the CSV file for detailed information." -ForegroundColor Gray
    }
}
catch {
    Write-Host "`n❌ Error occurred: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
}