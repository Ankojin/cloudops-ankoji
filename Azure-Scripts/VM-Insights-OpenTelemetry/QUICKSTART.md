# Quick Start Guide: VM Insights OpenTelemetry Migration

## 5-Minute Quick Start

### Prerequisites Check
```powershell
# 1. Verify Azure PowerShell modules
Get-Module -ListAvailable Az.Compute, Az.Monitor, Az.Resources

# 2. Login to Azure
Connect-AzAccount

# 3. Set subscription
Set-AzContext -SubscriptionId "your-subscription-id"
```

### Basic Migration (Recommended)
```powershell
# Navigate to script directory
cd "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\BAB_CloudOps-pipeline\Pipelines\VM-Insights-OpenTelemetry"

# Run migration (OTel only, disable classic metrics)
.\Migrate-VMInsights-OpenTelemetry.ps1 -Verbose
```

This will:
- ✅ Migrate all VMs in current subscription
- ✅ Create Azure Monitor Workspace automatically
- ✅ Install Azure Monitor Agent on all VMs
- ✅ Configure Data Collection Rules
- ✅ Disable expensive Log Analytics metrics

**Expected time**: 2-5 minutes per VM

---

## Step-by-Step Guided Migration

### Step 1: Pre-Migration Validation

```powershell
# Check current VM count
$vms = Get-AzVM -Status
Write-Host "Found $($vms.Count) VMs to migrate"

# Check which VMs already have monitoring
$vms | ForEach-Object {
    $insights = Get-AzVMExtension -ResourceGroupName $_.ResourceGroupName `
        -VMName $_.Name `
        -Name "AzureMonitorWindowsAgent" `
        -ErrorAction SilentlyContinue
    
    if ($insights) {
        Write-Host "✅ $($_.Name) - Already has AMA"
    } else {
        Write-Host "⏺️ $($_.Name) - Needs migration"
    }
}
```

### Step 2: Dry-Run (Preview Changes)

```powershell
# Test migration without making changes
.\Migrate-VMInsights-OpenTelemetry.ps1 -WhatIf -Verbose
```

Review output for:
- ✅ Azure Monitor Workspace that will be created
- ✅ VMs that will be migrated
- ✅ Extensions that will be installed

### Step 3: Execute Migration

#### Option A: All VMs in Subscription
```powershell
.\Migrate-VMInsights-OpenTelemetry.ps1 -Verbose
```

#### Option B: Specific Resource Group
```powershell
.\Migrate-VMInsights-OpenTelemetry.ps1 `
    -ResourceGroupName "rg-production-vms" `
    -Verbose
```

#### Option C: Keep Classic Metrics (Dual Monitoring)
```powershell
.\Migrate-VMInsights-OpenTelemetry.ps1 `
    -EnableClassicMetrics `
    -LogAnalyticsWorkspaceId "/subscriptions/.../workspaces/law-prod" `
    -Verbose
```

### Step 4: Post-Migration Validation

```powershell
# Run validation script
.\Validate-VMInsights-OTel.ps1 -ExportReport -Verbose
```

Expected output:
```
✅ Successfully Migrated: 45/50 (90%)
⚠️ Partially Migrated: 3/50 (6%)
❌ Failed/Not Migrated: 2/50 (4%)
```

### Step 5: Verify Metrics in Azure Portal

1. **Navigate to VM**:
   - Azure Portal → Virtual Machines → Select VM → Insights

2. **Check Monitor Settings**:
   - Click "Monitor Settings" button
   - Verify "OpenTelemetry metrics" is enabled
   - Should show Azure Monitor Workspace name

3. **View Metrics**:
   - Click "Metrics" tab
   - You should see metrics like:
     - `system.cpu.time`
     - `system.memory.usage`
     - `system.disk.io`

**Note**: Metrics take 5-10 minutes to appear after migration.

---

## Common Scenarios

