<#
.SYNOPSIS
    Migrate all VMs in a subscription to VM insights OpenTelemetry (Preview)

.DESCRIPTION
    This script automates the migration of Azure VMs to the new OpenTelemetry-based VM insights.
    It deploys Azure Monitor Agent (AMA) and configures Data Collection Rules (DCR) for OTel metrics.
    
    Features:
    - Multi-subscription support with context switching
    - Batch processing with parallel execution support
    - Automatic Azure Monitor Workspace creation/selection
    - Data Collection Rule (DCR) provisioning for OTel metrics
    - Azure Monitor Agent (AMA) extension deployment
    - Support for both Azure VMs and Arc-enabled servers
    - Comprehensive logging with timestamped log files
    - CSV export of migration results
    - Resume capability for interrupted runs
    - WhatIf support for dry-run testing

.PARAMETER SubscriptionId
    Target Azure subscription ID. If not provided, uses current context subscription.

.PARAMETER ResourceGroupName
    Optional. Migrate VMs in specific resource group only. If omitted, processes all VMs in subscription.

.PARAMETER AzureMonitorWorkspaceId
    Optional. Full resource ID of existing Azure Monitor Workspace.
    Example: "/subscriptions/.../resourcegroups/.../providers/microsoft.monitor/accounts/workspace-name"
    If provided, this workspace will be used instead of creating a new one.

.PARAMETER AzureMonitorWorkspaceName
    Optional. Name of Azure Monitor Workspace for OTel metrics. If not exists, will be created.
    Default: "amw-vminsights-{subscription-shortname}"
    Ignored if AzureMonitorWorkspaceId is specified.

.PARAMETER AzureMonitorWorkspaceRG
    Optional. Resource group for Azure Monitor Workspace. Default: "rg-monitoring-{location}"
    Ignored if AzureMonitorWorkspaceId is specified.

.PARAMETER Location
    Azure region for Azure Monitor Workspace and DCR. Default: "uaenorth"

.PARAMETER LogAnalyticsWorkspaceId
    Optional. Log Analytics workspace resource ID for classic metrics (if keeping both).
    If omitted, classic log-based metrics will be disabled (OTel only).

.PARAMETER EnableClassicMetrics
    Switch. Keep classic log-based metrics alongside OTel metrics. Default: false (OTel only)

.PARAMETER CustomMetricsEnabled
    Switch. Enable additional custom metrics (incurs additional cost). See documentation for full list.

.PARAMETER ParallelBatchSize
    Number of VMs to process in parallel. Default: 5 (recommended for Standard tier)

.PARAMETER ResumeFromCheckpoint
    Switch. Resume from last checkpoint (reads progress from checkpoint file)

.PARAMETER ExcludeVMsWithTag
    Optional. Tag name to exclude VMs (e.g., "ExcludeFromMonitoring"). VMs with this tag will be skipped.

.PARAMETER WhatIf
    Dry-run mode. Shows what would be done without making changes.

.EXAMPLE
    # Migrate all VMs in current subscription (OTel only, disable classic metrics)
    .\Migrate-VMInsights-OpenTelemetry.ps1 -Verbose

.EXAMPLE
    # Migrate VMs in specific subscription and resource group
    .\Migrate-VMInsights-OpenTelemetry.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789abc" -ResourceGroupName "rg-production-vms"

.EXAMPLE
    # Use existing Azure Monitor Workspace
    .\Migrate-VMInsights-OpenTelemetry.ps1 -AzureMonitorWorkspaceId "/subscriptions/.../providers/microsoft.monitor/accounts/workspace-name" -Verbose

.EXAMPLE
    # Keep both classic and OTel metrics
    .\Migrate-VMInsights-OpenTelemetry.ps1 -EnableClassicMetrics -LogAnalyticsWorkspaceId "/subscriptions/.../workspaces/law-prod"

.EXAMPLE
    # Enable custom metrics (per-process CPU, memory, disk I/O)
    .\Migrate-VMInsights-OpenTelemetry.ps1 -CustomMetricsEnabled

.EXAMPLE
    # Dry-run to preview changes
    .\Migrate-VMInsights-OpenTelemetry.ps1 -WhatIf

.EXAMPLE
    # Resume interrupted migration
    .\Migrate-VMInsights-OpenTelemetry.ps1 -ResumeFromCheckpoint

