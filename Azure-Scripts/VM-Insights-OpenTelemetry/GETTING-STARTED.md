# VM Insights OpenTelemetry Migration - Complete Solution

## 📦 What's Been Created

A complete automation solution for migrating Azure VMs to OpenTelemetry-based VM insights monitoring.

### Location
```
BAB_CloudOps/
└── BAB_CloudOps-pipeline/
    └── Pipelines/
        └── VM-Insights-OpenTelemetry/
            ├── Migrate-VMInsights-OpenTelemetry.ps1    # Main migration script
            ├── Validate-VMInsights-OTel.ps1            # Post-migration validation
            ├── Rollback-VMInsights-OTel.ps1            # Emergency rollback
            ├── azure-pipelines-vm-insights-otel.yml    # Azure DevOps pipeline
            ├── README.md                               # Full technical docs
            ├── QUICKSTART.md                           # Quick start guide
            └── GETTING-STARTED.md                      # This file
```

---

## 🚀 Getting Started in 3 Steps

### Step 1: Install Prerequisites (5 minutes)

```powershell
# Install required Azure PowerShell modules
Install-Module -Name Az.Compute -Force -AllowClobber
Install-Module -Name Az.Monitor -Force -AllowClobber
Install-Module -Name Az.Resources -Force -AllowClobber
Install-Module -Name Az.OperationalInsights -Force -AllowClobber

# Login to Azure
Connect-AzAccount

# Set your subscription
Set-AzContext -SubscriptionId "your-subscription-id-here"
```

### Step 2: Test Migration (Dry-Run)

```powershell
# Navigate to script directory
cd "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\BAB_CloudOps-pipeline\Pipelines\VM-Insights-OpenTelemetry"

# Preview what will happen (no changes made)
.\Migrate-VMInsights-OpenTelemetry.ps1 -WhatIf -Verbose
```

**Review the output** - you'll see:
- Number of VMs that will be migrated
- Azure Monitor Workspace that will be created
- Data Collection Rule configuration

### Step 3: Execute Migration

```powershell
# Run the migration
.\Migrate-VMInsights-OpenTelemetry.ps1 -Verbose
```

**Expected time**: 2-5 minutes per VM

**Monitor progress**:
- Watch console output for real-time status
- Check log file: `Logs/VMInsights-OTel-Migration-{timestamp}.log`
- Review results: `Logs/VMInsights-OTel-Results-{timestamp}.csv`

---

## 📊 What Happens During Migration

```
┌─────────────────────────────────────────────────────────────┐
│                     MIGRATION PROCESS                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. Create Azure Monitor Workspace (if not exists)          │
│     └─> Store OTel metrics (cheaper than Log Analytics)     │
│                                                              │
│  2. Create Data Collection Rule (DCR)                       │
│     └─> Define which metrics to collect                     │
│                                                              │
│  3. For Each VM:                                            │
│     ├─> Install Azure Monitor Agent (AMA)                   │
│     ├─> Associate VM with DCR                               │
│     └─> Start collecting OTel metrics                       │
│                                                              │
│  4. Generate Report                                         │
│     └─> CSV with success/failure status per VM              │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## ✅ Post-Migration Validation

### Quick Check (5 minutes)
```powershell
# Run validation script
.\Validate-VMInsights-OTel.ps1 -ExportReport -Verbose
```

### Azure Portal Verification (5 minutes)
1. Go to **Azure Portal** → **Virtual Machines**
2. Select any VM → **Insights** (under Monitoring)
3. Click **Monitor Settings** button
4. Verify: ✅ "OpenTelemetry metrics" is enabled
5. Check **Metrics** tab - you should see data within 10 minutes

---

## 📈 Benefits You'll See

### Cost Savings
| Before (Classic) | After (OTel) | Savings |
|-----------------|--------------|---------|
| $2.30/GB | $0.10/GB | **95% cheaper** |
| ~$50-100/month (10 VMs) | ~$5-10/month (10 VMs) | **$40-90/month** |

### Performance Improvements
- ⚡ **Faster queries**: PromQL on native metrics vs KQL on logs
- 📊 **Unified schema**: Same metric names for Windows & Linux
- 🔍 **Richer metrics**: Per-process CPU, memory, disk I/O

### Operational Benefits
- ✅ **Simplified onboarding**: One script for all VMs
- ✅ **Modern stack**: Industry-standard OpenTelemetry
- ✅ **Future-proof**: Microsoft's strategic direction

---

## 🎯 Common Use Cases

### Use Case 1: Dev/Test Environment (Quick Migration)
```powershell
# Migrate all VMs in dev subscription (no validation period needed)
.\Migrate-VMInsights-OpenTelemetry.ps1 -Verbose
```

### Use Case 2: Production (Phased Approach)
```powershell
# Phase 1: Pilot group (keep classic metrics for safety)
.\Migrate-VMInsights-OpenTelemetry.ps1 `
    -ResourceGroupName "rg-prod-pilot" `
    -EnableClassicMetrics `
    -Verbose

# Wait 1-2 weeks, validate metrics

# Phase 2: Migrate remaining VMs
.\Migrate-VMInsights-OpenTelemetry.ps1 `
    -EnableClassicMetrics `
    -Verbose

# Phase 3: Disable classic metrics after validation (cost savings)
```

