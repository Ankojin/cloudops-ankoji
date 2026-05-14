<#
.SYNOPSIS
    Identifies oversized Azure VMs based on 6-month average metrics.

.DESCRIPTION
    This script analyzes Azure VMs across subscriptions to identify oversized resources
    based on CPU, memory, and disk utilization over the past 6 months. It provides
    Azure Advisor-style rightsizing recommendations and potential cost savings.

.PARAMETER SubscriptionId
    Single subscription ID to analyze. If not provided, all accessible subscriptions will be scanned.

.PARAMETER SubscriptionIds
    Array of subscription IDs to analyze.

.PARAMETER ResourceGroupName
    Optional. Filter VMs by specific resource group.

.PARAMETER CpuThreshold
    CPU utilization threshold percentage. VMs below this are considered oversized. Default: 20%

.PARAMETER MemoryThreshold
    Memory utilization threshold percentage. VMs below this are considered oversized. Default: 30%

.PARAMETER DiskThreshold
    Disk utilization threshold percentage. VMs below this are considered oversized. Default: 40%

.PARAMETER OutputPath
    Path for the output CSV report. Default: Current directory with timestamp.

.PARAMETER MonthsToAnalyze
    Number of months to analyze. Default: 6 months.

.PARAMETER IncludeAdvisorRecommendations
    Include Azure Advisor-style recommendations (Cost, Security, Reliability, Performance).

.PARAMETER CheckReservedInstances
    Check for Reserved Instance recommendations.

.PARAMETER DetailedReport
    Generate detailed report with all recommendations.

.EXAMPLE
    .\Get-OversizedVMs.ps1 -SubscriptionId "xxxx-xxxx-xxxx-xxxx"

.EXAMPLE
    .\Get-OversizedVMs.ps1 -IncludeAdvisorRecommendations -CpuThreshold 15 -MemoryThreshold 25

.EXAMPLE
    .\Get-OversizedVMs.ps1 -SubscriptionIds @("sub1", "sub2") -IncludeAdvisorRecommendations -CheckReservedInstances

.NOTES
    Author: BAB CloudOps Team
    Date: February 2026
    Requires: Az.Accounts, Az.Compute, Az.Monitor, Az.OperationalInsights modules
    
.LINK
    https://docs.microsoft.com/en-us/azure/azure-monitor/
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionIds,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$CpuThreshold = 20,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$MemoryThreshold = 30,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$DiskThreshold = 40,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 12)]
    [int]$MonthsToAnalyze = 6,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeAdvisorRecommendations,

    [Parameter(Mandatory = $false)]
    [switch]$CheckReservedInstances,

    [Parameter(Mandatory = $false)]
    [switch]$DetailedReport,

    [Parameter(Mandatory = $false)]
    [string]$LogAnalyticsWorkspaceId = "2b769ac8-2757-4611-a534-891be5dcb3b6",

    [Parameter(Mandatory = $false)]
    [string]$LogAnalyticsWorkspaceName = "bab-dev-all-wrkspc-swec-01"
)

#region Functions

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    switch ($Level) {
        'ERROR'   { Write-Host $logMessage -ForegroundColor Red }
        'WARNING' { Write-Host $logMessage -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $logMessage -ForegroundColor Green }
        default   { Write-Host $logMessage -ForegroundColor White }
    }
    
    $logMessage | Out-File -FilePath $script:LogFile -Append -Encoding UTF8
}

function Test-AzureConnection {
    [CmdletBinding()]
    param()
    
    try {
        $context = Get-AzContext
        if (-not $context) {
            Write-Log "Not connected to Azure. Initiating login..." -Level WARNING
            Connect-AzAccount -ErrorAction Stop
            Write-Log "Successfully connected to Azure" -Level SUCCESS
        }
        else {
            Write-Log "Already connected to Azure as $($context.Account.Id)" -Level INFO
        }
        return $true
    }
    catch {
        Write-Log "Failed to connect to Azure: $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

function Get-LAWorkspaceForVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$VM
    )
    
    $omsExtension = $VM.Extensions | Where-Object { 
        $_.Name -like "*MicrosoftMonitoringAgent*" -or 
        $_.Name -like "*OmsAgentForLinux*" -or
        $_.Name -like "*AzureMonitorWindowsAgent*" -or
        $_.Name -like "*AzureMonitorLinuxAgent*"
    }
    
    if ($omsExtension) {
        try {
            $settings = $omsExtension.PublicSettings | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($settings.workspaceId) {
                return $settings.workspaceId
            }
        }
        catch {
            # Could not parse settings
        }
    }
    
    return $null
}