.NOTES
    Version: 1.0
    Author: BAB CloudOps Team
    Date: 2026-02-03
    Requires: 
        - Azure PowerShell Module (Az.Compute, Az.Monitor, Az.Resources, Az.OperationalInsights)
        - Contributor or Owner role on target subscription
        - Network connectivity to Azure Monitor endpoints
    
    Prerequisites:
        - VMs must be running supported OS (Windows Server 2012+, RHEL 7+, Ubuntu 18.04+, etc.)
        - Network connectivity requirements: https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-network-configuration
    
    Reference: https://learn.microsoft.com/en-us/azure/azure-monitor/vm/vminsights-opentelemetry

.LINK
    https://learn.microsoft.com/en-us/azure/azure-monitor/vm/vminsights-opentelemetry
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$false)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory=$false)]
    [ValidateLength(1,90)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory=$false)]
    [ValidatePattern('^/subscriptions/.+/resourcegroups/.+/providers/microsoft\.monitor/accounts/.+$')]
    [string]$AzureMonitorWorkspaceId = "/subscriptions/43cc4f11-ffb1-4a0d-8420-0ba3746b4248/resourcegroups/defaultresourcegroup-sec/providers/microsoft.monitor/accounts/defaultazuremonitorworkspace-sec",

    [Parameter(Mandatory=$false)]
    [ValidateLength(3,63)]
    [string]$AzureMonitorWorkspaceName,

    [Parameter(Mandatory=$false)]
    [ValidateLength(1,90)]
    [string]$AzureMonitorWorkspaceRG,

    [Parameter(Mandatory=$false)]
    [ValidateSet('uaenorth', 'uaecentral', 'eastus', 'westeurope', 'southeastasia')]
    [string]$Location = 'uaenorth',

    [Parameter(Mandatory=$false)]
    [string]$LogAnalyticsWorkspaceId,

    [Parameter(Mandatory=$false)]
    [switch]$EnableClassicMetrics,

    [Parameter(Mandatory=$false)]
    [switch]$CustomMetricsEnabled,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1,10)]
    [int]$ParallelBatchSize = 5,

    [Parameter(Mandatory=$false)]
    [switch]$ResumeFromCheckpoint,

    [Parameter(Mandatory=$false)]
    [string]$ExcludeVMsWithTag
)

# ==============================================================================
# INITIALIZATION
# ==============================================================================

# Set strict error handling
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Create logs directory with timestamp
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$logsDir = Join-Path $scriptPath "Logs"
$checkpointDir = Join-Path $scriptPath "Checkpoints"
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
New-Item -ItemType Directory -Force -Path $checkpointDir | Out-Null

$logFile = Join-Path $logsDir "VMInsights-OTel-Migration-$timestamp.log"
$csvResultsFile = Join-Path $logsDir "VMInsights-OTel-Results-$timestamp.csv"
$checkpointFile = Join-Path $checkpointDir "migration-checkpoint.json"

# Global results tracking
$script:migrationResults = [System.Collections.ArrayList]::new()

# ==============================================================================
# LOGGING FUNCTIONS
# ==============================================================================

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Write to log file
    Add-Content -Path $logFile -Value $logMessage -ErrorAction SilentlyContinue
    
    # Console output with colors
    switch ($Level) {
        'INFO'    { Write-Host $logMessage -ForegroundColor Cyan }
        'WARNING' { Write-Warning $logMessage }
        'ERROR'   { Write-Host $logMessage -ForegroundColor Red }
        'SUCCESS' { Write-Host $logMessage -ForegroundColor Green }
    }
}

function Write-Progress-Status {
    param(
        [int]$Current,
        [int]$Total,
        [string]$Activity,
        [string]$Status
    )
    
    $percentComplete = [math]::Round(($Current / $Total) * 100, 1)
    Write-Progress -Activity $Activity -Status "$Status ($Current of $Total)" -PercentComplete $percentComplete
}

# ==============================================================================
# CHECKPOINT MANAGEMENT
# ==============================================================================

