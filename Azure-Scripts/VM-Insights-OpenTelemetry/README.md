# VM Insights OpenTelemetry Migration

Automate the migration of Azure VMs to the new OpenTelemetry-based VM insights monitoring solution.

## Overview

This script migrates all VMs in an Azure subscription from classic Log Analytics-based VM insights to the modern OpenTelemetry (OTel) metrics pipeline. The OTel approach offers:

- **Lower cost**: Metrics stored in Azure Monitor Workspace vs Log Analytics
- **Faster queries**: Native metric storage with PromQL support
- **Unified schema**: Consistent naming across Windows and Linux
- **Richer metrics**: Per-process CPU, memory, disk I/O, and more
- **Standards-based**: OpenTelemetry industry standard

## Benefits of OpenTelemetry for VM Insights

| Feature | Classic (Log Analytics) | OpenTelemetry |
|---------|------------------------|---------------|
| **Storage** | Log Analytics workspace (expensive) | Azure Monitor Workspace (cost-efficient) |
| **Query Performance** | KQL on logs (slower) | PromQL on metrics (faster) |
| **Schema** | Different for Windows/Linux | Unified across platforms |
| **Per-process metrics** | Limited | Full support (CPU, memory, disk I/O) |
| **Onboarding** | Complex DCR configuration | Simplified setup |

## What the Script Does

1. **Validates Prerequisites**
   - Azure PowerShell modules (Az.Compute, Az.Monitor, Az.Resources)
   - Azure authentication and permissions
   - Network connectivity requirements

2. **Creates Infrastructure** (if not exists)
   - Azure Monitor Workspace for OTel metrics
   - Data Collection Rule (DCR) with default or custom metrics
   - Resource groups for monitoring resources

3. **Migrates Each VM**
   - Installs Azure Monitor Agent (AMA) extension
   - Associates VM with Data Collection Rule
   - Enables OpenTelemetry metric collection

4. **Tracks Progress**
   - Checkpoint file for resuming interrupted runs
   - Detailed logging with timestamps
   - CSV export of migration results

## Prerequisites

### Azure Permissions
- **Contributor** or **Owner** role on target subscription
- Permissions to create:
  - Resource groups
  - Azure Monitor Workspaces
  - Data Collection Rules
  - VM extensions

### Software Requirements
```powershell
# Required PowerShell modules
Install-Module -Name Az.Compute -Force
Install-Module -Name Az.Monitor -Force
Install-Module -Name Az.Resources -Force
Install-Module -Name Az.OperationalInsights -Force

# Login to Azure
Connect-AzAccount
```

### VM Requirements
- Supported OS versions:
  - **Windows**: Server 2012 R2, 2016, 2019, 2022
  - **Linux**: RHEL 7+, Ubuntu 18.04+, SLES 12+, Debian 9+
- Network connectivity to Azure Monitor endpoints
- See: [Azure Monitor Agent network configuration](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-network-configuration)

## Usage Examples

### Basic Migration (Current Subscription, OTel Only)
```powershell
.\Migrate-VMInsights-OpenTelemetry.ps1 -Verbose
```
This will:
- Migrate all VMs in current subscription
- Create default Azure Monitor Workspace
- Disable classic log-based metrics (OTel only)

### Specific Subscription and Resource Group
```powershell
.\Migrate-VMInsights-OpenTelemetry.ps1 `
    -SubscriptionId "12345678-1234-1234-1234-123456789abc" `
    -ResourceGroupName "rg-production-vms" `
    -Verbose
```

### Keep Both Classic and OTel Metrics
```powershell
.\Migrate-VMInsights-OpenTelemetry.ps1 `
    -EnableClassicMetrics `
    -LogAnalyticsWorkspaceId "/subscriptions/.../workspaces/law-prod" `
    -Verbose
```

### Enable Custom Metrics (Per-Process Monitoring)
```powershell
.\Migrate-VMInsights-OpenTelemetry.ps1 `
    -CustomMetricsEnabled `
    -Verbose
```
**Note**: Custom metrics incur additional cost. Includes:
- `process.cpu.utilization` - Per-process CPU usage
- `process.memory.usage` - Per-process memory
- `process.disk.io` - Per-process disk I/O
- `system.cpu.utilization` - System CPU percentage
- And more (see Metrics Reference below)

### Dry-Run (Preview Changes)
```powershell
.\Migrate-VMInsights-OpenTelemetry.ps1 -WhatIf
```

### Resume Interrupted Migration
```powershell
.\Migrate-VMInsights-OpenTelemetry.ps1 -ResumeFromCheckpoint -Verbose
```

### Exclude VMs by Tag
```powershell
.\Migrate-VMInsights-OpenTelemetry.ps1 `
    -ExcludeVMsWithTag "ExcludeFromMonitoring" `
    -Verbose
```

## Parameters