function Get-MemoryMetricsFromLogAnalytics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceId,
        
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        
        [Parameter(Mandatory = $true)]
        [datetime]$StartTime,
        
        [Parameter(Mandatory = $true)]
        [datetime]$EndTime
    )
    
    try {
        # Try DCR-based InsightsMetrics table (VM Insights with Azure Monitor Agent)
        # Computer names are case-sensitive and typically uppercase
        $VMNameUpper = $VMName.ToUpper()
        $queryDCR = @"
InsightsMetrics
| where TimeGenerated >= datetime('$($StartTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))') and TimeGenerated <= datetime('$($EndTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))')
| where Computer == '$VMNameUpper' or Computer == '$VMName' or Computer startswith '$VMNameUpper' or Computer startswith '$VMName'
| where Namespace == 'Memory'
| where Name == 'AvailableMB' or Name == 'Available Memory Bytes' or Name == 'Available Memory MBytes'
| summarize AvgMemoryMB = avg(Val), MinMemoryMB = min(Val) by Name
"@
        
        Write-Log "Querying InsightsMetrics (VM Insights/DCR) for $VMName" -Level INFO
        
        $resultDCR = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $queryDCR -ErrorAction SilentlyContinue
        
        if ($resultDCR -and $resultDCR.Results -and $resultDCR.Results.Count -gt 0) {
            Write-Log "Found VM Insights memory metrics for $VMName" -Level SUCCESS
            return @{
                Source = "DCR"
                Results = $resultDCR.Results
            }
        }
        
        # Fallback: Legacy Perf table
        $VMNameUpper = $VMName.ToUpper()
        $queryPerf = @"
Perf
| where TimeGenerated >= datetime('$($StartTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))') and TimeGenerated <= datetime('$($EndTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))')
| where Computer == '$VMNameUpper' or Computer == '$VMName' or Computer startswith '$VMNameUpper' or Computer startswith '$VMName'
| where ObjectName == 'Memory' or ObjectName == 'Memoria'
| where CounterName == '% Committed Bytes In Use' or CounterName == 'Available MBytes'
| summarize AvgValue = avg(CounterValue), MaxValue = max(CounterValue), MinValue = min(CounterValue) by CounterName
"@
        
        Write-Log "Querying Perf table (legacy) for $VMName" -Level INFO
        
        $resultPerf = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $queryPerf -ErrorAction Stop
        
        if ($resultPerf -and $resultPerf.Results -and $resultPerf.Results.Count -gt 0) {
            Write-Log "Found legacy Perf table metrics for $VMName" -Level SUCCESS
            return @{
                Source = "Perf"
                Results = $resultPerf.Results
            }
        }
    }
    catch {
        Write-Log "Failed to query Log Analytics: $($_.Exception.Message)" -Level WARNING
    }
    
    return $null
}

function Test-VMMonitoringEnabled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$VM
    )
    
    $hasMonitoring = $false
    $monitoringType = "None"
    $workspaceId = $null
    
    $amaExtension = $VM.Extensions | Where-Object { 
        $_.Name -like "*AzureMonitorWindowsAgent*" -or 
        $_.Name -like "*AzureMonitorLinuxAgent*" 
    }
    
    $diagExtension = $VM.Extensions | Where-Object { 
        $_.Name -like "*Diagnostics*" -or 
        $_.VirtualMachineExtensionType -eq "IaaSDiagnostics" -or
        $_.VirtualMachineExtensionType -eq "LinuxDiagnostic"
    }
    
    $omsExtension = $VM.Extensions | Where-Object { 
        $_.Name -like "*MicrosoftMonitoringAgent*" -or 
        $_.Name -like "*OmsAgentForLinux*"
    }
    
    if ($amaExtension) {
        $hasMonitoring = $true
        $monitoringType = "VM Insights (Azure Monitor Agent)"
        $workspaceId = Get-LAWorkspaceForVM -VM $VM
    }
    elseif ($diagExtension) {
        $hasMonitoring = $true
        $monitoringType = "Diagnostics Extension"
    }
    elseif ($omsExtension) {
        $hasMonitoring = $true
        $monitoringType = "VM Insights (Log Analytics Agent)"
        $workspaceId = Get-LAWorkspaceForVM -VM $VM
    }
    
    return @{
        HasMonitoring = $hasMonitoring
        MonitoringType = $monitoringType
        WorkspaceId = $workspaceId
    }
}

