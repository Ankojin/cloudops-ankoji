# 🖥️ Azure VM Cross-Subscription Cloning Pipeline

## 📋 Table of Contents
- [Overview](#-overview)
- [Pipeline Components](#-pipeline-components)
- [Quick Start](#-quick-start)
- [CSV Configuration](#-csv-configuration)
- [Pipeline Parameters](#-pipeline-parameters)
- [Operation Examples](#-operation-examples)
- [Troubleshooting](#-troubleshooting)
- [Best Practices](#-best-practices)

---

## 🎯 Overview

The BAB CloudOps Engineering Team developed this Azure DevOps pipeline to enable secure, automated Virtual Machine cloning across subscriptions and regions. Based on our extensive experience managing banking infrastructure, this solution addresses critical needs for:

- ✅ **Cross-subscription VM migration** for environment promotion and isolation
- ✅ **Cross-region disaster recovery** setup and testing
- ✅ **Development environment provisioning** from production templates
- ✅ **Automated disk management** with snapshot-based cloning
- ✅ **Network configuration preservation** during migration

**Key Features Our Engineering Team Implemented:**
- Automated OS type detection for Windows and Linux VMs
- Intelligent disk snapshot creation and cleanup processes
- Cross-region VHD-based disk transfer using AzCopy optimization
- Network interface recreation with proper subnet and NSG assignment
- LUN-preserving data disk attachment for application compatibility
- Comprehensive error handling and rollback capabilities

## 🏢 Environment Information

**Current Environment:** BAB (Bank Albilad) Azure Infrastructure  
**Supported Subscriptions:** `BAB_DEV`, `BAB_SIT`, `BAB_CORE`  
**Agent Pool:** `cloudops-agent` (10.189.61.20)  
**CSV Location:** `C:\vm-to-clone\vm-to-clone.csv`

**Cloning Methods:**
- **Same Region:** Snapshot-based cloning (faster, more cost-effective)
- **Cross-Region:** VHD export/import with AzCopy (comprehensive migration)

## 👥 About This Pipeline

This VM cloning pipeline was developed by the BAB CloudOps Engineering Team to address our operational requirements for infrastructure scaling, disaster recovery testing, and environment management. Our engineers have years of hands-on experience managing critical banking workloads and have built this solution to meet strict banking industry standards for data security and operational reliability.

The design incorporates lessons learned from production VM migrations and reflects our real-world experience with Azure infrastructure management in regulated environments.

---

## 📁 Pipeline Components

Our engineering team has developed multiple pipeline variations to handle different cloning scenarios:

| File | Purpose | Use Case |
|------|---------|----------|
| `vm-clone-sub-crossregion.yaml` | Main cross-region cloning pipeline | Production to DR site migration |
| `vm-clone-sub-crossregion.ps1` | PowerShell implementation script | Direct execution and testing |
| `vm-clone-sub-mult.yaml` | Bulk VM cloning pipeline | Multiple VM migrations |
| `Clone-VMs.ps1` | Legacy standalone script | Manual operations |
| `vms-to-clone.csv` | CSV configuration template | VM definition format |

### Pipeline Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────────┐
│   Azure DevOps  │    │   CloudOps Agent │    │   Target Azure      │
│   Pipeline      │───▶│   (10.189.61.20) │───▶│   Environment       │
│                 │    │                  │    │                     │
└─────────────────┘    └──────────────────┘    └─────────────────────┘
         │                        │                        │
         ▼                        ▼                        ▼
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────────┐
│ CSV Input &     │    │ Snapshot/VHD     │    │ VM Creation &       │
│ Parameter       │    │ Management       │    │ Network Config      │
│ Validation      │    │                  │    │                     │
└─────────────────┘    └──────────────────┘    └─────────────────────┘
```

---

## ⚡ Quick Start

### Prerequisites
Our engineering team has configured the following infrastructure requirements:

1. **Azure DevOps Environment**:
   - Permissions to execute pipelines in BAB CloudOps project
   - Access to `cloudops-agent` pool (10.189.61.20)

2. **Service Principal Configuration** (managed by our security team):
   - Variable Group: `cloud-subs` containing:
     - `AZURE_CLIENT_ID` (Service Principal App ID)
     - `AZURE_CLIENT_SECRET` (Secure client secret, rotated quarterly)
     - `AZURE_TENANT_ID` (BAB Azure AD tenant identifier)
   - Variable Group: `AZ-Resources` containing subscription mappings

3. **Infrastructure Prerequisites** (verified by our operations team):
   - Target resource groups must exist with proper RBAC permissions
   - Network resources (VNet, subnets, NSGs) configured in target environment
   - Sufficient quota in target subscription for VM and disk resources
   - Storage accounts configured for VHD transfers (cross-region scenarios)

### Running the Pipeline
Follow these operational procedures established by our team:

1. **Prepare CSV Configuration**:
   - Update `C:\vm-to-clone\vm-to-clone.csv` on the agent server
   - Validate VM names and target configurations
   - Ensure network subnet names match target environment

2. **Execute Pipeline**:
   - Navigate to **Pipelines** → **vm-clone** in Azure DevOps
   - Select appropriate pipeline variant based on your scenario
   - Configure parameters for source and target environments
   - Monitor execution through Azure DevOps interface

3. **Post-Execution Validation**:
   - Verify VM creation and network connectivity
   - Test application functionality on cloned VMs
   - Review logs in `C:\log\clone_log.txt` for any issues

---

## 📊 CSV Configuration

### CSV File Location
**Agent Path:** `C:\vm-to-clone\vm-to-clone.csv`  
**Template:** Available as `vms-to-clone.csv` in repository

### Required CSV Format

Our team has standardized on this CSV structure for consistency:

```csv
SourceVMName,NewVMName,SubnetName,VMSize
```

### CSV Field Definitions

| Column | Required | Description | Example | Validation |
|--------|----------|-------------|---------|------------|
| `SourceVMName` | ✅ Yes | Name of source VM to clone | `DABASWBMSSLV1` | Must exist in source resource group |
| `NewVMName` | ✅ Yes | Name for the new cloned VM | `DASMEWBMSSLV1` | Must follow BAB naming convention |
| `SubnetName` | ✅ Yes | Target subnet for new VM | `sme-loan-subnet` | Must exist in target VNet |
| `VMSize` | ✅ Yes | Azure VM size for new VM | `Standard_D4s_v3` | Must be available in target region |

### CSV Examples from Our Environment

**Production to DR Migration:**
```csv
SourceVMName,NewVMName,SubnetName,VMSize
PROD-WEB-01,DR-WEB-01,dr-web-subnet,Standard_D2s_v3
PROD-DB-01,DR-DB-01,dr-db-subnet,Standard_E4s_v3
PROD-APP-01,DR-APP-01,dr-app-subnet,Standard_D4s_v3
```

**Development Environment Setup:**
```csv
SourceVMName,NewVMName,SubnetName,VMSize
SIT-TEMPLATE-01,DEV-WEB-01,dev-subnet,Standard_B2s
SIT-TEMPLATE-02,DEV-DB-01,dev-subnet,Standard_B4ms
```

### CSV Validation Rules

Our team enforces these validation standards:
- ✅ No duplicate `NewVMName` entries within the CSV
- ✅ Source VMs must exist and be accessible
- ✅ Target subnets must exist in destination VNet
- ✅ VM sizes must be available in target Azure region
- ✅ Names must follow BAB naming conventions for tracking

---

## 📊 Pipeline Parameters

### Required Parameters

| Parameter | Type | Description | Valid Values |
|-----------|------|-------------|--------------|
| `sourceSubscription` | String | Source Azure subscription | `BAB_DEV`, `BAB_SIT`, `BAB_CORE` |
| `targetSubscription` | String | Target Azure subscription | `BAB_DEV`, `BAB_SIT`, `BAB_CORE` |
| `sourceResourceGroup` | String | Source resource group name | Must exist in source subscription |
| `targetResourceGroup` | String | Target resource group name | Must exist in target subscription |

### Cross-Region Parameters (Additional)

| Parameter | Type | Description | Example |
|-----------|------|-------------|---------|
| `sourceVMName` | String | Single VM to clone | `DABASWBMSSLV1` |
| `newVMName` | String | Name for cloned VM | `DASMEWBMSSLV1` |
| `targetLocation` | String | Target Azure region | `East US 2`, `West Europe` |
| `targetVNetName` | String | Target virtual network | `bab-sit-vnet-01` |
| `targetSubnetName` | String | Target subnet name | `sme-loan-subnet` |

### Parameter Validation by Our Team

**Subscription Validation:**
- ✅ Only BAB subscriptions are supported for security compliance
- ✅ Cross-subscription cloning requires appropriate permissions
- ✅ Same-subscription cloning is optimized for speed

**Resource Group Validation:**
- ✅ Must exist in respective subscriptions
- ✅ Service principal must have Contributor access
- ✅ Sufficient quota must be available

**Network Configuration:**
- ✅ Target VNet and subnet must exist
- ✅ Network security groups properly configured
- ✅ IP address space available for new VMs

---

## 🔄 Operation Examples

### Example 1: Cross-Subscription Clone (Same Region)

**Scenario:** Clone production template to development environment

**Pipeline:** `vm-clone-sub-crossregion.yaml`

**Parameters:**
```yaml
sourceSubscription: BAB_SIT
targetSubscription: BAB_DEV
sourceResourceGroup: sit-templates-rg
targetResourceGroup: dev-environment-rg
sourceVMName: SIT-TEMPLATE-WEB
newVMName: DEV-WEB-01
targetLocation: East US 2
targetVNetName: bab-dev-vnet
targetSubnetName: dev-web-subnet
```

**Process Flow:**
1. Create snapshot of source VM disks in BAB_SIT
2. Copy snapshots to BAB_DEV subscription
3. Create new disks from copied snapshots
4. Build new VM with proper network configuration
5. Clean up temporary snapshots

**Expected Duration:** 15-30 minutes depending on disk sizes

### Example 2: Cross-Region Disaster Recovery Setup

**Scenario:** Create DR copies in different Azure region

**Pipeline:** `vm-clone-sub-crossregion.yaml`

**Parameters:**
```yaml
sourceSubscription: BAB_CORE
targetSubscription: BAB_CORE
sourceResourceGroup: prod-banking-rg
targetResourceGroup: dr-banking-rg
sourceVMName: PROD-BANKING-01
newVMName: DR-BANKING-01
targetLocation: West Europe
targetVNetName: bab-dr-vnet
targetSubnetName: dr-banking-subnet
```

**Process Flow:**
1. Export source VM disks to VHD files using AzCopy
2. Transfer VHDs to target region storage account
3. Create managed disks from VHDs in target region
4. Create new VM with replicated configuration
5. Configure network settings for DR environment

**Expected Duration:** 45-90 minutes for cross-region transfer

### Example 3: Bulk VM Migration

**Scenario:** Migrate multiple VMs using CSV configuration

**Pipeline:** `vm-clone-sub-mult.yaml`

**CSV Configuration:**
```csv
SourceVMName,NewVMName,SubnetName,VMSize
APP-SERVER-01,MIGRATED-APP-01,target-app-subnet,Standard_D4s_v3
DB-SERVER-01,MIGRATED-DB-01,target-db-subnet,Standard_E8s_v3
WEB-SERVER-01,MIGRATED-WEB-01,target-web-subnet,Standard_D2s_v3
```

**Result:**
- 3 VMs cloned with preserved configurations
- Network settings updated for target environment
- Data disks properly attached with original LUN assignments

---

## 🔧 Troubleshooting

### Common Issues Encountered by Our Team

#### Issue 1: Insufficient Permissions

**Error Message:**
```
ERROR: The client '...' with object id '...' does not have authorization to perform action 'Microsoft.Compute/virtualMachines/read'
```

**Solutions (Security Team Verified):**
1. Verify service principal has `Contributor` role on both source and target subscriptions
2. Check that resource group-level permissions are properly assigned
3. Ensure service principal is not blocked by conditional access policies
4. Validate client secret hasn't expired in Key Vault

#### Issue 2: Network Configuration Failures

**Error Message:**
```
ERROR: Subnet 'target-subnet' was not found in virtual network 'target-vnet'
```

**Solutions (Network Team Validated):**
1. Verify target VNet and subnet exist in target resource group
2. Check subnet names match exactly (case-sensitive)
3. Ensure subnet has available IP addresses
4. Validate network security group associations

#### Issue 3: Disk Quota Exceeded

**Error Message:**
```
ERROR: Operation failed due to quota limits exceeded for Standard_LRS disks
```

**Solutions (Operations Team Procedures):**
1. Check current disk quota usage in target subscription
2. Request quota increase through Azure support if needed
3. Clean up unused disks and snapshots to free quota
4. Consider using different disk SKU if appropriate

#### Issue 4: Cross-Region Transfer Failures

**Error Message:**
```
ERROR: AzCopy transfer failed with exit code 1
```

**Solutions (Engineering Team Experience):**
1. Check storage account accessibility and permissions
2. Verify network connectivity between regions
3. Monitor storage account throttling limits
4. Retry operation during off-peak hours

### Diagnostic Commands for Our Team

**Check Service Principal Access:**
```powershell
# Verify service principal login
az login --service-principal -u $AZURE_CLIENT_ID -p $AZURE_CLIENT_SECRET --tenant $AZURE_TENANT_ID

# List accessible subscriptions
az account list --query "[].{Name:name, Id:id, State:state}" --output table

# Check permissions on resource group
az role assignment list --assignee $AZURE_CLIENT_ID --resource-group "target-rg" --output table
```

**Validate Network Configuration:**
```powershell
# List VNets in target resource group
az network vnet list --resource-group "target-rg" --query "[].{Name:name, Location:location}" --output table

# Check subnet availability
az network vnet subnet show --resource-group "target-rg" --vnet-name "target-vnet" --name "target-subnet"

# Verify NSG associations
az network nsg list --resource-group "target-rg" --query "[].{Name:name, Subnets:subnets[].id}" --output table
```

### Log Analysis by Our Operations Team

**Log Location:** `C:\log\clone_log.txt`

**Critical Log Patterns to Monitor:**
```
[INFO] Starting VM clone operation                     # ✅ Process start
[INFO] Creating snapshot for disk: disk-name          # ✅ Snapshot creation
[INFO] VM vm-name created successfully               # ✅ VM creation success
[ERROR] Failed to create VM: error-details           # ❌ VM creation failure
[ERROR] Disk operation failed: disk-name             # ❌ Disk operation issue
[INFO] Cleanup completed: X snapshots deleted       # ✅ Cleanup success
```

---

## ✅ Best Practices

### 🔐 Security Best Practices (Security Team Standards)

Our security team has established these requirements:

1. **Service Principal Management:**
   - ✅ Use dedicated service principals for VM cloning operations only
   - ✅ Rotate client secrets every 90 days per security policy
   - ✅ Apply least-privilege access (Contributor on specific resource groups)
   - ✅ Monitor service principal activity through Azure AD logs

2. **Data Protection During Migration:**
   - ✅ Ensure encryption at rest is maintained during disk transfers
   - ✅ Use secure storage accounts for VHD transfer operations
   - ✅ Validate data integrity after clone operations
   - ✅ Clean up temporary snapshots and VHDs immediately after use

### 📋 Operational Best Practices (Operations Team Experience)

Based on our team's production experience:

3. **Planning and Scheduling:**
   - ✅ Schedule large clone operations during maintenance windows
   - ✅ Coordinate with application teams before cloning production VMs
   - ✅ Plan for extended durations during cross-region operations
   - ✅ Validate network and quota capacity before execution

4. **Pre-Execution Validation:**
   - ✅ Test CSV configuration with small subset of VMs first
   - ✅ Verify target network configuration and IP availability
   - ✅ Confirm sufficient storage quota in target subscription
   - ✅ Validate application dependencies and requirements

5. **Monitoring and Verification:**
   - ✅ Monitor clone operations in real-time through Azure Portal
   - ✅ Verify VM functionality post-clone (network, applications, data)
   - ✅ Test backup and recovery procedures for cloned VMs
   - ✅ Document any configuration changes required post-migration

### 🔧 Technical Best Practices (Engineering Team Optimizations)

6. **Performance Optimization:**
   - ✅ Use same-region cloning when possible for faster operations
   - ✅ Schedule cross-region transfers during off-peak hours
   - ✅ Optimize VM sizes based on actual usage patterns
   - ✅ Consider disk performance tiers for cloned environments

7. **Error Handling and Recovery:**
   - ✅ Implement proper rollback procedures for failed operations
   - ✅ Monitor and alert on clone operation failures
   - ✅ Maintain documentation of common issues and solutions
   - ✅ Regular testing of disaster recovery clone procedures

### 💰 Cost Optimization (Finance Team Requirements)

8. **Resource Management:**
   - ✅ Clean up temporary snapshots and VHDs immediately after use
   - ✅ Right-size cloned VMs based on actual requirements
   - ✅ Use Standard_LRS disks for non-production environments
   - ✅ Monitor and optimize storage costs for VHD transfers

---

## 📝 Change Log

Our CloudOps engineering team maintains this development history:

| Version | Date | Changes | Author | Impact |
|---------|------|---------|---------|--------|
| 1.0.0 | 2025-11-07 | Initial VM cloning pipeline development | BAB CloudOps Engineering Team | Production-ready cross-subscription cloning |
| 1.1.0 | 2025-11-07 | Added cross-region cloning capabilities | BAB CloudOps Engineering Team | Enhanced DR and migration support |
| 1.2.0 | 2025-11-07 | Comprehensive documentation and procedures | BAB CloudOps Engineering Team | Improved operational guidance |

---

## 📜 Maintenance & Support

**Developed and Maintained by:** BAB CloudOps Engineering Team  
**Documentation Last Updated:** 2025-11-07  
**Support Level:** Production Environment (24/7 Coverage)  
**Internal Repository:** BAB_CloudOps on GitHub

### Internal Support

**BAB CloudOps Engineering Team:**
- Teams Channel: `BAB CloudOps` (primary support)
- Documentation: [BAB CloudOps Repository](https://github.com/Ankojin/BAB_CloudOps)
- Pipeline: [VM Clone Pipelines](https://dev.azure.com/BAB/CloudOps/_build)
- On-Call Engineer: Available 24/7 for production migration issues

### Escalation Process

Our CloudOps engineering team has established this support structure:

1. **Level 1 - Self-Service:**
   - Review this comprehensive documentation created by our engineering team
   - Check troubleshooting section for common issues we've resolved
   - Validate CSV configuration and parameters

2. **Level 2 - Team Support:**
   - Post in Teams `BAB CloudOps` channel with complete details:
     - Pipeline run ID and execution timestamp
     - Source and target environment details
     - CSV configuration and parameters used
     - Error messages and log file excerpts

3. **Level 3 - Senior Engineer Escalation:**
   - Create Azure DevOps incident for critical production migrations
   - Include complete logs, environment configuration, and business impact
   - Our senior engineers provide immediate response for production-critical issues

**Related Microsoft Documentation:**
- [Azure VM Migration](https://docs.microsoft.com/en-us/azure/virtual-machines/migration-classic-resource-manager-overview)
- [Azure CLI VM Commands](https://docs.microsoft.com/en-us/cli/azure/vm)
- [Cross-Region Replication](https://docs.microsoft.com/en-us/azure/storage/common/storage-redundancy)

---

**Questions or Issues?** Contact the BAB CloudOps Engineering Team via our Teams channel or create an Azure DevOps work item. Our engineering team is committed to providing timely support for all VM migration and cloning operations in our banking infrastructure.