<#
.SYNOPSIS
    Create a new Azure Monitor Workspace and DCR for VM Insights OpenTelemetry

.DESCRIPTION
    This script creates a fresh Azure Monitor Workspace and Data Collection Rule (DCR)
    with proper configuration for VM Insights OpenTelemetry metrics.
    
    Use this when you want to start fresh or the existing workspace has configuration issues.

.PARAMETER WorkspaceName
    Name for the new Azure Monitor Workspace. Default: "amw-vminsights-otel-{timestamp}"

.PARAMETER ResourceGroupName
    Resource group for the workspace. If not exists, will be created. Default: "rg-monitoring-swedencentral"

.PARAMETER Location
    Azure region. Default: "swedencentral"

.PARAMETER CustomMetricsEnabled
    Enable additional custom metrics (per-process monitoring). Default: false

.EXAMPLE
    .\Create-New-Workspace-And-DCR.ps1 -Verbose

.EXAMPLE
    .\Create-New-Workspace-And-DCR.ps1 -WorkspaceName "my-vminsights-workspace" -Location "swedencentral"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$WorkspaceName,

    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "rg-monitoring-swedencentral",

    [Parameter(Mandatory=$false)]
    [ValidateSet('swedencentral', 'uaenorth', 'uaecentral', 'eastus', 'westeurope', 'southeastasia')]
    [string]$Location = 'swedencentral',

    [Parameter(Mandatory=$false)]
    [switch]$CustomMetricsEnabled
)

$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Create New Azure Monitor Workspace & DCR" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Generate unique workspace name if not provided
if (-not $WorkspaceName) {
    $timestamp = Get-Date -Format 'yyyyMMddHHmm'
    $WorkspaceName = "amw-vminsights-otel-$timestamp"
}

$context = Get-AzContext
$subscriptionId = $context.Subscription.Id

Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Subscription: $($context.Subscription.Name)" -ForegroundColor White
Write-Host "  Subscription ID: $subscriptionId" -ForegroundColor White
Write-Host "  Workspace Name: $WorkspaceName" -ForegroundColor White
Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor White
Write-Host "  Location: $Location" -ForegroundColor White
Write-Host "  Custom Metrics: $CustomMetricsEnabled" -ForegroundColor White
Write-Host ""

# Step 1: Create Resource Group
Write-Host "Step 1: Creating/Verifying Resource Group..." -ForegroundColor Cyan
$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
    Write-Host "  Creating resource group: $ResourceGroupName" -ForegroundColor Yellow
    $rg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag @{
        Purpose = "Monitoring"
        CreatedBy = "VMInsights-OTel-Setup"
        CreatedDate = (Get-Date).ToString('yyyy-MM-dd')
    }
    Write-Host "  ✓ Resource group created" -ForegroundColor Green
} else {
    Write-Host "  ✓ Resource group already exists" -ForegroundColor Green
}
Write-Host ""

# Step 2: Create Azure Monitor Workspace
Write-Host "Step 2: Creating Azure Monitor Workspace..." -ForegroundColor Cyan
try {
    $workspace = New-AzResource -ResourceType "Microsoft.Monitor/accounts" `
        -ResourceGroupName $ResourceGroupName `
        -Name $WorkspaceName `
        -Location $Location `
        -Properties @{
            publicNetworkAccess = "Enabled"
        } `
        -Tag @{
            Purpose = "VMInsights-OpenTelemetry"
            CreatedBy = "Automation"
            CreatedDate = (Get-Date).ToString('yyyy-MM-dd')
        } `
        -Force
    
    Write-Host "  ✓ Azure Monitor Workspace created" -ForegroundColor Green
    Write-Host "  Workspace ID: $($workspace.ResourceId)" -ForegroundColor Gray
} catch {
    Write-Host "  ❌ Failed to create workspace: $_" -ForegroundColor Red
    throw
}
Write-Host ""

# Step 3: Wait for workspace to be ready
Write-Host "Step 3: Waiting for workspace provisioning (10 seconds)..." -ForegroundColor Cyan
Start-Sleep -Seconds 10
Write-Host "  ✓ Workspace ready" -ForegroundColor Green
Write-Host ""

# Step 4: Get current user and assign permissions
Write-Host "Step 4: Configuring permissions..." -ForegroundColor Cyan
try {
    $currentUser = Get-AzADUser -UserPrincipalName $context.Account.Id
    $userObjectId = $currentUser.Id
    
    # Assign Monitoring Reader
    Write-Host "  Assigning Monitoring Reader role..." -ForegroundColor Yellow
    New-AzRoleAssignment -ObjectId $userObjectId `
        -RoleDefinitionName "Monitoring Reader" `
        -Scope $workspace.ResourceId `
        -ErrorAction SilentlyContinue | Out-Null
    
    # Assign Monitoring Data Reader
    Write-Host "  Assigning Monitoring Data Reader role..." -ForegroundColor Yellow
    New-AzRoleAssignment -ObjectId $userObjectId `
        -RoleDefinitionName "Monitoring Data Reader" `
        -Scope $workspace.ResourceId `
        -ErrorAction SilentlyContinue | Out-Null
    
    Write-Host "  ✓ Permissions configured" -ForegroundColor Green
} catch {
    Write-Host "  ⚠ Could not assign permissions automatically" -ForegroundColor Yellow
    Write-Host "    You may need to assign Monitoring Reader role manually" -ForegroundColor Yellow
}
Write-Host ""