function Get-VMMetrics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$VM,
        
        [Parameter(Mandatory = $true)]
        [datetime]$StartTime,
        
        [Parameter(Mandatory = $true)]
        [datetime]$EndTime
    )
    
    $metrics = @{
        VMName = $VM.Name
        ResourceGroup = $VM.ResourceGroupName
        SubscriptionId = $VM.Id.Split('/')[2]
        Location = $VM.Location
        VMSize = $VM.HardwareProfile.VmSize
        PowerState = $VM.PowerState
        OSType = $VM.StorageProfile.OsDisk.OsType
        OSDiskType = $VM.StorageProfile.OsDisk.ManagedDisk.StorageAccountType
        AvgCpuPercent = $null
        MaxCpuPercent = $null
        AvgMemoryPercent = $null
        MaxMemoryPercent = $null
        AvgDiskReadBytes = $null
        AvgDiskWriteBytes = $null
        IsOversized = $false
        Recommendation = ""
        EstimatedMonthlySavings = 0
        Category = ""
        Impact = ""
        RecommendationType = ""
        HasAvailabilityZone = $false
        HasBackupEnabled = $false
        HasBootDiagnostics = $false
        HasTags = $false
        TagsCount = 0
        IsIdleVM = $false
        ReservedInstanceRecommendation = ""
        SecurityRecommendations = @()
        CostOptimizations = @()
        ReliabilityRecommendations = @()
        PerformanceRecommendations = @()
        MonitoringType = ""
    }
    
    try {
        if ($VM.PowerState -eq "VM deallocated") {
            Write-Log "Skipping deallocated VM: $($VM.Name)" -Level WARNING
            $metrics.Recommendation = "VM is deallocated - no metrics available"
            return $metrics
        }
        
        $resourceId = $VM.Id
        
        # CPU Metrics
        Write-Log "Retrieving CPU metrics for $($VM.Name)..." -Level INFO
        try {
            $cpuMetrics = Get-AzMetric -ResourceId $resourceId `
                -MetricName "Percentage CPU" `
                -StartTime $StartTime `
                -EndTime $EndTime `
                -TimeGrain 01:00:00 `
                -AggregationType Average `
                -ErrorAction SilentlyContinue
            
            if ($cpuMetrics -and $cpuMetrics.Data.Count -gt 0) {
                $avgCpu = ($cpuMetrics.Data.Average | Where-Object { $_ -ne $null } | Measure-Object -Average).Average
                $maxCpu = ($cpuMetrics.Data.Average | Where-Object { $_ -ne $null } | Measure-Object -Maximum).Maximum
                $metrics.AvgCpuPercent = [math]::Round($avgCpu, 2)
                $metrics.MaxCpuPercent = [math]::Round($maxCpu, 2)
            }
        }
        catch {
            Write-Log "Failed to get CPU metrics for $($VM.Name): $($_.Exception.Message)" -Level WARNING
        }
        
        # Memory Metrics from Log Analytics (VM Insights)
        Write-Log "Retrieving memory metrics for $($VM.Name)..." -Level INFO
        
        $monitoringStatus = Test-VMMonitoringEnabled -VM $VM
        
        if (-not $monitoringStatus.HasMonitoring) {
            Write-Log "VM $($VM.Name) does not have monitoring enabled" -Level WARNING
            $metrics.MonitoringType = "None - Enable VM Insights for memory metrics"
        }
        else {
            $metrics.MonitoringType = $monitoringStatus.MonitoringType
            Write-Log "VM $($VM.Name) has $($monitoringStatus.MonitoringType) enabled" -Level SUCCESS
        }
        
        $memoryFound = $false
        
        # Use provided workspace ID or try to get from VM extension
        $workspaceToUse = if ($script:WorkspaceId) { $script:WorkspaceId } else { $monitoringStatus.WorkspaceId }
        
        if ($workspaceToUse) {
            Write-Log "Retrieving memory from Log Analytics workspace $workspaceToUse for $($VM.Name)" -Level INFO
            
            $laMemoryMetrics = Get-MemoryMetricsFromLogAnalytics `
                -WorkspaceId $workspaceToUse `
                -VMName $VM.Name `
                -StartTime $StartTime `
                -EndTime $EndTime
            
            if ($laMemoryMetrics) {
                if ($laMemoryMetrics.Source -eq "DCR") {
                    Write-Log "Processing VM Insights/DCR memory data for $($VM.Name)" -Level INFO
                    
                    $availableMemRow = $laMemoryMetrics.Results | Select-Object -First 1
                    
                    if ($availableMemRow -and $availableMemRow.AvgMemoryMB) {
                        try {
                            # Use Location from metrics, fallback to swedencentral if empty
                            $vmLocation = if ($metrics.Location) { $metrics.Location } else { "swedencentral" }
                            $vmSize = Get-AzVMSize -Location $vmLocation | Where-Object { $_.Name -eq $VM.HardwareProfile.VmSize }
                        } catch {
                            Write-Log "Failed to get VM size for $($VM.Name): $($_.Exception.Message)" -Level WARNING
                            $vmSize = $null
                        }
                        
                        if ($vmSize -and $vmSize.MemoryInMB) {
                            $totalMemoryMB = $vmSize.MemoryInMB
                            $avgAvailableMB = $availableMemRow.AvgMemoryMB
                            $minAvailableMB = $availableMemRow.MinMemoryMB
                            
                            $avgUsedPercent = (1 - ($avgAvailableMB / $totalMemoryMB)) * 100
                            $maxUsedPercent = (1 - ($minAvailableMB / $totalMemoryMB)) * 100
                            
                            $metrics.AvgMemoryPercent = [math]::Round($avgUsedPercent, 2)
                            $metrics.MaxMemoryPercent = [math]::Round($maxUsedPercent, 2)
                            
                            Write-Log "VM Insights memory for $($VM.Name): Avg=${avgUsedPercent}%, Max=${maxUsedPercent}%" -Level SUCCESS
                            $memoryFound = $true
                        }
                    }
                }
                elseif ($laMemoryMetrics.Source -eq "Perf") {
                    Write-Log "Processing legacy Perf data for $($VM.Name)" -Level INFO
                    
                    $committedBytesRow = $laMemoryMetrics.Results | Where-Object { $_.CounterName -like "*Committed Bytes*" }
                    $availableMBRow = $laMemoryMetrics.Results | Where-Object { $_.CounterName -like "*Available*" }
                    
                    if ($committedBytesRow) {
                        $metrics.AvgMemoryPercent = [math]::Round($committedBytesRow.AvgValue, 2)
                        $metrics.MaxMemoryPercent = [math]::Round($committedBytesRow.MaxValue, 2)
                        $memoryFound = $true
                    }
                    elseif ($availableMBRow) {
                        try {
                            # Use Location from metrics, fallback to swedencentral if empty
                            $vmLocation = if ($metrics.Location) { $metrics.Location } else { "swedencentral" }
                            $vmSize = Get-AzVMSize -Location $vmLocation | Where-Object { $_.Name -eq $VM.HardwareProfile.VmSize }
                        } catch {
                            Write-Log "Failed to get VM size for $($VM.Name): $($_.Exception.Message)" -Level WARNING
                            $vmSize = $null
                        }
                        if ($vmSize -and $vmSize.MemoryInMB) {
                            $avgUsedPercent = (1 - ($availableMBRow.AvgValue / $vmSize.MemoryInMB)) * 100
                            $maxUsedPercent = (1 - ($availableMBRow.MinValue / $vmSize.MemoryInMB)) * 100
                            
                            $metrics.AvgMemoryPercent = [math]::Round($avgUsedPercent, 2)
                            $metrics.MaxMemoryPercent = [math]::Round($maxUsedPercent, 2)
                            $memoryFound = $true
                        }
                    }
                }
            }
        }
        
        if (-not $memoryFound) {
            Write-Log "No memory metrics available for $($VM.Name)" -Level WARNING
        }
        
        # Disk Metrics
        Write-Log "Retrieving disk metrics for $($VM.Name)..." -Level INFO
        try {
            $diskReadMetrics = Get-AzMetric -ResourceId $resourceId `
                -MetricName "Disk Read Bytes" `
                -StartTime $StartTime `
                -EndTime $EndTime `
                -TimeGrain 01:00:00 `
                -AggregationType Average `
                -ErrorAction SilentlyContinue
            
            if ($diskReadMetrics -and $diskReadMetrics.Data.Count -gt 0) {
                $avgDiskRead = ($diskReadMetrics.Data.Average | Where-Object { $_ -ne $null } | Measure-Object -Average).Average
                $metrics.AvgDiskReadBytes = [math]::Round($avgDiskRead / 1MB, 2)
            }
            
            $diskWriteMetrics = Get-AzMetric -ResourceId $resourceId `
                -MetricName "Disk Write Bytes" `
                -StartTime $StartTime `
                -EndTime $EndTime `
                -TimeGrain 01:00:00 `
                -AggregationType Average `
                -ErrorAction SilentlyContinue
            
            if ($diskWriteMetrics -and $diskWriteMetrics.Data.Count -gt 0) {
                $avgDiskWrite = ($diskWriteMetrics.Data.Average | Where-Object { $_ -ne $null } | Measure-Object -Average).Average
                $metrics.AvgDiskWriteBytes = [math]::Round($avgDiskWrite / 1MB, 2)
            }
        }
        catch {
            Write-Log "Failed to get disk metrics for $($VM.Name): $($_.Exception.Message)" -Level WARNING
        }
    }
    catch {
        Write-Log "Error retrieving metrics for $($VM.Name): $($_.Exception.Message)" -Level ERROR
    }
    
    return $metrics
}