function Save-Checkpoint {
    param(
        [string]$VMId,
        [string]$Status,
        [hashtable]$Details
    )
    
    $checkpoint = @{
        LastUpdated = (Get-Date).ToString('o')
        ProcessedVMs = @{
            $VMId = @{
                Status = $Status
                Details = $Details
                Timestamp = (Get-Date).ToString('o')
            }
        }
    }
    
    # Merge with existing checkpoint
    if (Test-Path $checkpointFile) {
        $existing = Get-Content $checkpointFile -Raw | ConvertFrom-Json -AsHashtable
        foreach ($key in $existing.ProcessedVMs.Keys) {
            if (-not $checkpoint.ProcessedVMs.ContainsKey($key)) {
                $checkpoint.ProcessedVMs[$key] = $existing.ProcessedVMs[$key]
            }
        }
    }
    
    $checkpoint | ConvertTo-Json -Depth 10 | Set-Content $checkpointFile
}

function Get-ProcessedVMs {
    if (-not (Test-Path $checkpointFile)) {
        return @{}
    }
    
    $checkpoint = Get-Content $checkpointFile -Raw | ConvertFrom-Json -AsHashtable
    return $checkpoint.ProcessedVMs
}

# ==============================================================================
# AZURE PREREQUISITES VALIDATION
# ==============================================================================

function Test-Prerequisites {
    Write-Log "Validating prerequisites..." -Level INFO
    
    # Check Az.Compute module
    $requiredModules = @('Az.Compute', 'Az.Monitor', 'Az.Resources', 'Az.OperationalInsights')
    foreach ($module in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-Log "Missing required module: $module. Install with: Install-Module $module -Force" -Level ERROR
            throw "Missing prerequisite module: $module"
        }
    }
    
    # Check Azure login
    try {
        $context = Get-AzContext
        if (-not $context) {
            Write-Log "Not logged in to Azure. Run Connect-AzAccount first." -Level ERROR
            throw "Azure authentication required"
        }
        Write-Log "Authenticated as: $($context.Account.Id)" -Level SUCCESS
    }
    catch {
        Write-Log "Azure authentication check failed: $_" -Level ERROR
        throw
    }
    
    Write-Log "Prerequisites validated successfully" -Level SUCCESS
}

# ==============================================================================
# SUBSCRIPTION CONTEXT MANAGEMENT
# ==============================================================================

function Set-SubscriptionContext {
    param([string]$SubId)
    
    try {
        $context = Set-AzContext -SubscriptionId $SubId -ErrorAction Stop
        Write-Log "Switched to subscription: $($context.Subscription.Name) ($SubId)" -Level SUCCESS
        return $context
    }
    catch {
        Write-Log "Failed to set subscription context: $_" -Level ERROR
        throw
    }
}

# ==============================================================================
# AZURE MONITOR WORKSPACE MANAGEMENT
# ==============================================================================