| Parameter | Required | Description | Default |
|-----------|----------|-------------|---------|
| `SubscriptionId` | No | Target subscription ID | Current subscription |
| `ResourceGroupName` | No | Specific resource group (optional) | All VMs |
| `AzureMonitorWorkspaceName` | No | Azure Monitor Workspace name | `amw-vminsights-{sub}` |
| `AzureMonitorWorkspaceRG` | No | Workspace resource group | `rg-monitoring-{location}` |
| `Location` | No | Azure region | `uaenorth` |
| `LogAnalyticsWorkspaceId` | No | Log Analytics workspace (if keeping classic) | None |
| `EnableClassicMetrics` | No | Keep classic metrics alongside OTel | `false` |
| `CustomMetricsEnabled` | No | Enable additional metrics (extra cost) | `false` |
| `ParallelBatchSize` | No | Number of VMs to process in parallel | `5` |
| `ResumeFromCheckpoint` | No | Resume from last checkpoint | `false` |
| `ExcludeVMsWithTag` | No | Tag name to exclude VMs | None |
| `WhatIf` | No | Dry-run mode (no changes) | `false` |

## Outputs

### Log Files
```
Logs/
├── VMInsights-OTel-Migration-20260203-143022.log  # Detailed log
└── VMInsights-OTel-Results-20260203-143022.csv    # Results CSV
```

### CSV Results Format
```csv
VMName,ResourceGroup,VMId,Location,OSType,Status,Details,Timestamp
vm-web-01,rg-prod,/subscriptions/.../vm-web-01,uaenorth,Linux,Success,VM migrated successfully,2026-02-03T14:30:45Z
vm-db-01,rg-prod,/subscriptions/.../vm-db-01,uaenorth,Windows,Failed,AMA installation failed,2026-02-03T14:32:10Z
```

### Checkpoint File
```json
{
  "LastUpdated": "2026-02-03T14:35:00Z",
  "ProcessedVMs": {
    "/subscriptions/.../vm-web-01": {
      "Status": "Success",
      "Details": {...},
      "Timestamp": "2026-02-03T14:30:45Z"
    }
  }
}
```

## Metrics Reference

### Default Metrics (No Additional Cost)
These metrics are collected automatically at no extra charge:

| Metric | Description |
|--------|-------------|
| `system.uptime` | Time since last reboot (seconds) |
| `system.cpu.time` | Total CPU time (user + system + idle) |
| `system.memory.usage` | Memory in use (bytes) |
| `system.network.io` | Network bytes transmitted/received |
| `system.network.dropped` | Dropped packets |
| `system.network.errors` | Network errors |
| `system.disk.io` | Disk I/O (bytes read/written) |
| `system.disk.operations` | Disk operations (read/write counts) |
| `system.filesystem.usage` | Filesystem usage in bytes |
| `system.disk.operation_time` | Average disk operation time |

### Additional Custom Metrics (Extra Cost)
Enable with `-CustomMetricsEnabled` flag:

| Metric | Description |
|--------|-------------|
| `system.cpu.utilization` | CPU usage percentage |
| `system.memory.utilization` | Memory usage percentage |
| `system.disk.io_time` | Time spent doing I/O |
| `system.filesystem.utilization` | Filesystem usage percentage |
| `process.cpu.utilization` | CPU usage % per process |
| `process.memory.usage` | Memory usage (RSS) per process |
| `process.cpu.time` | CPU time per process |
| `process.disk.io` | Disk I/O bytes per process |
| `process.threads` | Number of threads per process |