function Get-RightsizingRecommendation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Metrics,
        
        [Parameter(Mandatory = $true)]
        [int]$CpuThreshold,
        
        [Parameter(Mandatory = $true)]
        [int]$MemoryThreshold,
        
        [Parameter(Mandatory = $true)]
        [int]$DiskThreshold
    )
    
    $recommendations = @()
    $isOversized = $false
    
    if ($Metrics.AvgCpuPercent -ne $null -and $Metrics.AvgCpuPercent -lt $CpuThreshold) {
        $recommendations += "Low CPU usage ($($Metrics.AvgCpuPercent)% avg)"
        $isOversized = $true
    }
    
    if ($Metrics.AvgMemoryPercent -ne $null -and $Metrics.AvgMemoryPercent -lt $MemoryThreshold) {
        $recommendations += "Low memory usage ($($Metrics.AvgMemoryPercent)% avg)"
        $isOversized = $true
    }
    
    if ($isOversized) {
        $currentSize = $Metrics.VMSize
        
        if ($currentSize -match '_([A-Z]\d+[a-z]*)') {
            $currentTier = $matches[1]
            if ($currentTier -match '(\D+)(\d+)(.*)') {
                $prefix = $matches[1]
                $number = [int]$matches[2]
                $suffix = $matches[3]
                
                if ($number -gt 1) {
                    $suggestedNumber = [math]::Max(1, $number / 2)
                    $sizeFamily = $currentSize -replace '\d+.*$', ''
                    $suggestedSize = "$($sizeFamily)$($prefix)$($suggestedNumber)$($suffix)"
                    $recommendations += "Consider downsizing to $suggestedSize or similar"
                    
                    $Metrics.EstimatedMonthlySavings = 200
                }
            }
        }
        
        $Metrics.IsOversized = $true
        $Metrics.Recommendation = $recommendations -join "; "
    }
    else {
        $Metrics.Recommendation = "VM appears to be appropriately sized"
    }
}