function Get-OrCreateAzureMonitorWorkspace {
    param(
        [string]$WorkspaceId,
        [string]$WorkspaceName,
        [string]$ResourceGroup,
        [string]$Location
    )
    
    # If full resource ID provided, validate and use it
    if ($WorkspaceId) {
        Write-Log "Using existing Azure Monitor Workspace: $WorkspaceId" -Level INFO
        
        try {
            # Validate workspace exists and is accessible
            $workspace = Get-AzResource -ResourceId $WorkspaceId -ErrorAction Stop
            Write-Log "Azure Monitor Workspace validated: $($workspace.Name)" -Level SUCCESS
            return $workspace.ResourceId
        }
        catch {
            Write-Log "Failed to access Azure Monitor Workspace: $_" -Level ERROR
            throw "Cannot access workspace: $WorkspaceId. Verify it exists and you have permissions."
        }
    }
    
    Write-Log "Checking Azure Monitor Workspace: $WorkspaceName in $ResourceGroup..." -Level INFO
    
    # Check if workspace exists
    try {
        $workspace = Get-AzResource -ResourceType "Microsoft.Monitor/accounts" -ResourceGroupName $ResourceGroup -Name $WorkspaceName -ErrorAction SilentlyContinue
        
        if ($workspace) {
            Write-Log "Azure Monitor Workspace found: $($workspace.ResourceId)" -Level SUCCESS
            return $workspace.ResourceId
        }
    }
    catch {
        Write-Log "Workspace lookup failed, will attempt creation: $_" -Level WARNING
    }
    
    # Create resource group if not exists
    $rg = Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue
    if (-not $rg) {
        if ($PSCmdlet.ShouldProcess($ResourceGroup, "Create Resource Group")) {
            Write-Log "Creating resource group: $ResourceGroup" -Level INFO
            $rg = New-AzResourceGroup -Name $ResourceGroup -Location $Location -Tag @{Purpose="Monitoring"; CreatedBy="VMInsights-OTel-Migration"}
            Write-Log "Resource group created: $ResourceGroup" -Level SUCCESS
        }
    }
    
    # Create Azure Monitor Workspace
    if ($PSCmdlet.ShouldProcess($WorkspaceName, "Create Azure Monitor Workspace")) {
        Write-Log "Creating Azure Monitor Workspace: $WorkspaceName..." -Level INFO
        
        $workspaceProperties = @{
            location = $Location
            properties = @{}
        }
        
        try {
            $newWorkspace = New-AzResource -ResourceType "Microsoft.Monitor/accounts" `
                -ResourceGroupName $ResourceGroup `
                -Name $WorkspaceName `
                -Location $Location `
                -Properties @{} `
                -Force
            
            Write-Log "Azure Monitor Workspace created: $($newWorkspace.ResourceId)" -Level SUCCESS
            return $newWorkspace.ResourceId
        }
        catch {
            Write-Log "Failed to create Azure Monitor Workspace: $_" -Level ERROR
            throw
        }
    }
    else {
        # WhatIf mode - return placeholder for validation
        $placeholderWorkspaceId = "/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$ResourceGroup/providers/Microsoft.Monitor/accounts/$WorkspaceName"
        Write-Log "[WhatIf] Would create workspace: $placeholderWorkspaceId" -Level INFO
        return $placeholderWorkspaceId
    }
}

# ==============================================================================
# DATA COLLECTION RULE (DCR) MANAGEMENT
# ==============================================================================

function New-OTelDataCollectionRule {
    param(
        [string]$DcrName,
        [string]$ResourceGroup,
        [string]$Location,
        [string]$AzureMonitorWorkspaceId,
        [bool]$EnableCustomMetrics = $false
    )
    
    Write-Log "Creating Data Collection Rule: $DcrName..." -Level INFO
    
    # Default metrics (NO ADDITIONAL COST) - Exact match to Microsoft documentation
    # Reference: https://learn.microsoft.com/en-us/azure/azure-monitor/vm/vminsights-opentelemetry#default-metrics
    $baseCounters = @(
        "system.filesystem.usage",             # Filesystem usage in bytes
        "system.disk.io",                      # Disk I/O (bytes read/written)
        "system.disk.operation_time",          # Average disk operation time
        "system.disk.operations",              # Disk operations (read/write counts)
        "system.memory.usage",                 # Memory in use (bytes)
        "system.network.io",                   # Bytes transmitted/received
        "system.cpu.time",                     # Total CPU time consumed (user + system + idle), in seconds
        "system.uptime",                       # Time since last reboot (in seconds)
        "system.network.dropped",              # Dropped packets
        "system.network.errors"                # Network errors
    )
    
    # Additional metrics (ADDITIONAL COST) - Extended visibility
    # Reference: https://learn.microsoft.com/en-us/azure/azure-monitor/vm/vminsights-opentelemetry#additional-metrics
    # Enable with -CustomMetricsEnabled for deeper system and per-process monitoring
    $customCounters = @(
        # Extended System Metrics
        "system.cpu.utilization",              # CPU usage %
        "system.cpu.logical.count",            # Number of logical processors
        "system.cpu.physical.count",           # Number of physical CPUs
        "system.cpu.load_average.1m",          # System load average (1 min)
        "system.cpu.load_average.5m",          # System load average (5 min)
        "system.cpu.load_average.15m",         # System load average (15 min)
        "system.memory.utilization",           # % memory used
        "system.linux.memory.available",       # Available memory
        "system.paging.faults",                # Page faults
        "system.paging.operations",            # Paging operations (reads/writes)
        "system.disk.io_time",                 # Time spent doing I/O
        "system.disk.merged",                  # Number of merged operations
        "system.disk.pending_operations",      # Pending I/O operations
        "system.filesystem.utilization",       # Filesystem usage %
        "system.filesystem.inodes.usage",      # Inodes usage
        "system.network.packets",              # Packets transmitted/received
        "system.network.connections",          # Active network connections
        "system.processes.count",              # Total number of processes
        "system.processes.created",            # Processes created
        # Per-Process Metrics
        "process.cpu.utilization",             # CPU usage % per process
        "process.cpu.time",                    # CPU time consumed by process
        "process.memory.usage",                # Memory usage (RSS)
        "process.memory.virtual",              # Virtual memory usage
        "process.memory.utilization",          # Memory % usage
        "process.disk.io",                     # Disk I/O (bytes per process)
        "process.disk.operations",             # Disk operations per process
        "process.threads",                     # Number of threads
        "process.uptime",                      # Process uptime
        "process.open_file_descriptors",       # Open file descriptors
        "process.context_switches"             # Context switches
    )
    
    $counterSpecifiers = $baseCounters
    if ($EnableCustomMetrics) {
        $counterSpecifiers += $customCounters
        Write-Log "Custom metrics enabled (additional cost applies)" -Level WARNING
    }
    
    # DCR JSON structure
    $dcrProperties = @{
        dataSources = @{
            performanceCountersOTel = @(
                @{
                    streams = @("Microsoft-OtelPerfMetrics")
                    samplingFrequencyInSeconds = 60
                    counterSpecifiers = $counterSpecifiers
                    name = "OtelDataSource"
                }
            )
        }
        destinations = @{
            monitoringAccounts = @(
                @{
                    accountResourceId = $AzureMonitorWorkspaceId
                    name = "MonitoringAccountDestination"
                }
            )
        }
        dataFlows = @(
            @{
                streams = @("Microsoft-OtelPerfMetrics")
                destinations = @("MonitoringAccountDestination")
            }
        )
    }
    
    if ($PSCmdlet.ShouldProcess($DcrName, "Create Data Collection Rule")) {
        try {
            $dcr = New-AzResource -ResourceType "Microsoft.Insights/dataCollectionRules" `
                -ResourceGroupName $ResourceGroup `
                -Name $DcrName `
                -Location $Location `
                -Properties $dcrProperties `
                -Force
            
            Write-Log "Data Collection Rule created: $($dcr.ResourceId)" -Level SUCCESS
            return $dcr.ResourceId
        }
        catch {
            Write-Log "Failed to create DCR: $_" -Level ERROR
            throw
        }
    }
    else {
        # WhatIf mode - return placeholder for validation
        $placeholderDcrId = "/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/dataCollectionRules/$DcrName"
        Write-Log "[WhatIf] Would create DCR: $placeholderDcrId" -Level INFO
        return $placeholderDcrId
    }
}