# Step 5: Create Data Collection Rule
Write-Host "Step 5: Creating Data Collection Rule..." -ForegroundColor Cyan

$dcrName = "MSVMOtel-$Location-$(Get-Date -Format 'yyyyMMdd')"

# Default metrics (no additional cost)
$baseCounters = @(
    "system.filesystem.usage",
    "system.disk.io",
    "system.disk.operation_time",
    "system.disk.operations",
    "system.memory.usage",
    "system.network.io",
    "system.cpu.time",
    "system.uptime",
    "system.network.dropped",
    "system.network.errors"
)

# Custom metrics (additional cost)
$customCounters = @(
    "system.cpu.utilization", "system.cpu.logical.count", "system.cpu.physical.count",
    "system.cpu.load_average.1m", "system.cpu.load_average.5m", "system.cpu.load_average.15m",
    "system.memory.utilization", "system.linux.memory.available",
    "system.paging.faults", "system.paging.operations",
    "system.disk.io_time", "system.disk.merged", "system.disk.pending_operations",
    "system.filesystem.utilization", "system.filesystem.inodes.usage",
    "system.network.packets", "system.network.connections",
    "system.processes.count", "system.processes.created",
    "process.cpu.utilization", "process.cpu.time", "process.memory.usage",
    "process.memory.virtual", "process.memory.utilization",
    "process.disk.io", "process.disk.operations",
    "process.threads", "process.uptime",
    "process.open_file_descriptors", "process.context_switches"
)

$counterSpecifiers = $baseCounters
if ($CustomMetricsEnabled) {
    $counterSpecifiers += $customCounters
    Write-Host "  ℹ Custom metrics enabled (additional cost applies)" -ForegroundColor Yellow
}

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
                accountResourceId = $workspace.ResourceId
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

try {
    $dcr = New-AzResource -ResourceType "Microsoft.Insights/dataCollectionRules" `
        -ResourceGroupName $ResourceGroupName `
        -Name $dcrName `
        -Location $Location `
        -Properties $dcrProperties `
        -Tag @{
            Purpose = "VMInsights-OpenTelemetry"
            Workspace = $WorkspaceName
        } `
        -Force
    
    Write-Host "  ✓ Data Collection Rule created" -ForegroundColor Green
    Write-Host "  DCR Name: $dcrName" -ForegroundColor Gray
    Write-Host "  DCR ID: $($dcr.ResourceId)" -ForegroundColor Gray
    Write-Host "  Metrics: $($counterSpecifiers.Count) counters configured" -ForegroundColor Gray
} catch {
    Write-Host "  ❌ Failed to create DCR: $_" -ForegroundColor Red
    throw
}
Write-Host ""

# Step 6: Save configuration for migration script
Write-Host "Step 6: Saving configuration..." -ForegroundColor Cyan

$config = @{
    WorkspaceId = $workspace.ResourceId
    WorkspaceName = $WorkspaceName
    DcrId = $dcr.ResourceId
    DcrName = $dcrName
    ResourceGroup = $ResourceGroupName
    Location = $Location
    SubscriptionId = $subscriptionId
    CreatedDate = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    CustomMetricsEnabled = $CustomMetricsEnabled.IsPresent
}

$configFile = "New-Workspace-Config.json"
$config | ConvertTo-Json -Depth 10 | Set-Content $configFile
Write-Host "  ✓ Configuration saved to: $configFile" -ForegroundColor Green
Write-Host ""

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "✓ SETUP COMPLETE!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "📋 Resources Created:" -ForegroundColor Yellow
Write-Host "  • Azure Monitor Workspace: $WorkspaceName" -ForegroundColor White
Write-Host "  • Data Collection Rule: $dcrName" -ForegroundColor White
Write-Host "  • Resource Group: $ResourceGroupName" -ForegroundColor White
Write-Host "  • Location: $Location" -ForegroundColor White
Write-Host ""
Write-Host "🎯 Next Steps:" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. Migrate VMs to use this new workspace:" -ForegroundColor White
Write-Host "   .\Migrate-VMInsights-OpenTelemetry.ps1 ``" -ForegroundColor Cyan
Write-Host "       -AzureMonitorWorkspaceId '$($workspace.ResourceId)' ``" -ForegroundColor Cyan
Write-Host "       -ResourceGroupName 'YOUR-VM-RESOURCE-GROUP' ``" -ForegroundColor Cyan
Write-Host "       -Verbose" -ForegroundColor Cyan
Write-Host ""
Write-Host "2. Or migrate ALL VMs in subscription:" -ForegroundColor White
Write-Host "   .\Migrate-VMInsights-OpenTelemetry.ps1 ``" -ForegroundColor Cyan
Write-Host "       -AzureMonitorWorkspaceId '$($workspace.ResourceId)' ``" -ForegroundColor Cyan
Write-Host "       -Verbose" -ForegroundColor Cyan
Write-Host ""
Write-Host "3. Wait 10-15 minutes after migration for metrics to appear" -ForegroundColor White
Write-Host ""
Write-Host "4. View metrics in Azure Portal:" -ForegroundColor White
Write-Host "   VM → Monitoring → Insights → Performance" -ForegroundColor Gray
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan

# Output workspace ID for easy copy-paste
Write-Host ""
Write-Host "💾 Copy this Workspace ID for migration:" -ForegroundColor Yellow
Write-Host $workspace.ResourceId -ForegroundColor Green
Write-Host ""
