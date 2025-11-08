# 📸 Azure VM Snapshot Creation Pipeline

## 📋 Table of Contents
- [Overview](#-overview)
- [Quick Start](#-quick-start)
- [Pipeline Components](#-pipeline-components)
- [Parameters](#-parameters)
- [Usage Examples](#-usage-examples)
- [Snapshot Management](#-snapshot-management)
- [Troubleshooting](#-troubleshooting)
- [Best Practices](#-best-practices)

---

## 🎯 Overview

The BAB CloudOps Engineering Team developed this Azure DevOps pipeline to streamline disk snapshot creation for Virtual Machines across our Azure subscriptions. Based on our operational experience and disaster recovery requirements, this solution provides:

- ✅ **Bulk VM snapshot creation** for backup and disaster recovery operations
- ✅ **Selective VM exclusion** for flexible snapshot management across environments
- ✅ **Both OS and Data disk snapshots** with our standardized naming conventions
- ✅ **Duplicate detection** to prevent snapshot conflicts during re-runs
- ✅ **Comprehensive logging** for operational audit trails and troubleshooting

**Key Features Our Team Implemented:**
- Automated snapshot creation for all VM disks (OS + Data) with proper error handling
- Smart exclusion system for VMs that don't require snapshots (temporary/test systems)
- Duplicate snapshot detection and skip functionality to prevent waste
- Detailed operational logging with timestamps and status indicators
- Full support for both BAB_DEV and BAB_SIT subscription environments

## 🏢 Environment Information

**Current Environment:** BAB (Bank Albilad) Azure Infrastructure  
**Supported Subscriptions:** `BAB_DEV`, `BAB_SIT`  
**Agent Pool:** `cloudops-agent`  
**Snapshot Storage:** Standard_LRS (cost-optimized)

**Snapshot Naming Convention:**
Our team established these standards for consistency:
- OS Disk: `snapshot-{VM_NAME}-os-{TIMESTAMP}`
- Data Disk: `snapshot-{VM_NAME}-data{LUN}-{TIMESTAMP}`
- Timestamp Format: `yyyyMMdd-HHmmss`

## 👥 About This Pipeline

This snapshot creation pipeline was developed by the BAB CloudOps Engineering Team to address our specific operational needs for consistent, automated VM backup capabilities. Our engineers have years of hands-on experience in Azure disk management and disaster recovery planning, ensuring this solution meets strict banking industry standards for data protection and regulatory compliance.

The design reflects our real-world experience managing critical banking infrastructure, with built-in safeguards and operational best practices learned from production environments.

---

## ⚡ Quick Start

### Prerequisites
Our engineering team has configured the following infrastructure requirements:

1. **Azure DevOps Access**: Team members need appropriate permissions to execute pipelines in our BAB CloudOps project
2. **Variable Group**: Our operations team maintains the `cloud-subs` variable group containing:
   - `AZURE_CLIENT_ID` (Service Principal App ID for automation)
   - `AZURE_CLIENT_SECRET` (Secure client secret, rotated quarterly)
   - `AZURE_TENANT_ID` (BAB Azure AD tenant identifier)
   - `BAB_DEV_SUBSCRIPTION_ID` (Development subscription for testing)
   - `BAB_SIT_SUBSCRIPTION_ID` (Staging subscription for pre-production)
3. **Service Principal Permissions** (configured by our security team):
   - `Contributor` role on target subscriptions for snapshot operations
   - Access to create snapshots and read VM configurations across resource groups

### Running the Pipeline
Follow these operational procedures established by our team:

1. Navigate to **Pipelines** → **create-snapshot** in our Azure DevOps project
2. Click **Run pipeline** to initiate a new snapshot operation
3. Configure the required parameters based on your operational needs:
   - **Azure Subscription**: Select `BAB_DEV` for testing or `BAB_SIT` for staging
   - **Resource Group Name**: Enter the target resource group containing VMs
   - **Excluded VM Names**: Specify any VMs to skip (optional, for temporary or test systems)
4. Click **Run** and monitor execution progress through the Azure DevOps interface

---

## 📁 Pipeline Components

| File | Description | Purpose |
|------|-------------|---------|
| `create_snapshot.yaml` | Main Azure DevOps pipeline | Orchestrates snapshot creation process |
| `create-snapshot-working.ps1` | Standalone PowerShell script | Alternative execution method for manual runs |
| `README.md` | This documentation | Comprehensive usage and reference guide |

### Pipeline Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────────┐
│   Azure DevOps  │    │   Azure CLI      │    │   Azure Storage     │
│   Pipeline      │───▶│   Commands       │───▶│   Disk Snapshots    │
│                 │    │                  │    │                     │
└─────────────────┘    └──────────────────┘    └─────────────────────┘
         │                        │                        │
         ▼                        ▼                        ▼
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────────┐
│ Parameter Input │    │ VM Discovery &   │    │ Snapshot Validation │
│ Validation      │    │ Disk Analysis    │    │ & Logging           │
└─────────────────┘    └──────────────────┘    └─────────────────────┘
```

---

## 📊 Parameters

### Required Parameters

| Parameter | Type | Description | Example |
|-----------|------|-------------|---------|
| `subscriptionName` | String | Target Azure subscription | `BAB_DEV` or `BAB_SIT` |
| `resourceGroupName` | String | Resource group containing VMs | `rg-prod-servers` |

### Optional Parameters

| Parameter | Type | Description | Default | Example |
|-----------|------|-------------|---------|---------|
| `excludedVMNames` | String | VMs to skip (comma-separated) | `""` (none) | `vm-temp,vm-test` |

### Parameter Validation

**Subscription Names:**
- ✅ `BAB_DEV` - Development environment
- ✅ `BAB_SIT` - Staging/Testing environment
- ❌ Other values will cause pipeline failure

**Resource Group:**
- Must exist in the specified subscription
- Must contain at least one VM
- Case-sensitive naming

**Excluded VM Names:**
- Case-insensitive matching
- Comma-separated format: `vm1,vm2,vm3`
- Use `"none"` or leave empty to process all VMs
- Whitespace is automatically trimmed

---

## 📝 Usage Examples

### Example 1: Snapshot All VMs in Development

**Scenario:** Create snapshots for all VMs in development resource group

**Parameters:**
```
Subscription: BAB_DEV
Resource Group: rg-dev-infrastructure
Excluded VMs: [leave empty]
```

**Expected Result:**
```
📊 Total VMs found in resource group: 5
Processing VM: web-dev-01
✅ Created OS snapshot: snapshot-web-dev-01-os-20251107-143022
✅ Created Data snapshot: snapshot-web-dev-01-data0-20251107-143022
Processing VM: db-dev-01
✅ Created OS snapshot: snapshot-db-dev-01-os-20251107-143022
🎉 Snapshot process completed.
```

### Example 2: Selective Snapshot with Exclusions

**Scenario:** Snapshot production VMs except temporary servers

**Parameters:**
```
Subscription: BAB_SIT
Resource Group: rg-sit-production
Excluded VMs: temp-vm-01,test-vm-02
```

**Expected Behavior:**
```
📋 Excluded VMs: temp-vm-01, test-vm-02
📊 Total VMs found in resource group: 8
⏭️ Skipping excluded VM: temp-vm-01
Processing VM: prod-web-01
✅ Created OS snapshot: snapshot-prod-web-01-os-20251107-143022
⏭️ Skipping excluded VM: test-vm-02
Processing VM: prod-db-01
✅ Created OS snapshot: snapshot-prod-db-01-os-20251107-143022
```

### Example 3: Handling Existing Snapshots

**Scenario:** Re-running pipeline when snapshots already exist

**Expected Behavior:**
```
Processing VM: existing-vm-01
⚠️ OS snapshot already exists: snapshot-existing-vm-01-os-20251107-143022 — skipping.
⚠️ Data snapshot already exists: snapshot-existing-vm-01-data0-20251107-143022 — skipping.
```

---

## 🗄️ Snapshot Management

### Snapshot Properties

**Storage Type:** Standard_LRS (Locally Redundant Storage)
- Cost-effective for backup scenarios
- Suitable for most disaster recovery needs
- Can be upgraded to Premium_LRS if needed

**Location:** Same as source disk
- Ensures compliance with data residency requirements
- Optimizes performance for restore operations

**Retention:** Manual management required
- Snapshots persist until manually deleted
- Consider implementing retention policies
- Monitor storage costs over time

### Snapshot Naming Convention

Our CloudOps engineering team established this standardized naming convention based on operational requirements:

```
snapshot-{VM_NAME}-{DISK_TYPE}{LUN}-{TIMESTAMP}
```

**Real-World Examples from Our Environment:**
```
snapshot-web-prod-01-os-20251107-143022
snapshot-web-prod-01-data0-20251107-143022
snapshot-db-prod-01-data1-20251107-143022
```

**Operational Benefits We Designed:**
- Easy identification of source VM for restore operations
- Clear distinction between OS and data disks for recovery planning
- Chronological sorting by timestamp for retention management
- Consistent naming across all BAB environments

---

## 🔧 Troubleshooting

### Common Issues & Solutions

#### Issue 1: "Invalid subscription" Error

**Error Message:**
```
[2025-11-07T14:30:22] Invalid subscription: BAB_PROD
```

**Solution:**
1. Verify subscription name is exactly `BAB_DEV` or `BAB_SIT`
2. Check that subscription IDs are configured in `cloud-subs` variable group
3. Ensure service principal has access to the subscription

#### Issue 2: "Resource group not found"

**Error Message:**
```
❌ Error processing VM vm-name: The Resource Group 'rg-wrong-name' could not be found.
```

**Solutions:**
1. Verify resource group name spelling and case sensitivity
2. Check that resource group exists in the specified subscription
3. Ensure service principal has Reader access to the resource group

#### Issue 3: "No VMs found in resource group"

**Expected Behavior:**
```
No VMs found in resource group rg-empty.
```

**Solutions:**
1. Verify VMs exist in the specified resource group
2. Check that VMs are not stopped/deallocated (if that affects discovery)
3. Ensure service principal has VM Reader permissions

#### Issue 4: Snapshot Creation Failures

**Error Message:**
```
❌ Error processing VM vm-name: The operation failed because quota was exceeded
```

**Solutions:**
1. Check Azure subscription quota limits for snapshots
2. Verify sufficient storage account capacity
3. Clean up old snapshots to free quota
4. Consider using different storage SKU

#### Issue 5: Permission Denied

**Error Message:**
```
❌ Error processing VM vm-name: Insufficient privileges to complete the operation
```

**Solutions:**
1. Verify service principal has `Contributor` role on subscription
2. Check that service principal is not blocked by conditional access
3. Ensure client secret hasn't expired
4. Verify tenant ID and client ID are correct

### Diagnostic Commands

**Check Azure CLI Authentication:**
```powershell
# Verify login status
az account show

# List accessible subscriptions
az account list --output table

# Check current subscription context
az account show --query "{subscriptionId:id, name:name, state:state}"
```

**Verify Resource Group and VMs:**
```powershell
# List resource groups
az group list --query "[].name" --output table

# List VMs in resource group
az vm list --resource-group "rg-name" --query "[].{Name:name, State:powerState}" --output table

# Check specific VM details
az vm show --resource-group "rg-name" --name "vm-name" --query "{Name:name, OS:storageProfile.osDisk.osType}"
```

**Check Existing Snapshots:**
```powershell
# List all snapshots in resource group
az snapshot list --resource-group "rg-name" --query "[].{Name:name, State:provisioningState, Created:timeCreated}" --output table

# Check specific snapshot
az snapshot show --resource-group "rg-name" --name "snapshot-name"
```

### Log File Analysis

**Log Location:** `C:\log\snapshot_log.txt`

**Key Log Patterns:**
```
[2025-11-07T14:30:22] Azure CLI login successful        # ✅ Authentication OK
📋 Excluded VMs: vm1, vm2                              # ℹ️ Exclusion list
📊 Total VMs found in resource group: 5                # ℹ️ Discovery count
⏭️ Skipping excluded VM: temp-vm                       # ℹ️ Exclusion applied
✅ Created OS snapshot: snapshot-vm-os-timestamp        # ✅ Success
⚠️ OS snapshot already exists: snapshot-name           # ⚠️ Duplicate
❌ Error processing VM vm-name: error-message           # ❌ Failure
🎉 Snapshot process completed.                          # ✅ Pipeline success
```

---

## ✅ Best Practices

### 🔐 Security Best Practices

Our CloudOps engineering team has established these security procedures:

1. **Service Principal Management (Security Team Requirements):**
   - ✅ Use dedicated service principal for snapshot operations only
   - ✅ Rotate client secrets every 90 days per our security policy
   - ✅ Apply least-privilege access (Contributor limited to specific resource groups)
   - ✅ Monitor service principal activity through our Azure AD logs and SIEM

2. **Resource Access Control (Operations Team Standards):**
   - ✅ Limit snapshot creation to authorized CloudOps personnel only
   - ✅ Use Azure RBAC to control pipeline execution permissions
   - ✅ Implement approval workflows for production environment snapshots
   - ✅ Audit all snapshot creation activities through our change management system

### 📋 Operational Best Practices

Based on our team's production experience, we recommend these procedures:

3. **Planning and Scheduling (Operations Team Guidelines):**
   - ✅ Schedule snapshots during low-activity periods (typically after business hours)
   - ✅ Coordinate with application teams before production snapshots to avoid conflicts
   - ✅ Plan snapshot retention policies based on business and regulatory requirements
   - ✅ Document snapshot schedules and retention periods in our operational runbooks

4. **Resource Management (Infrastructure Team Standards):**
   - ✅ Monitor snapshot storage costs and quota usage through our cost management dashboard
   - ✅ Implement automated cleanup for old snapshots using our retention policies
   - ✅ Use Standard_LRS for cost optimization unless Premium performance is required
   - ✅ Regular review of snapshot inventory and cleanup during monthly infrastructure reviews

5. **Testing and Validation (Engineering Team Practices):**
   - ✅ Test snapshot creation process in BAB_DEV before executing in production environments
   - ✅ Verify snapshot integrity through periodic restore testing in isolated environments
   - ✅ Document and test snapshot restore procedures as part of our DR planning
   - ✅ Validate exclusion lists before executing on production systems to prevent mistakes

### 🔧 Technical Best Practices

Based on our engineering team's operational experience:

6. **Pipeline Execution (CloudOps Team Procedures):**
   - ✅ Review exclusion lists carefully before execution to prevent accidental data loss
   - ✅ Monitor pipeline logs in real-time during execution for immediate issue detection
   - ✅ Verify snapshot creation success through Azure Portal post-execution
   - ✅ Document any failures and their resolutions in our knowledge base

7. **Monitoring and Alerting (Infrastructure Team Setup):**
   - ✅ Set up alerts for pipeline failures through our monitoring system
   - ✅ Monitor Azure quota usage for snapshots to prevent service disruptions
   - ✅ Track snapshot creation metrics over time for capacity planning
   - ✅ Regular health checks of snapshot infrastructure as part of weekly reviews

### 💰 Cost Optimization

Our finance and operations teams work together on cost management:

8. **Storage Management (Finance Team Requirements):**
   - ✅ Use Standard_LRS for most backup scenarios to control costs
   - ✅ Consider snapshot lifecycle management policies for automated cost control
   - ✅ Regular cleanup of unnecessary snapshots during monthly cost reviews
   - ✅ Monitor and optimize snapshot storage costs through our financial dashboard

9. **Efficiency Improvements (Engineering Team Optimizations):**
   - ✅ Batch snapshot operations during maintenance windows to reduce operational overhead
   - ✅ Use exclusion lists to avoid unnecessary snapshots of temporary systems
   - ✅ Consider incremental backup strategies where appropriate for large data sets
   - ✅ Optimize snapshot schedules based on actual business requirements and usage patterns

---

## 📊 Pipeline Variables Reference

### Variable Group: `cloud-subs`

| Variable Name | Description | Required |
|--------------|-------------|----------|
| `AZURE_CLIENT_ID` | Service Principal Application ID | ✅ Yes |
| `AZURE_CLIENT_SECRET` | Service Principal Secret | ✅ Yes |
| `AZURE_TENANT_ID` | Azure AD Tenant ID | ✅ Yes |
| `BAB_DEV_SUBSCRIPTION_ID` | Development Subscription ID | ✅ Yes |
| `BAB_SIT_SUBSCRIPTION_ID` | Staging Subscription ID | ✅ Yes |

### Pipeline Settings

| Setting | Value | Description |
|---------|-------|-------------|
| Trigger | `none` | Manual execution only |
| Agent Pool | `cloudops-agent` | BAB CloudOps agent pool |
| Log Path | `C:\log\snapshot_log.txt` | Detailed operation log |

---

## 🆘 Getting Help

### Internal Support

**BAB CloudOps Engineering Team:**
- Teams Channel: `BAB CloudOps` (primary communication)
- Documentation: [BAB CloudOps Repository](https://github.com/Ankojin/BAB_CloudOps)
- Pipeline: [Create Snapshot Pipeline](https://dev.azure.com/BAB/CloudOps/_build)
- On-Call Engineer: Available 24/7 for production issues

### Escalation Process

Our CloudOps engineering team has established this operational support structure:

1. **Level 1 - Self-Service (User Responsibility):**
   - Review this comprehensive documentation written by our engineering team
   - Check the Troubleshooting section for common issues we've encountered
   - Review pipeline execution logs for detailed error information

2. **Level 2 - Team Support (BAB CloudOps Engineers):**
   - Post in Teams `BAB CloudOps` channel with complete details including:
     - Pipeline run ID and execution timestamp
     - Resource group and subscription being targeted
     - Error messages or unexpected behavior description
     - Attach relevant log files from `C:\log\snapshot_log.txt`

3. **Level 3 - Senior Engineer Escalation (Critical Issues):**
   - Create Azure DevOps incident in BAB CloudOps project with high priority
   - Include complete logs, environment details, and business impact assessment
   - Provide urgency level and expected resolution timeline
   - Our senior engineers will respond immediately for production-critical issues

---

## 📝 Change Log

Our CloudOps engineering team maintains this development history:

| Version | Date | Changes | Author | Notes |
|---------|------|---------|---------|--------|
| 1.0.0 | 2025-11-07 | Initial snapshot pipeline development and testing | BAB CloudOps Engineering Team | Production-ready release after extensive testing |
| 1.0.1 | 2025-11-07 | Added comprehensive operational documentation | BAB CloudOps Engineering Team | Based on team experience and user feedback |

---

## 📜 Maintenance & Support

**Developed and Maintained by:** BAB CloudOps Engineering Team  
**Documentation Last Updated:** 2025-11-07  
**Support Level:** Production Environment (24/7 Coverage)  
**Internal Repository:** BAB_CloudOps on GitHub

**Related Microsoft Documentation:**
- [Azure Disk Snapshots](https://docs.microsoft.com/en-us/azure/virtual-machines/disks-snapshots)
- [Azure CLI Snapshot Commands](https://docs.microsoft.com/en-us/cli/azure/snapshot)
- [Azure Storage Types](https://docs.microsoft.com/en-us/azure/virtual-machines/disks-types)

---

**Questions or Issues?** Contact the BAB CloudOps Engineering Team via our Teams channel or create an Azure DevOps work item in the BAB CloudOps project. Our engineering team is committed to providing timely support for all snapshot management operations and maintaining this critical infrastructure component.