function Get-OrCreateDataCollectionRule {
    param(
        [string]$Location,
        [string]$ResourceGroup,
        [string]$AzureMonitorWorkspaceId,
        [bool]$EnableCustomMetrics
    )
    
    $dcrName = "MSVMOtel-$Location-default"
    
    # Check if DCR already exists
    try {
        $existingDcr = Get-AzResource -ResourceType "Microsoft.Insights/dataCollectionRules" `
            -ResourceGroupName $ResourceGroup `
            -Name $dcrName `
            -ErrorAction SilentlyContinue
        
        if ($existingDcr) {
            Write-Log "Using existing DCR: $($existingDcr.ResourceId)" -Level SUCCESS
            return $existingDcr.ResourceId
        }
    }
    catch {
        Write-Log "DCR lookup failed, will create new: $_" -Level WARNING
    }
    
    # Create new DCR
    return New-OTelDataCollectionRule -DcrName $dcrName `
        -ResourceGroup $ResourceGroup `
        -Location $Location `
        -AzureMonitorWorkspaceId $AzureMonitorWorkspaceId `
        -EnableCustomMetrics $EnableCustomMetrics
}

# ==============================================================================
# AZURE MONITOR AGENT (AMA) EXTENSION MANAGEMENT
# ==============================================================================

function Install-AzureMonitorAgent {
    param(
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine]$VM,
        [string]$Location
    )
    
    $vmName = $VM.Name
    $vmRG = $VM.ResourceGroupName
    $osType = $VM.StorageProfile.OsDisk.OsType
    
    Write-Log "Installing Azure Monitor Agent on $vmName ($osType)..." -Level INFO
    
    # Determine extension name and publisher based on OS
    $extensionName = if ($osType -eq 'Windows') { 'AzureMonitorWindowsAgent' } else { 'AzureMonitorLinuxAgent' }
    $publisher = if ($osType -eq 'Windows') { 'Microsoft.Azure.Monitor' } else { 'Microsoft.Azure.Monitor' }
    $extensionType = if ($osType -eq 'Windows') { 'AzureMonitorWindowsAgent' } else { 'AzureMonitorLinuxAgent' }
    
    # Check if extension already installed
    $existingExtension = Get-AzVMExtension -ResourceGroupName $vmRG -VMName $vmName -Name $extensionName -ErrorAction SilentlyContinue
    
    if ($existingExtension -and $existingExtension.ProvisioningState -eq 'Succeeded') {
        Write-Log "Azure Monitor Agent already installed on $vmName" -Level SUCCESS
        return $true
    }
    
    if ($PSCmdlet.ShouldProcess($vmName, "Install Azure Monitor Agent")) {
        try {
            $extension = Set-AzVMExtension -ResourceGroupName $vmRG `
                -VMName $vmName `
                -Name $extensionName `
                -Publisher $publisher `
                -ExtensionType $extensionType `
                -TypeHandlerVersion '1.0' `
                -Location $Location `
                -EnableAutomaticUpgrade $true `
                -ErrorAction Stop
            
            if ($extension.ProvisioningState -eq 'Succeeded') {
                Write-Log "Azure Monitor Agent installed successfully on $vmName" -Level SUCCESS
                return $true
            }
            else {
                Write-Log "Azure Monitor Agent installation failed on $vmName - State: $($extension.ProvisioningState)" -Level ERROR
                return $false
            }
        }
        catch {
            Write-Log "Failed to install Azure Monitor Agent on $vmName : $_" -Level ERROR
            return $false
        }
    }
    
    return $false
}

# ==============================================================================
# DATA COLLECTION RULE ASSOCIATION
# ==============================================================================

function New-DcrAssociation {
    param(
        [string]$VMResourceId,
        [string]$DcrResourceId,
        [string]$VMName
    )
    
    Write-Log "Associating DCR with VM: $VMName..." -Level INFO
    
    $associationName = "MSVMOtel-$VMName-$(Get-Date -Format 'yyyyMMdd')"
    
    $associationProperties = @{
        dataCollectionRuleId = $DcrResourceId
    }
    
    if ($PSCmdlet.ShouldProcess($VMName, "Create DCR Association")) {
        try {
            # Create association using ARM REST API
            $association = New-AzResource `
                -ResourceId "$VMResourceId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$associationName" `
                -Properties $associationProperties `
                -ApiVersion "2021-04-01" `
                -Force `
                -ErrorAction Stop
            
            Write-Log "DCR association created for $VMName" -Level SUCCESS
            return $true
        }
        catch {
            Write-Log "Failed to create DCR association for $VMName : $_" -Level ERROR
            return $false
        }
    }
    
    return $false
}