function Get-AzureAdvisorRecommendations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$VM,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Metrics,
        
        [Parameter(Mandatory = $false)]
        [bool]$CheckReservedInstances = $false
    )
    
    Write-Log "Analyzing Azure Advisor recommendations for $($VM.Name)..." -Level INFO
    
    # Cost Optimization
    $costRecommendations = @()
    
    if ($Metrics.AvgCpuPercent -ne $null -and $Metrics.AvgCpuPercent -lt 5) {
        $costRecommendations += "VM appears idle with CPU < 5% - Consider deallocating or deleting"
        $Metrics.IsIdleVM = $true
        $Metrics.EstimatedMonthlySavings += 150
    }
    
    if ($VM.StorageProfile.OsDisk.ManagedDisk.StorageAccountType -like "*Premium*" -and 
        $Metrics.AvgCpuPercent -lt 30) {
        $costRecommendations += "Consider Standard SSD for OS disk on low-utilization VM"
        $Metrics.EstimatedMonthlySavings += 20
    }
    
    if ($CheckReservedInstances -and $Metrics.PowerState -eq "VM running") {
        $Metrics.ReservedInstanceRecommendation = "Consider 1 or 3-year Reserved Instance for ~40-60% savings"
        $costRecommendations += $Metrics.ReservedInstanceRecommendation
    }
    
    $Metrics.CostOptimizations = $costRecommendations
    
    # Reliability
    $reliabilityRecommendations = @()
    
    if ($VM.Zones -and $VM.Zones.Count -gt 0) {
        $Metrics.HasAvailabilityZone = $true
    }
    else {
        $reliabilityRecommendations += "Deploy VM in Availability Zone for 99.99% SLA"
    }
    
    if (-not $Metrics.HasAvailabilityZone -and -not $VM.AvailabilitySetReference) {
        $reliabilityRecommendations += "VM has no high availability configuration - Add to Availability Set or Zone"
    }
    
    if ($VM.DiagnosticsProfile.BootDiagnostics.Enabled) {
        $Metrics.HasBootDiagnostics = $true
    }
    else {
        $reliabilityRecommendations += "Enable boot diagnostics for troubleshooting"
    }
    
    $Metrics.ReliabilityRecommendations = $reliabilityRecommendations
    
    # Security
    $securityRecommendations = @()
    
    $encryptionSettings = $VM.StorageProfile.OsDisk.EncryptionSettings
    if (-not $encryptionSettings -or -not $encryptionSettings.Enabled) {
        $securityRecommendations += "Enable Azure Disk Encryption for data protection"
    }
    
    $securityRecommendations += "Verify VM is monitored by Microsoft Defender for Cloud"
    
    $Metrics.SecurityRecommendations = $securityRecommendations
    
    # Performance
    $performanceRecommendations = @()
    
    if ($Metrics.MaxCpuPercent -ne $null -and $Metrics.MaxCpuPercent -gt 90) {
        $performanceRecommendations += "High CPU utilization detected (Max: $($Metrics.MaxCpuPercent)%) - Consider scaling up"
    }
    
    if ($Metrics.AvgMemoryPercent -ne $null -and $Metrics.AvgMemoryPercent -gt 85) {
        $performanceRecommendations += "High memory utilization detected - Consider VM with more RAM"
    }
    
    $vmNics = $VM.NetworkProfile.NetworkInterfaces
    foreach ($nicRef in $vmNics) {
        $nicName = $nicRef.Id.Split('/')[-1]
        $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $VM.ResourceGroupName -ErrorAction SilentlyContinue
        
        if ($nic -and -not $nic.EnableAcceleratedNetworking) {
            $performanceRecommendations += "Enable Accelerated Networking for better performance"
            break
        }
    }
    
    $Metrics.PerformanceRecommendations = $performanceRecommendations
    
    # Operational Excellence
    if ($VM.Tags -and $VM.Tags.Count -gt 0) {
        $Metrics.HasTags = $true
        $Metrics.TagsCount = $VM.Tags.Count
    }
    
    # Determine category
    if ($Metrics.IsOversized -or $Metrics.IsIdleVM) {
        $Metrics.Category = "Cost Optimization"
        $Metrics.Impact = "High"
        $Metrics.RecommendationType = "Rightsizing"
    }
    elseif ($performanceRecommendations.Count -gt 0) {
        $Metrics.Category = "Performance"
        $Metrics.Impact = "Medium"
        $Metrics.RecommendationType = "Scale Up"
    }
    elseif ($reliabilityRecommendations.Count -gt 0) {
        $Metrics.Category = "Reliability"
        $Metrics.Impact = "Medium"
        $Metrics.RecommendationType = "High Availability"
    }
    else {
        $Metrics.Category = "Operational Excellence"
        $Metrics.Impact = "Low"
        $Metrics.RecommendationType = "Best Practices"
    }
}