### Use Case 3: Multi-Subscription Migration
```powershell
# Migrate subscription by subscription
$subscriptions = @(
    "sub-id-1",
    "sub-id-2",
    "sub-id-3"
)

foreach ($subId in $subscriptions) {
    Write-Host "Migrating subscription: $subId"
    .\Migrate-VMInsights-OpenTelemetry.ps1 `
        -SubscriptionId $subId `
        -Verbose
}
```

---

## 🔧 Troubleshooting

### Problem: "Azure Monitor Agent installation failed"
**Solution**:
```powershell
# Check VM is running
Get-AzVM -Name "vm-name" -Status

# Start VM if stopped
Start-AzVM -ResourceGroupName "rg-name" -Name "vm-name"

# Retry migration
.\Migrate-VMInsights-OpenTelemetry.ps1 -ResourceGroupName "rg-name" -Verbose
```

### Problem: "No metrics showing in portal"
**Solutions**:
1. **Wait 10 minutes** - metrics take time to appear
2. **Check DCR association**:
   ```powershell
   $vm = Get-AzVM -Name "vm-name"
   Get-AzResource -ResourceType "Microsoft.Insights/dataCollectionRuleAssociations" `
       -ResourceId "$($vm.Id)/providers/Microsoft.Insights/dataCollectionRuleAssociations"
   ```
3. **Verify network connectivity** to `*.monitor.azure.com`
4. **Disable browser ad blocker** or allowlist `*.monitor.azure.com`

### Problem: "Migration interrupted / timeout"
**Solution**:
```powershell
# Resume from checkpoint
.\Migrate-VMInsights-OpenTelemetry.ps1 -ResumeFromCheckpoint -Verbose
```

---

## 🔄 Rollback (If Needed)

If you need to revert the migration:

```powershell
# Option 1: Remove DCR associations only (keeps AMA for future use)
.\Rollback-VMInsights-OTel.ps1 -Verbose

# Option 2: Full rollback (remove AMA extensions completely)
.\Rollback-VMInsights-OTel.ps1 -RemoveAzureMonitorAgent -Verbose
```

---

## 📋 Azure DevOps Pipeline Setup

### Step 1: Import Pipeline
1. Go to **Azure DevOps** → **Pipelines** → **New Pipeline**
2. Select **Existing YAML**
3. Choose: `BAB_CloudOps-pipeline/Pipelines/VM-Insights-OpenTelemetry/azure-pipelines-vm-insights-otel.yml`

### Step 2: Update Service Connection
Edit the pipeline YAML:
```yaml
variables:
  azureServiceConnection: 'Your-Service-Connection-Name'  # Update this