**Full list**: See [Microsoft documentation](https://learn.microsoft.com/azure/azure-monitor/vm/vminsights-opentelemetry#additional-metrics)

## Cost Considerations

### Storage Costs
- **Classic**: Log Analytics ingestion (~$2.30/GB) + retention costs
- **OTel**: Azure Monitor Workspace (~$0.10/GB) - **90% cheaper**

### Recommended Approach
1. **Phase 1**: Enable OTel metrics only (disable classic) - **Maximum savings**
2. **Phase 2**: Monitor for 2-4 weeks, validate dashboards
3. **Phase 3**: Disable classic metrics completely

## Troubleshooting

### Common Issues

#### 1. Azure Monitor Agent Installation Fails
```
Error: Failed to install Azure Monitor Agent on vm-web-01
```
**Solutions**:
- Verify VM is running: `Get-AzVM -Status | Where-Object {$_.PowerState -eq 'VM running'}`
- Check network connectivity to `*.monitor.azure.com`
- Verify VM OS is supported
- Check Azure Monitor Agent logs in VM: `/var/lib/waagent/Microsoft.Azure.Monitor.AzureMonitorLinuxAgent-*/` (Linux) or `C:\WindowsAzure\Logs\Plugins\Microsoft.Azure.Monitor.AzureMonitorWindowsAgent\` (Windows)

#### 2. DCR Association Fails
```
Error: Failed to create DCR association for vm-db-01
```
**Solutions**:
- Verify DCR exists: `Get-AzResource -ResourceType "Microsoft.Insights/dataCollectionRules"`
- Check RBAC permissions: User needs `Monitoring Contributor` role
- Ensure VM and DCR are in same region (soft requirement)

#### 3. No Metrics Appearing in Portal
**Solutions**:
- Wait 5-10 minutes for first metrics to appear
- Verify DCR association: Go to VM → Insights → Monitor Settings
- Check Azure Monitor workspace access: Portal → Monitor → Azure Monitor Workspace
- Verify network traffic to `monitor.azure.com` is not blocked
- Check browser ad blocker (disable or allowlist `*.monitor.azure.com`)

#### 4. "Access Denied" in Metrics Explorer
**Solutions**:
- User needs **Monitoring Reader** role on Azure Monitor Workspace
- Ensure resource-centric flag is enabled on workspace (ask admin)
- Refresh browser session (token may have expired)

### Debug Mode
```powershell
# Run with detailed output
.\Migrate-VMInsights-OpenTelemetry.ps1 -Verbose -Debug

# Check specific VM migration status
$results = Import-Csv ".\Logs\VMInsights-OTel-Results-*.csv"
$results | Where-Object {$_.Status -eq 'Failed'} | Format-Table
```

## Post-Migration Steps

### 1. Verify Metrics Collection
```powershell
# Check VMs with AMA installed
Get-AzVM | ForEach-Object {
    $ext = Get-AzVMExtension -ResourceGroupName $_.ResourceGroupName -VMName $_.Name -Name "AzureMonitorWindowsAgent" -ErrorAction SilentlyContinue
    if ($ext) {
        [PSCustomObject]@{
            VM = $_.Name
            Status = $ext.ProvisioningState
            Version = $ext.TypeHandlerVersion
        }
    }
}
```

### 2. View Metrics in Portal
1. Navigate to Azure Portal → VM → **Insights**
2. Click **Monitor Settings** to verify OTel is enabled
3. View metrics in **Metrics Explorer** (PromQL support)

### 3. Create Custom Dashboards
- Use **Azure Monitor Workbooks** for custom views
- Query with **PromQL** in Metrics Explorer
- Integrate with **Grafana** for advanced visualizations

### 4. Disable Classic Metrics (Optional)
Once you've validated OTel metrics are working:
```powershell
# Remove Log Analytics workspace DCR associations (classic metrics)
# See: https://learn.microsoft.com/azure/azure-monitor/vm/vminsights-optout
```

## Azure DevOps Pipeline Integration

Create `azure-pipelines-vm-insights-migration.yml`:

```yaml
trigger: none

parameters:
- name: subscriptionId
  displayName: 'Subscription ID'
  type: string
- name: resourceGroupName
  displayName: 'Resource Group (optional, leave blank for all VMs)'
  type: string
  default: ''
- name: enableCustomMetrics
  displayName: 'Enable Custom Metrics (additional cost)'
  type: boolean
  default: false

pool:
  vmImage: 'windows-latest'

steps:
- task: AzurePowerShell@5
  inputs:
    azureSubscription: 'Azure-ServiceConnection'
    scriptType: 'FilePath'
    scriptPath: 'Pipelines/VM-Insights-OpenTelemetry/Migrate-VMInsights-OpenTelemetry.ps1'
    scriptArguments: |
      -SubscriptionId "${{ parameters.subscriptionId }}" \
      -ResourceGroupName "${{ parameters.resourceGroupName }}" \
      -CustomMetricsEnabled:$${{ parameters.enableCustomMetrics }} \
      -Verbose
    azurePowerShellVersion: 'LatestVersion'
    pwsh: true

- task: PublishBuildArtifacts@1
  inputs:
    pathToPublish: 'Logs'
    artifactName: 'MigrationLogs'
  condition: always()
```

## Security Considerations

### Secrets Management
- **Never hardcode** subscription IDs or resource IDs in scripts
- Use **Azure Key Vault** for storing Log Analytics workspace IDs
- Use **Managed Identities** in Azure DevOps pipelines

### RBAC Permissions
Minimum required permissions:
- `Contributor` on target VMs
- `Monitoring Contributor` on subscription (for DCR creation)
- `Resource Group Contributor` (for monitoring RG creation)

### Audit Logging
All operations are logged:
- VM extension installations
- DCR associations
- Azure Monitor Workspace creation

## Support & Documentation

### Official Microsoft Docs
- [VM Insights OpenTelemetry Migration Guide](https://learn.microsoft.com/azure/azure-monitor/vm/vminsights-opentelemetry)
- [Azure Monitor Agent Overview](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-overview)
- [Data Collection Rules](https://learn.microsoft.com/azure/azure-monitor/data-collection/data-collection-rule-overview)
- [Azure Monitor Metrics with PromQL](https://learn.microsoft.com/azure/azure-monitor/metrics/metrics-explorer)

### Internal Support
- **Team**: BAB CloudOps
- **Version**: 1.0
- **Last Updated**: 2026-02-03

## Contributing

When modifying this script:
1. Test with `-WhatIf` first
2. Use standard PowerShell logging pattern
3. Update version number in script header
4. Document breaking changes in this README

## License

Internal use only - BAB CloudOps Team