#endregion

#region Main Script

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$script:LogFile = Join-Path $PSScriptRoot "OversizedVMs_Log_$timestamp.txt"
$script:WorkspaceId = $LogAnalyticsWorkspaceId

Write-Log "=========================================" -Level INFO
Write-Log "Starting Oversized VM Analysis" -Level INFO
Write-Log "=========================================" -Level INFO
Write-Log "CPU Threshold: $CpuThreshold%" -Level INFO
Write-Log "Memory Threshold: $MemoryThreshold%" -Level INFO
Write-Log "Analysis Period: Last $MonthsToAnalyze months" -Level INFO
Write-Log "Log Analytics Workspace: $LogAnalyticsWorkspaceName" -Level INFO

if (-not (Test-AzureConnection)) {
    Write-Log "Failed to establish Azure connection. Exiting." -Level ERROR
    exit 1
}

# Check required modules
$requiredModules = @('Az.Accounts', 'Az.Compute', 'Az.Monitor', 'Az.OperationalInsights')
foreach ($module in $requiredModules) {
    if (-not (Get-Module -Name $module -ListAvailable)) {
        Write-Log "Required module $module is not installed. Installing..." -Level WARNING
        try {
            Install-Module -Name $module -Force -AllowClobber -Scope CurrentUser
            Write-Log "Successfully installed $module" -Level SUCCESS
        }
        catch {
            Write-Log "Failed to install $module : $($_.Exception.Message)" -Level ERROR
            exit 1
        }
    }
    Import-Module $module -ErrorAction SilentlyContinue
}