### Scenario 1: Dev/Test Environment (Fast Migration)
```powershell
# Migrate all VMs, ignore failures, no classic metrics
.\Migrate-VMInsights-OpenTelemetry.ps1 `
    -ResourceGroupName "rg-dev" `
    -ParallelBatchSize 10 `
    -Verbose
```

### Scenario 2: Production (Cautious Approach)
```powershell
# Step 1: Pilot group (5 VMs)
.\Migrate-VMInsights-OpenTelemetry.ps1 `
    -ResourceGroupName "rg-prod-web-pilot" `
    -EnableClassicMetrics `
    -Verbose

# Step 2: Wait 24 hours, validate metrics

# Step 3: Migrate remaining VMs
.\Migrate-VMInsights-OpenTelemetry.ps1 `
    -ResourceGroupName "rg-prod-web" `
    -EnableClassicMetrics `
    -Verbose

# Step 4: After 1 week, disable classic metrics for cost savings
# (Use Azure Portal to remove Log Analytics DCR associations)
```

### Scenario 3: Enable Per-Process Monitoring (Custom Metrics)
```powershell
# For VMs requiring deep process-level insights
.\Migrate-VMInsights-OpenTelemetry.ps1 `
    -ResourceGroupName "rg-database-servers" `
    -CustomMetricsEnabled `
    -Verbose
```
**Note**: Custom metrics incur additional cost (~$0.25/metric/month).

### Scenario 4: Resume Failed Migration
```powershell
# If migration was interrupted (network issue, timeout, etc.)
.\Migrate-VMInsights-OpenTelemetry.ps1 `
    -ResumeFromCheckpoint `
    -Verbose
```

### Scenario 5: Exclude Specific VMs
```powershell
# Tag VMs to exclude
Get-AzVM -ResourceGroupName "rg-prod" -Name "vm-legacy-app" | 
    Update-AzTag -Tag @{ExcludeFromMonitoring="true"} -Operation Merge

# Run migration (will skip tagged VMs)
.\Migrate-VMInsights-OpenTelemetry.ps1 `
    -ExcludeVMsWithTag "ExcludeFromMonitoring" `
    -Verbose
```

---

## Troubleshooting Common Issues

### Issue 1: "Azure Monitor Agent installation failed"
```powershell
# Check VM status
Get-AzVM -Name "vm-name" -Status

# Ensure VM is running
Start-AzVM -ResourceGroupName "rg-name" -Name "vm-name"

# Retry migration for specific RG
.\Migrate-VMInsights-OpenTelemetry.ps1 `
    -ResourceGroupName "rg-name" `
    -Verbose
```

### Issue 2: "No metrics appearing in portal"
```powershell
# Wait 10 minutes, then check DCR association
$vm = Get-AzVM -Name "vm-name"
Get-AzResource -ResourceType "Microsoft.Insights/dataCollectionRuleAssociations" `
    -ResourceId "$($vm.Id)/providers/Microsoft.Insights/dataCollectionRuleAssociations"

# If no association found, re-run migration
.\Migrate-VMInsights-OpenTelemetry.ps1 `
    -ResourceGroupName "rg-name" `
    -Verbose
```

### Issue 3: "Access Denied in Metrics Explorer"
```powershell
# Grant yourself Monitoring Reader role on Azure Monitor Workspace
$workspaceId = "/subscriptions/.../providers/Microsoft.Monitor/accounts/amw-vminsights-..."
New-AzRoleAssignment -SignInName "user@domain.com" `
    -RoleDefinitionName "Monitoring Reader" `
    -Scope $workspaceId