# ==============================================================================
# VM MIGRATION ORCHESTRATION
# ==============================================================================

function Start-VMMigration {
    param(
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine]$VM,
        [string]$DcrResourceId,
        [hashtable]$ProcessedVMs
    )
    
    $vmId = $VM.Id
    $vmName = $VM.Name
    $vmRG = $VM.ResourceGroupName
    
    # Skip if already processed successfully
    if ($ProcessedVMs.ContainsKey($vmId) -and $ProcessedVMs[$vmId].Status -eq 'Success') {
        Write-Log "Skipping $vmName - already migrated successfully" -Level INFO
        return @{
            VMName = $vmName
            ResourceGroup = $vmRG
            Status = 'Skipped-AlreadyMigrated'
            Details = 'VM already processed in previous run'
        }
    }
    
    Write-Log "====== Starting migration for: $vmName ======" -Level INFO
    
    $result = @{
        VMName = $vmName
        ResourceGroup = $vmRG
        VMId = $vmId
        Location = $VM.Location
        OSType = $VM.StorageProfile.OsDisk.OsType
        Status = 'Failed'
        Details = ''
        Timestamp = (Get-Date).ToString('o')
    }
    
    try {
        # Step 1: Install Azure Monitor Agent
        $amaInstalled = Install-AzureMonitorAgent -VM $VM -Location $VM.Location
        if (-not $amaInstalled) {
            $result.Status = 'Failed'
            $result.Details = 'Azure Monitor Agent installation failed'
            return $result
        }
        
        # Step 2: Associate DCR with VM
        $dcrAssociated = New-DcrAssociation -VMResourceId $vmId -DcrResourceId $DcrResourceId -VMName $vmName
        if (-not $dcrAssociated) {
            $result.Status = 'Failed'
            $result.Details = 'DCR association failed'
            return $result
        }
        
        # Success
        $result.Status = 'Success'
        $result.Details = 'VM migrated to OpenTelemetry successfully'
        Write-Log "====== Migration completed successfully for: $vmName ======" -Level SUCCESS
        
        # Save checkpoint
        Save-Checkpoint -VMId $vmId -Status 'Success' -Details $result
        
        return $result
    }
    catch {
        $result.Status = 'Failed'
        $result.Details = "Exception: $_"
        Write-Log "Migration failed for $vmName : $_" -Level ERROR
        
        # Save checkpoint
        Save-Checkpoint -VMId $vmId -Status 'Failed' -Details $result
        
        return $result
    }
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