```

### Step 3: Run Pipeline
- Click **Run pipeline**
- Fill in parameters (subscription ID, resource group, etc.)
- Monitor execution

---

## 📚 Documentation Structure

### For Quick Reference
- **QUICKSTART.md** - Step-by-step guide with examples
- **GETTING-STARTED.md** - This file (overview & setup)

### For Deep Dive
- **README.md** - Complete technical documentation
  - All parameters explained
  - Architecture details
  - Metrics reference
  - Cost analysis
  - Troubleshooting guide

### For Operations
- **Migration Script** - `Migrate-VMInsights-OpenTelemetry.ps1`
- **Validation Script** - `Validate-VMInsights-OTel.ps1`
- **Rollback Script** - `Rollback-VMInsights-OTel.ps1`
- **Azure Pipeline** - `azure-pipelines-vm-insights-otel.yml`

---

## ⏱️ Migration Timeline

### Small Environment (10-50 VMs)
- **Preparation**: 15 minutes
- **Migration**: 30-120 minutes
- **Validation**: 15 minutes
- **Total**: ~2-3 hours

### Medium Environment (50-200 VMs)
- **Preparation**: 30 minutes
- **Migration**: 2-6 hours
- **Validation**: 30 minutes
- **Total**: ~3-7 hours

### Large Environment (200+ VMs)
- **Preparation**: 1 hour
- **Migration**: 6-12 hours (use Azure DevOps pipeline)
- **Validation**: 1 hour
- **Total**: ~8-14 hours

---

## 🎓 Learning Resources

### Microsoft Documentation
- [VM Insights OpenTelemetry Migration](https://learn.microsoft.com/azure/azure-monitor/vm/vminsights-opentelemetry)
- [Azure Monitor Agent Overview](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-overview)
- [Data Collection Rules](https://learn.microsoft.com/azure/azure-monitor/data-collection/data-collection-rule-overview)

### Internal Resources
- Script location: `BAB_CloudOps-pipeline/Pipelines/VM-Insights-OpenTelemetry/`
- Logs: Check `Logs/` directory after each run
- Results: CSV files in `Logs/` directory

---

## ✨ Key Features

### Script Capabilities
- ✅ Multi-subscription support
- ✅ Batch processing with parallel execution
- ✅ Automatic workspace creation
- ✅ Resume from checkpoint (interrupted runs)
- ✅ Dry-run mode (`-WhatIf`)
- ✅ Comprehensive logging
- ✅ CSV export of results
- ✅ Exclude VMs by tag
- ✅ Custom metrics support

### Safety Features
- ✅ No VM downtime during migration
- ✅ Validation script included
- ✅ Rollback script available
- ✅ Checkpoint for resume capability
- ✅ WhatIf mode for testing

---

## 📞 Support

### For Issues
1. Check **README.md** troubleshooting section
2. Review **logs** in `Logs/` directory
3. Run **validation script**: `Validate-VMInsights-OTel.ps1`
4. Contact **BAB CloudOps Team**

### For Questions
- **Technical details**: See README.md
- **Quick examples**: See QUICKSTART.md
- **Setup help**: This file (GETTING-STARTED.md)

---

## 🎉 Ready to Start?

```powershell
# 1. Navigate to script directory
cd "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\BAB_CloudOps-pipeline\Pipelines\VM-Insights-OpenTelemetry"

# 2. Login to Azure
Connect-AzAccount

# 3. Test migration (dry-run)
.\Migrate-VMInsights-OpenTelemetry.ps1 -WhatIf -Verbose

# 4. Execute migration
.\Migrate-VMInsights-OpenTelemetry.ps1 -Verbose

# 5. Validate results
.\Validate-VMInsights-OTel.ps1 -ExportReport -Verbose
```

**That's it!** Your VMs are now using modern OpenTelemetry-based monitoring with 80-90% cost savings! 🎊

---

## 📝 Next Steps After Migration

### Week 1
- [ ] Monitor metrics collection daily
- [ ] Validate dashboards work correctly
- [ ] Test alerting rules (may need minor updates)

### Week 2-4
- [ ] Disable classic Log Analytics metrics (cost savings)
- [ ] Update monitoring documentation
- [ ] Train team on new metrics

### Month 2+
- [ ] Create custom Grafana dashboards
- [ ] Implement PromQL queries for analytics
- [ ] Enable custom metrics for critical VMs (per-process monitoring)

---

**Questions?** Check **README.md** for detailed documentation or **QUICKSTART.md** for more examples.