```

---

## Migration Checklist

### Pre-Migration ✅
- [ ] Azure PowerShell modules installed
- [ ] Contributor/Owner access to subscription
- [ ] Network connectivity to `*.monitor.azure.com` verified
- [ ] Backup/snapshot of critical VMs (optional, cautious approach)
- [ ] Test migration run with `-WhatIf` completed

### During Migration ✅
- [ ] Migration script running
- [ ] Monitor logs for errors: `Logs/VMInsights-OTel-Migration-*.log`
- [ ] Track progress: Check CSV results file

### Post-Migration ✅
- [ ] Run validation script: `.\Validate-VMInsights-OTel.ps1`
- [ ] Verify metrics in Azure Portal (wait 10 minutes)
- [ ] Check Azure Monitor Workspace access
- [ ] Review failed VMs (if any) and retry
- [ ] Update monitoring dashboards to use new metrics
- [ ] Schedule classic metrics removal (after 1-2 weeks validation)

---

## Azure DevOps Pipeline Setup

### 1. Import Pipeline
```bash
# In Azure DevOps, go to Pipelines → New Pipeline → Existing YAML
# Select: /BAB_CloudOps-pipeline/Pipelines/VM-Insights-OpenTelemetry/azure-pipelines-vm-insights-otel.yml
```

### 2. Update Service Connection
Edit `azure-pipelines-vm-insights-otel.yml`:
```yaml
variables:
  azureServiceConnection: 'Your-Azure-Service-Connection-Name'
```

### 3. Run Pipeline
- Click "Run pipeline"
- Fill in parameters:
  - Subscription ID
  - Resource Group (optional)
  - Enable custom metrics (yes/no)
- Monitor execution in Azure DevOps

---

## Cost Comparison

### Before Migration (Classic Log Analytics)
- **Storage**: $2.30/GB ingestion + $0.12/GB retention
- **Typical cost**: ~$50-100/month per 10 VMs

### After Migration (OpenTelemetry)
- **Storage**: $0.10/GB in Azure Monitor Workspace
- **Typical cost**: ~$5-10/month per 10 VMs
- **Savings**: **80-90% reduction**

### Custom Metrics (Optional)
- **Additional cost**: ~$0.25/metric/month
- Example: 10 custom metrics × 50 VMs = $125/month
- **Only enable for VMs requiring deep process-level insights**

---

## Next Steps After Migration

### Week 1: Validation Phase
1. Monitor metrics collection daily
2. Validate dashboards work with new metrics
3. Test alerting rules (may need updates)

### Week 2-4: Optimization Phase
1. Disable classic metrics (if not needed)
2. Remove unused Log Analytics workspace associations
3. Update monitoring documentation

### Month 2+: Enhancement Phase
1. Create custom Grafana dashboards
2. Implement PromQL queries for advanced analytics
3. Enable custom metrics for critical VMs

---

## Support & Resources

### Script Locations
- **Migration**: `Migrate-VMInsights-OpenTelemetry.ps1`
- **Validation**: `Validate-VMInsights-OTel.ps1`
- **Rollback**: `Rollback-VMInsights-OTel.ps1`
- **Pipeline**: `azure-pipelines-vm-insights-otel.yml`

### Documentation
- **README**: Full technical documentation
- **Microsoft Docs**: https://learn.microsoft.com/azure/azure-monitor/vm/vminsights-opentelemetry

### Logs & Artifacts
- **Logs**: `Logs/VMInsights-OTel-Migration-*.log`
- **Results**: `Logs/VMInsights-OTel-Results-*.csv`
- **Checkpoints**: `Checkpoints/migration-checkpoint.json`

---

## FAQ

**Q: Can I run this during business hours?**
A: Yes, migration has no downtime. VM remains running and operational.

**Q: What if migration fails mid-way?**
A: Use `-ResumeFromCheckpoint` to continue from where it stopped.

**Q: Should I keep classic metrics?**
A: For production, keep both for 1-2 weeks, then disable classic to save costs.

**Q: How long does migration take?**
A: ~2-5 minutes per VM. For 100 VMs: ~3-8 hours.

**Q: Can I rollback?**
A: Yes, use `Rollback-VMInsights-OTel.ps1` to remove AMA and DCR associations.

**Q: Do I need to restart VMs?**
A: No, Azure Monitor Agent installs without reboot.

---

**Ready to migrate? Start with:**
```powershell
.\Migrate-VMInsights-OpenTelemetry.ps1 -WhatIf -Verbose
```