$endTime = Get-Date
$startTime = $endTime.AddMonths(-$MonthsToAnalyze)
Write-Log "Analyzing metrics from $($startTime.ToString('yyyy-MM-dd')) to $($endTime.ToString('yyyy-MM-dd'))" -Level INFO

# Determine subscriptions
$subscriptionsToAnalyze = @()

if ($SubscriptionId) {
    $subscriptionsToAnalyze += $SubscriptionId
}
elseif ($SubscriptionIds -and $SubscriptionIds.Count -gt 0) {
    $subscriptionsToAnalyze = $SubscriptionIds
}
else {
    Write-Log "Analyzing all accessible subscriptions..." -Level INFO
    $allSubscriptions = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }
    $subscriptionsToAnalyze = $allSubscriptions.Id
    Write-Log "Found $($subscriptionsToAnalyze.Count) enabled subscriptions" -Level INFO
}

$allResults = @()
$totalVMs = 0
$oversizedVMs = 0

foreach ($subId in $subscriptionsToAnalyze) {
    try {
        Write-Log "========================================" -Level INFO
        Write-Log "Processing Subscription: $subId" -Level INFO
        
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
        $subscription = Get-AzSubscription -SubscriptionId $subId
        Write-Log "Context set to: $($subscription.Name)" -Level SUCCESS
        
        $vms = if ($ResourceGroupName) {
            Get-AzVM -ResourceGroupName $ResourceGroupName -Status
        }
        else {
            Get-AzVM -Status
        }
        
        # Exclude Azure Red Hat OpenShift (ARO) PaaS VMs
        $vms = $vms | Where-Object { $_.Name -notmatch '-aro-|^aro-' }
        Write-Log "Excluding Azure Red Hat OpenShift (ARO) PaaS VMs from analysis" -Level INFO
        
        Write-Log "Found $($vms.Count) VMs in subscription" -Level INFO
        $totalVMs += $vms.Count
        
        foreach ($vm in $vms) {
            Write-Log "Analyzing VM: $($vm.Name)" -Level INFO
            
            $vmMetrics = Get-VMMetrics -VM $vm -StartTime $startTime -EndTime $endTime
            $vmMetrics.SubscriptionName = $subscription.Name
            
            Get-RightsizingRecommendation -Metrics $vmMetrics `
                -CpuThreshold $CpuThreshold `
                -MemoryThreshold $MemoryThreshold `
                -DiskThreshold $DiskThreshold
            
            if ($IncludeAdvisorRecommendations) {
                Get-AzureAdvisorRecommendations -VM $vm -Metrics $vmMetrics -CheckReservedInstances $CheckReservedInstances.IsPresent
            }
            
            if ($vmMetrics.IsOversized) {
                $oversizedVMs++
                Write-Log "VM $($vm.Name) identified as oversized" -Level WARNING
            }
            
            $allResults += [PSCustomObject]$vmMetrics
            
            Start-Sleep -Milliseconds 100
        }
    }
    catch {
        Write-Log "Error processing subscription $subId : $($_.Exception.Message)" -Level ERROR
        continue
    }
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot "OversizedVMs_Report_$timestamp.csv"
}

# Flatten arrays for CSV export
try {
    $exportResults = $allResults | ForEach-Object {
        $item = $_
        $item.SecurityRecommendations = ($item.SecurityRecommendations -join "; ")
        $item.CostOptimizations = ($item.CostOptimizations -join "; ")
        $item.ReliabilityRecommendations = ($item.ReliabilityRecommendations -join "; ")
        $item.PerformanceRecommendations = ($item.PerformanceRecommendations -join "; ")
        $item
    }
    
    $exportResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Log "Report exported to: $OutputPath" -Level SUCCESS
}
catch {
    Write-Log "Failed to export report: $($_.Exception.Message)" -Level ERROR
}

Write-Log "========================================" -Level INFO
Write-Log "Analysis Complete!" -Level SUCCESS
Write-Log "========================================" -Level INFO
Write-Log "Total VMs Analyzed: $totalVMs" -Level INFO
Write-Log "Oversized VMs Found: $oversizedVMs" -Level WARNING
Write-Log "Report Location: $OutputPath" -Level INFO
Write-Log "Log Location: $script:LogFile" -Level INFO

if ($oversizedVMs -gt 0) {
    Write-Log "`nOversized VMs Summary:" -Level WARNING
    $allResults | Where-Object { $_.IsOversized } | Format-Table VMName, VMSize, AvgCpuPercent, AvgMemoryPercent, Recommendation -AutoSize
    
    $totalEstimatedSavings = ($allResults | Where-Object { $_.IsOversized } | Measure-Object -Property EstimatedMonthlySavings -Sum).Sum
    Write-Log "`nEstimated Monthly Savings: $$$totalEstimatedSavings (approximate)" -Level INFO
}

if ($IncludeAdvisorRecommendations) {
    Write-Log "`n========================================" -Level INFO
    Write-Log "Azure Advisor Recommendations Summary" -Level INFO
    Write-Log "========================================" -Level INFO
    
    $costIssues = $allResults | Where-Object { $_.CostOptimizations.Length -gt 0 }
    Write-Log "Cost Optimization: $($costIssues.Count) VMs" -Level WARNING
    
    $reliabilityIssues = $allResults | Where-Object { $_.ReliabilityRecommendations.Length -gt 0 }
    Write-Log "Reliability: $($reliabilityIssues.Count) VMs" -Level WARNING
    
    $securityIssues = $allResults | Where-Object { $_.SecurityRecommendations.Length -gt 0 }
    Write-Log "Security: $($securityIssues.Count) VMs" -Level WARNING
    
    $highImpact = $allResults | Where-Object { $_.Impact -eq "High" }
    if ($highImpact.Count -gt 0) {
        Write-Log "`nHigh-Impact Recommendations: $($highImpact.Count) VMs" -Level WARNING
    }
}

#endregion