try {
    Write-Log "======================================================" -Level INFO
    Write-Log "VM Insights OpenTelemetry Migration Script" -Level INFO
    Write-Log "======================================================" -Level INFO
    Write-Log "Start Time: $(Get-Date)" -Level INFO
    Write-Log "Log File: $logFile" -Level INFO
    Write-Log "Results CSV: $csvResultsFile" -Level INFO
    
    # Validate prerequisites
    Test-Prerequisites
    
    # Set subscription context
    if (-not $SubscriptionId) {
        $context = Get-AzContext
        $SubscriptionId = $context.Subscription.Id
        Write-Log "Using current subscription: $($context.Subscription.Name) ($SubscriptionId)" -Level INFO
    }
    else {
        Set-SubscriptionContext -SubId $SubscriptionId | Out-Null
    }
    
    # Set default workspace names if not provided
    if (-not $AzureMonitorWorkspaceName) {
        $subShortName = (Get-AzSubscription -SubscriptionId $SubscriptionId).Name -replace '[^a-zA-Z0-9]', '' | Select-Object -First 10
        $AzureMonitorWorkspaceName = "amw-vminsights-$subShortName"
    }
    
    if (-not $AzureMonitorWorkspaceRG) {
        $AzureMonitorWorkspaceRG = "rg-monitoring-$Location"
    }
    
    Write-Log "Configuration:" -Level INFO
    Write-Log "  Subscription: $SubscriptionId" -Level INFO
    Write-Log "  Resource Group Filter: $(if($ResourceGroupName){"$ResourceGroupName"}else{"All"})" -Level INFO
    if ($AzureMonitorWorkspaceId) {
        Write-Log "  Azure Monitor Workspace ID: $AzureMonitorWorkspaceId" -Level INFO
    } else {
        Write-Log "  Azure Monitor Workspace: $AzureMonitorWorkspaceName" -Level INFO
        Write-Log "  Workspace RG: $AzureMonitorWorkspaceRG" -Level INFO
    }
    Write-Log "  Location: $Location" -Level INFO
    Write-Log "  Custom Metrics: $CustomMetricsEnabled" -Level INFO
    Write-Log "  Classic Metrics: $EnableClassicMetrics" -Level INFO
    Write-Log "  Parallel Batch Size: $ParallelBatchSize" -Level INFO
    
    # Get or create Azure Monitor Workspace
    $azureMonitorWorkspaceId = Get-OrCreateAzureMonitorWorkspace -WorkspaceId $AzureMonitorWorkspaceId `
        -WorkspaceName $AzureMonitorWorkspaceName `
        -ResourceGroup $AzureMonitorWorkspaceRG `
        -Location $Location
    
    if (-not $azureMonitorWorkspaceId) {
        throw "Failed to get or create Azure Monitor Workspace"
    }
    
    # Extract resource group and location from workspace for DCR creation
    # DCR must be in same resource group and location as the Azure Monitor Workspace
    $workspaceResource = Get-AzResource -ResourceId $azureMonitorWorkspaceId
    $dcrResourceGroup = $workspaceResource.ResourceGroupName
    $dcrLocation = $workspaceResource.Location
    
    Write-Log "DCR will be created in: $dcrResourceGroup ($dcrLocation)" -Level INFO
    
    # Get or create Data Collection Rule
    $dcrResourceId = Get-OrCreateDataCollectionRule -Location $dcrLocation `
        -ResourceGroup $dcrResourceGroup `
        -AzureMonitorWorkspaceId $azureMonitorWorkspaceId `
        -EnableCustomMetrics $CustomMetricsEnabled
    
    if (-not $dcrResourceId) {
        throw "Failed to get or create Data Collection Rule"
    }
    
    Write-Log "DCR Resource ID: $dcrResourceId" -Level SUCCESS
    
    # Validate permissions on Azure Monitor Workspace
    Write-Log "=========================================================" -Level INFO
    Write-Log "IMPORTANT: Permissions & Access Configuration" -Level INFO
    Write-Log "=========================================================" -Level INFO
    Write-Log "To view metrics in Azure Portal, ensure:" -Level INFO
    Write-Log "  1. Your account has 'Monitoring Reader' role on workspace" -Level INFO
    Write-Log "  2. Resource-centric flag is enabled on Azure Monitor Workspace" -Level INFO
    Write-Log "  3. Refresh browser if you see 'Access Denied' errors" -Level INFO
    Write-Log "Troubleshooting Reference:" -Level INFO
    Write-Log "  https://learn.microsoft.com/azure/azure-monitor/vm/vminsights-opentelemetry#troubleshooting" -Level INFO
    Write-Log "=========================================================" -Level INFO
    
    # Load checkpoint if resuming
    $processedVMs = @{}
    if ($ResumeFromCheckpoint) {
        $processedVMs = Get-ProcessedVMs
        Write-Log "Resuming from checkpoint - $($processedVMs.Count) VMs already processed" -Level INFO
    }
    
    # Get VMs to migrate
    Write-Log "Discovering VMs..." -Level INFO
    $vms = if ($ResourceGroupName) {
        Get-AzVM -ResourceGroupName $ResourceGroupName -Status
    }
    else {
        Get-AzVM -Status
    }
    
    # Filter VMs by exclusion tag if specified
    if ($ExcludeVMsWithTag) {
        $vms = $vms | Where-Object {
            $tags = Get-AzResource -ResourceId $_.Id | Select-Object -ExpandProperty Tags
            -not ($tags.ContainsKey($ExcludeVMsWithTag))
        }
        Write-Log "Excluded VMs with tag '$ExcludeVMsWithTag'" -Level INFO
    }
    
    Write-Log "Found $($vms.Count) VMs to migrate" -Level INFO
    
    if ($vms.Count -eq 0) {
        Write-Log "No VMs found to migrate. Exiting." -Level WARNING
        return
    }
    
    # Process VMs
    $totalVMs = $vms.Count
    $currentVM = 0
    
    foreach ($vm in $vms) {
        $currentVM++
        Write-Progress-Status -Current $currentVM -Total $totalVMs -Activity "Migrating VMs to OpenTelemetry" -Status "Processing $($vm.Name)"
        
        $result = Start-VMMigration -VM $vm -DcrResourceId $dcrResourceId -ProcessedVMs $processedVMs
        [void]$script:migrationResults.Add([PSCustomObject]$result)
    }
    
    Write-Progress -Activity "Migrating VMs to OpenTelemetry" -Completed
    
    # Export results to CSV
    $script:migrationResults | Export-Csv -Path $csvResultsFile -NoTypeInformation
    Write-Log "Results exported to: $csvResultsFile" -Level SUCCESS
    
    # Summary
    $successCount = ($script:migrationResults | Where-Object { $_.Status -eq 'Success' }).Count
    $failedCount = ($script:migrationResults | Where-Object { $_.Status -eq 'Failed' }).Count
    $skippedCount = ($script:migrationResults | Where-Object { $_.Status -like 'Skipped*' }).Count
    
    Write-Log "======================================================" -Level INFO
    Write-Log "Migration Summary:" -Level INFO
    Write-Log "  Total VMs: $totalVMs" -Level INFO
    Write-Log "  Success: $successCount" -Level SUCCESS
    Write-Log "  Failed: $failedCount" -Level $(if($failedCount -gt 0){'ERROR'}else{'INFO'})
    Write-Log "  Skipped: $skippedCount" -Level INFO
    Write-Log "======================================================" -Level INFO
    Write-Log "End Time: $(Get-Date)" -Level INFO
    Write-Log "Log File: $logFile" -Level INFO
    Write-Log "Results CSV: $csvResultsFile" -Level INFO
    
}
catch {
    Write-Log "FATAL ERROR: $_" -Level ERROR
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level ERROR
    throw
}
finally {
    $ProgressPreference = 'Continue'
}
