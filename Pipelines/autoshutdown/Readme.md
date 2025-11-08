# Azure VM Auto-Shutdown Pipelines

This folder contains Azure DevOps pipelines to configure auto-shutdown schedules for Azure VMs using Terraform. The solution provides cost optimization by automatically shutting down VMs at specified times across multiple Azure subscriptions and resource groups.

## 📁 Directory Contents

| File | Description |
|------|-------------|
| `autoshutdown-single.yml` | Pipeline for configuring a single resource group |
| `autoshutdown-multiple-csv.yml` | Pipeline for configuring multiple resource groups via CSV |
| `main.tf` | Terraform configuration for VM auto-shutdown |
| `multiple_csv.csv` | CSV configuration file for bulk operations |
| `csv-examples.md` | Examples and validation scenarios for CSV format |
| `create-functions.ps1` | PowerShell functions for pipeline operations |
| `process-csv-data.ps1` | CSV data processing script |
| `process-resource-groups.ps1` | Resource group processing script |
| `Readme.md` | This documentation file |

## 📋 Available Pipelines

### 1. **Single Resource Group Pipeline** (`autoshutdown-single.yml`)
Configure auto-shutdown for VMs in a single resource group.

**Use this when:**
- You need to configure one resource group at a time
- You prefer a simple UI form
- Testing configurations before bulk deployment

**Parameters:**
- **Subscription**: BAB_DEV, BAB_SIT, BAB_CORE
- **Resource Group Name**: Target resource group
- **DB VM Names**: Comma-separated database VM names (optional)
- **DB Shutdown Time**: HHmm format (e.g., 2200 for 10:00 PM)
- **App VM Names**: Comma-separated application VM names (optional)
- **App Shutdown Time**: HHmm format (e.g., 2000 for 8:00 PM)
- **Time Zone**: Default is 'Arab Standard Time'

**State File Location:**
- Path: `C:\TerraformState\autoshutdown\<subscription>-<resource-group>.tfstate`
- Example: `C:\TerraformState\autoshutdown\BAB_DEV-rg-dev-app.tfstate`

### 2. **Multiple Resource Groups Pipeline** (`autoshutdown-multiple-csv.yml`)
Configure auto-shutdown for multiple resource groups across different subscriptions using a CSV file.

**Use this when:**
- You need to configure multiple resource groups at once
- You want to manage configurations in Excel/CSV
- You need to apply settings across different subscriptions
- Performing bulk operations for cost optimization

**Setup:**
1. Edit `multiple_csv.csv` with your configuration
2. Commit the file to the repository
3. Run the pipeline with optional Time Zone parameter

**State File Location:**
- Path: `C:\TerraformState\autoshutdown\<subscription>-<resource-group>.tfstate`
- Each resource group gets its own state file
- Example: `C:\TerraformState\autoshutdown\BAB_SIT-rg-sit-app.tfstate`

**CSV Format:**
```csv
Subscription,ResourceGroupName,DBVMs,DBShutdownTime,AppVMs,AppShutdownTime
BAB_DEV,rg-dev-app,sql-dev-01,2200,web-dev-01,2000
BAB_SIT,bab-sit-pbi-swec-rg-01,DAPPIDBSWV1,2000,"DAPPIAPSWV1,DACDBPBISWV1",1950
```

## 🚀 Quick Start

### Single Resource Group
1. Navigate to Pipelines in Azure DevOps
2. Select `autoshutdown-single` pipeline
3. Click "Run pipeline"
4. Fill in the parameters
5. Click "Run"

### Multiple Resource Groups
1. Edit `Pipelines/autoshutdown/multiple_csv.csv`
2. Add your resource group configurations
3. Commit and push to repository
4. Navigate to Pipelines in Azure DevOps
5. Select `autoshutdown-multiple-csv` pipeline
6. Click "Run pipeline"

## 📊 CSV Configuration Format

### Required Columns

| Column | Required | Description | Example |
|--------|----------|-------------|---------|
| `Subscription` | ✅ Yes | Subscription name (BAB_DEV, BAB_SIT, BAB_CORE) | BAB_DEV |
| `ResourceGroupName` | ✅ Yes | Name of the resource group | rg-prod-app |
| `DBVMs` | ❌ Optional | Comma-separated DB VM names | sql-vm-01,sql-vm-02 |
| `DBShutdownTime` | ❌ Optional | Shutdown time for DB VMs (HHmm) | 2200 |
| `AppVMs` | ❌ Optional | Comma-separated App VM names | web-vm-01,api-vm-01 |
| `AppShutdownTime` | ❌ Optional | Shutdown time for App VMs (HHmm) | 2000 |

### CSV Validation Rules

✅ **Valid Configurations:**
- At least one VM type (DBVMs or AppVMs) must be specified per row
- Empty columns are allowed (leave blank if not needed)
- Multiple VMs can be specified using comma separation
- Quotes can be used around VM lists: `"vm1,vm2,vm3"`
- Missing shutdown times default to 2000 (8:00 PM)

❌ **Invalid Configurations:**
- Rows with no VMs specified in either DBVMs or AppVMs columns
- Resource groups that don't exist in the specified subscription
- VM names that don't exist in the specified resource group

### Example CSV Configurations

**1. Mixed Environment (Production):**
```csv
Subscription,ResourceGroupName,DBVMs,DBShutdownTime,AppVMs,AppShutdownTime
BAB_CORE,rg-prod-backend,sql-prod-01,2300,"api-prod-01,api-prod-02",2200
BAB_CORE,rg-prod-frontend,,,web-prod-01,2100
BAB_CORE,rg-prod-data,postgres-prod-01,2359,,
```

**2. Development Environment:**
```csv
Subscription,ResourceGroupName,DBVMs,DBShutdownTime,AppVMs,AppShutdownTime
BAB_DEV,rg-dev-main,mysql-dev-01,1900,"web-dev-01,app-dev-01",1800
BAB_DEV,rg-dev-test,,,test-vm-01,1700
```

**3. Current Production Configuration:**
```csv
Subscription,ResourceGroupName,DBVMs,DBShutdownTime,AppVMs,AppShutdownTime
BAB_SIT,bab-sit-pbi-swec-rg-01,DAPPIDBSWV1,2000,"DAPPIAPSWV1,DACDBPBISWV1",1950
BAB_DEV,BAB-DEV-PBI-SWEC-RG-01,DAPBIDBSQDWV1,2000,,2000
```

**Notes:**
- Time format: HHmm (24-hour format, e.g., 2200 for 10:00 PM)
- Use quotes around VM lists containing commas for better CSV parsing
- Leave empty cells for unused VM types or default shutdown times

## 🔧 Terraform State Management

### State File Location
All Terraform state files are stored locally on the Azure DevOps agent:
- **Base Directory:** `C:\TerraformState\autoshutdown\`
- **Naming Convention:** `<Subscription>-<ResourceGroupName>.tfstate`

### State File Benefits
✅ **Isolated State per Resource Group** - Each resource group has its own state file, preventing conflicts  
✅ **Fast State Operations** - Local storage provides faster read/write operations  
✅ **No Azure Storage Costs** - No need for Azure Storage Account for state  
✅ **Agent-based** - State persists on the agent machine between runs  

### State File Examples

**Single Resource Group:**
```
C:\TerraformState\autoshutdown\BAB_DEV-rg-dev-app.tfstate
```

**Multiple Resource Groups:**
```
C:\TerraformState\autoshutdown\BAB_DEV-rg-dev-app.tfstate
C:\TerraformState\autoshutdown\BAB_DEV-rg-dev-data.tfstate
C:\TerraformState\autoshutdown\BAB_SIT-rg-sit-app.tfstate
C:\TerraformState\autoshutdown\BAB_CORE-rg-prod-app.tfstate
```

### State File Lifecycle

1. **First Run:** State file is created in `C:\TerraformState\autoshutdown\`
2. **Subsequent Runs:** Terraform reads existing state and updates it
3. **Updates:** State is updated with current configuration
4. **Concurrent Runs:** Each resource group has isolated state, allowing parallel execution

### Important Considerations

⚠️ **Agent Persistence:**
- State files persist on the agent machine
- If the agent is rebuilt, state files are lost
- Consider backing up the state directory regularly

⚠️ **Concurrent Execution:**
- Safe for different resource groups (isolated state files)
- Do NOT run the same resource group configuration simultaneously
- Pipeline locks prevent concurrent runs for the same resource group

⚠️ **State File Cleanup:**
- State files accumulate over time
- Periodically review and clean up unused state files
- Keep state files for active resource groups

### Backup Recommendations

```powershell
# Manual backup script (run on agent)
$source = "C:\TerraformState\autoshutdown"
$destination = "C:\TerraformState\backups\autoshutdown-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item -Path $source -Destination $destination -Recurse
```

Consider setting up automated backups:
- Schedule: Daily or weekly
- Retention: 30 days
- Location: Network share or Azure Blob Storage

## ✅ Best Practices

### 🔐 Security Best Practices
1. **Never hardcode credentials** - Use Azure Key Vault and variable groups
2. **Limit service principal permissions** - Grant minimum required access (Contributor + DevTest Labs User)
3. **Regular credential rotation** - Update client secrets in Key Vault quarterly
4. **Audit trail maintenance** - Monitor all pipeline executions and state changes
5. **Secure state files** - Restrict access to `C:\TerraformState` directory

### 📋 Operational Best Practices
6. **Test in BAB_DEV first** before applying to BAB_SIT or BAB_CORE
7. **Use CSV pipeline for bulk operations** to save time and ensure consistency
8. **Keep CSV file in source control** for audit trail and change tracking
9. **Document changes** in commit messages with business justification
10. **Review Terraform plan output** before applying changes

### 🔧 Technical Best Practices
11. **Monitor state file growth** - Large state files may indicate configuration drift
12. **Don't manually edit state files** - Always use Terraform commands
13. **Back up state files** before major changes or agent maintenance
14. **Use descriptive resource group names** to avoid state conflicts
15. **Clean up old state files** for decommissioned resource groups

### 📊 Pipeline Management Best Practices
16. **Avoid concurrent runs** for the same resource group to prevent conflicts
17. **Check state file existence** before major operations or migrations
18. **Verify agent disk space** regularly for state directory (`C:\TerraformState`)
19. **Document state file locations** in runbooks and operational procedures
20. **Schedule regular reviews** of auto-shutdown configurations for cost optimization

### 🕒 Time Zone Considerations
21. **Use consistent time zones** across environments (default: Arab Standard Time)
22. **Account for daylight saving time** when setting shutdown schedules
23. **Coordinate with business hours** to avoid disrupting active workloads
24. **Test shutdown schedules** in development before production deployment

### 💰 Cost Optimization
25. **Regular review of VM usage** patterns to optimize shutdown times
26. **Monitor cost savings** after implementing auto-shutdown
27. **Adjust schedules seasonally** based on business calendar
28. **Document exceptions** for VMs that require 24/7 operation

## 🏗️ Architecture & How It Works

### Solution Overview
The auto-shutdown solution uses **Azure DevOps Pipelines** + **Terraform** + **Azure Auto-Shutdown Schedules** to configure cost-effective VM management across multiple subscriptions.

### Component Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────────┐
│   Azure DevOps  │    │   Terraform      │    │   Azure Resources   │
│   Pipelines     │───▶│   Configuration  │───▶│   VM Auto-Shutdown  │
│                 │    │                  │    │   Schedules         │
└─────────────────┘    └──────────────────┘    └─────────────────────┘
         │                        │                        │
         ▼                        ▼                        ▼
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────────┐
│ CSV Input Files │    │ State Management │    │ Cost Optimization   │
│ Parameters      │    │ (Local Backend)  │    │ Automated Shutdown  │
└─────────────────┘    └──────────────────┘    └─────────────────────┘
```

### Process Flow

1. **Input Configuration**: Either UI parameters (single) or CSV file (multiple)
2. **Authentication**: Service Principal connects to target Azure subscription
3. **Terraform Initialization**: Sets up provider and local state backend
4. **Resource Discovery**: Validates VM existence in specified resource groups
5. **Configuration Application**: Creates/updates auto-shutdown schedules per VM
6. **State Management**: Stores configuration state locally for future updates

### Key Benefits

✅ **Multi-Subscription Support**: Works across BAB_DEV, BAB_SIT, and BAB_CORE  
✅ **Isolated State Management**: Each resource group has separate state file  
✅ **Cost Optimization**: Automated shutdown reduces infrastructure costs  
✅ **Flexible Scheduling**: Different shutdown times for DB vs App VMs  
✅ **Audit Trail**: All changes tracked in Azure DevOps and Git  
✅ **Scalable**: Handles single VMs to hundreds via CSV bulk operations  

### State Management Details

- **Backend**: Terraform local backend for simplicity and performance
- **Location**: `C:\TerraformState\autoshutdown\` on Azure DevOps agent
- **Naming**: `<Subscription>-<ResourceGroup>.tfstate` for isolation
- **Benefits**: No Azure Storage costs, fast operations, isolated changes

### Security Model

- **Authentication**: Service Principal with least-privilege access
- **Secrets**: Stored in Azure Key Vault, referenced via variable groups
- **RBAC**: Contributor + DevTest Labs User roles on target subscriptions
- **Audit**: All pipeline runs logged and tracked in Azure DevOps

## 📝 Examples

### Example 1: Single Resource Group with DB VMs Only
**Scenario**: Configure auto-shutdown for development database servers

**Pipeline**: `autoshutdown-single.yml`
**Parameters**:
- Subscription: `BAB_DEV`
- Resource Group: `rg-dev-database`
- DB VMs: `sql-dev-01,postgres-dev-01,mysql-dev-01`
- DB Shutdown Time: `2200`
- App VMs: *(leave empty)*
- Time Zone: `Arab Standard Time`

**Result**:
- State File: `C:\TerraformState\autoshutdown\BAB_DEV-rg-dev-database.tfstate`
- All DB VMs will shutdown at 10:00 PM daily

### Example 2: Mixed Environment with Different Schedules
**Scenario**: Production environment with staggered shutdown times

**Pipeline**: `autoshutdown-single.yml`
**Parameters**:
- Subscription: `BAB_CORE`
- Resource Group: `rg-prod-ecommerce`
- DB VMs: `sql-prod-01,sql-prod-02`
- DB Shutdown Time: `2300` *(11:00 PM - later for data processing)*
- App VMs: `web-prod-01,api-prod-01,cache-prod-01`
- App Shutdown Time: `2200` *(10:00 PM - earlier as no late traffic)*
- Time Zone: `Arab Standard Time`

**Result**:
- State File: `C:\TerraformState\autoshutdown\BAB_CORE-rg-prod-ecommerce.tfstate`
- App VMs shutdown at 10:00 PM, DB VMs at 11:00 PM

### Example 3: Multiple Resource Groups via CSV
**Scenario**: Bulk configuration across development and staging environments

**File**: `multiple_csv.csv`
```csv
Subscription,ResourceGroupName,DBVMs,DBShutdownTime,AppVMs,AppShutdownTime
BAB_DEV,rg-dev-microservices,mysql-dev-01,2000,"api-dev-01,web-dev-01,worker-dev-01",1900
BAB_DEV,rg-dev-analytics,postgres-dev-01,2100,,
BAB_SIT,rg-sit-frontend,,,nginx-sit-01,2030
BAB_SIT,bab-sit-pbi-swec-rg-01,DAPPIDBSWV1,2000,"DAPPIAPSWV1,DACDBPBISWV1",1950
```

**Pipeline**: `autoshutdown-multiple-csv.yml`
**Parameters**:
- Time Zone: `Arab Standard Time`

**Result**:
- Four state files created, one per resource group
- Mixed shutdown schedules based on business requirements
- Covers multiple subscription environments

### Example 4: Cost Optimization for Test Environment
**Scenario**: Aggressive shutdown schedule for cost savings in test environment

**CSV Configuration**:
```csv
Subscription,ResourceGroupName,DBVMs,DBShutdownTime,AppVMs,AppShutdownTime
BAB_DEV,rg-test-performance,testdb-01,1800,testapp-01,1730
BAB_DEV,rg-test-integration,,,integration-vm-01,1700
BAB_DEV,rg-test-automation,,,selenium-grid-01,1900
```

**Business Logic**:
- Test VMs shutdown earlier (5:30-7:00 PM) for maximum cost savings
- No weekend/holiday exceptions for test environments
- Can be restarted manually when needed

### Example 5: Current Production Setup
**Scenario**: Existing BI/Analytics environment configuration

**Current CSV**:
```csv
Subscription,ResourceGroupName,DBVMs,DBShutdownTime,AppVMs,AppShutdownTime
BAB_SIT,bab-sit-pbi-swec-rg-01,DAPPIDBSWV1,2000,"DAPPIAPSWV1,DACDBPBISWV1",1950
BAB_DEV,BAB-DEV-PBI-SWEC-RG-01,DAPBIDBSQDWV1,2000,,2000
```

**Analysis**:
- SIT environment: Staggered shutdown (App VMs at 7:50 PM, DB at 8:00 PM)
- DEV environment: DB-only configuration with 8:00 PM shutdown
- Follows naming convention for BI/Power BI workloads

## 🆘 Troubleshooting

### Common Issues & Solutions

#### CSV-Related Issues

**Issue: CSV file not found or not reading correctly**
```
Error: No such file or directory: 'multiple_csv.csv'
```
**Solutions:**
1. Ensure `multiple_csv.csv` is committed to the repository in the correct path: `Pipelines/autoshutdown/multiple_csv.csv`
2. Check file encoding - should be UTF-8
3. Verify the file isn't empty or corrupted
4. Check for proper CSV format with headers

**Issue: CSV validation errors**
```
Error: Invalid CSV format or missing required columns
```
**Solutions:**
1. Verify all required columns exist: `Subscription,ResourceGroupName,DBVMs,DBShutdownTime,AppVMs,AppShutdownTime`
2. Check for extra spaces in column headers
3. Ensure at least one VM type is specified per row
4. Use quotes around VM lists containing commas: `"vm1,vm2,vm3"`

#### Azure Authentication Issues

**Issue: Subscription ID not resolved**
```
Error: Cannot find subscription 'BAB_DEV'
```
**Solutions:**
1. Verify variable group `cloud-subs` contains subscription IDs for all three subscriptions
2. Check that subscription mappings are correctly configured in Azure DevOps
3. Ensure service connection has access to the subscription

**Issue: Service Principal permissions**
```
Error: Insufficient privileges to complete the operation
```
**Solutions:**
1. Verify service principal has `Contributor` role on target subscriptions
2. Check that service principal has `DevTest Labs User` role for auto-shutdown resources
3. Ensure client secret hasn't expired in Key Vault

#### Terraform Issues

**Issue: Terraform validation failed**
```
Error: Resource not found or VM doesn't exist
```
**Solutions:**
1. Verify VM names exist in the specified resource group
2. Check that VMs are running and accessible
3. Ensure resource group exists in the specified subscription
4. Validate VM names don't contain special characters or spaces

**Issue: State file permission denied**
```
Error: Failed to write state file
```
**Solutions:**
1. Check agent service account has write access to `C:\TerraformState`
2. Verify folder permissions: `icacls C:\TerraformState`
3. Ensure no other process is locking the state file
4. Check available disk space on agent

**Issue: State file corrupted**
```
Error: Failed to load backend: state file corrupted
```
**Solutions:**
1. Stop all pipeline runs for the affected resource group
2. Restore from backup: `C:\TerraformState\backups\`
3. If no backup exists, delete state file and re-run pipeline (will recreate resources)
4. Check agent disk health

#### Pipeline Execution Issues

**Issue: Multiple pipelines running concurrently**
```
Warning: Resource group already being processed
```
**Solutions:**
1. Check if another pipeline is running for the same resource group
2. Wait for the other pipeline to complete
3. Local backend doesn't support state locking; avoid concurrent runs
4. Cancel conflicting pipeline runs if necessary

**Issue: Agent pool capacity**
```
Error: No agents available in pool 'cloudops-agent'
```
**Solutions:**
1. Check agent status in Azure DevOps
2. Restart Azure DevOps agent service if needed
3. Verify agent machine is online and accessible
4. Check agent disk space and memory usage

### Diagnostic Commands

**Check State Files:**
```powershell
# List all state files
Get-ChildItem "C:\TerraformState\autoshutdown\" -Filter "*.tfstate" | 
  Select-Object Name, Length, LastWriteTime

# Check specific state file size
(Get-Item "C:\TerraformState\autoshutdown\BAB_DEV-rg-dev-app.tfstate").Length / 1KB
```

**Validate CSV File:**
```powershell
# Import and validate CSV
$csv = Import-Csv ".\multiple_csv.csv"
$csv | ForEach-Object { 
  if (-not $_.DBVMs -and -not $_.AppVMs) { 
    Write-Warning "Row $($_.ResourceGroupName) has no VMs specified" 
  } 
}
```

**Check Azure Resources:**
```powershell
# Verify resource group exists
Get-AzResourceGroup -Name "your-rg-name" -ErrorAction SilentlyContinue

# List VMs in resource group  
Get-AzVM -ResourceGroupName "your-rg-name" | Select-Object Name, PowerState
```

### Getting Help

For additional support:
1. Check Azure DevOps pipeline logs for detailed error messages
2. Review Terraform plan output before applying changes
3. Consult the `csv-examples.md` file for valid CSV formats
4. Contact the CloudOps team for infrastructure issues
5. Check Azure portal for resource status and configuration

## 🔍 State File Inspection

### View State File Contents
```powershell
# View state file in JSON format
Get-Content "C:\TerraformState\autoshutdown\BAB_DEV-rg-dev-app.tfstate" | ConvertFrom-Json | ConvertTo-Json -Depth 10
```

### List All State Files
```powershell
# List all state files
Get-ChildItem "C:\TerraformState\autoshutdown\" -Filter "*.tfstate" | Select-Object Name, Length, LastWriteTime
```

### Check State File Size
```powershell
# Check size of specific state file
(Get-Item "C:\TerraformState\autoshutdown\BAB_DEV-rg-dev-app.tfstate").Length / 1KB
```

## 🔐 Security Considerations

1. **Access Control:**
   - Restrict access to `C:\TerraformState` directory
   - Only agent service account should have write access
   - Implement folder-level encryption if required

2. **Sensitive Data:**
   - State files may contain sensitive information
   - Do not commit state files to source control
   - Ensure backups are stored securely

3. **Audit Trail:**
   - Monitor access to state files
   - Log all pipeline runs that modify state
   - Maintain change history in Azure DevOps

## 📞 Support & Contact

### 🎯 Quick Help Resources
- **CSV Format Help**: Check `csv-examples.md` for valid configuration examples
- **Pipeline Logs**: Review Azure DevOps pipeline execution logs for detailed errors
- **Terraform Documentation**: [Official Terraform Docs](https://www.terraform.io/docs/)
- **Azure Auto-Shutdown**: [Microsoft Documentation](https://docs.microsoft.com/en-us/azure/automation/automation-solution-vm-management)

### 🔧 Self-Service Troubleshooting
1. **Validation Issues**: Use the diagnostic PowerShell commands in the troubleshooting section
2. **CSV Problems**: Compare your file format with examples in `csv-examples.md`
3. **State File Issues**: Check the state management section for common solutions
4. **Permission Errors**: Verify service principal permissions and variable group configuration

### � Contact Information
- **CloudOps Team**: For infrastructure and pipeline configuration issues
- **Azure Support**: For Azure platform-specific problems
- **DevOps Team**: For Azure DevOps pipeline and agent issues

### 📋 When Contacting Support
Please provide:
1. **Pipeline Run URL** from Azure DevOps
2. **Error messages** (copy exact text from logs)
3. **CSV file content** (if using multiple resource groups pipeline)
4. **Subscription and resource group** affected
5. **Expected vs actual behavior**

### 🚨 Emergency Contacts
- **Production Issues**: CloudOps on-call team
- **Security Incidents**: Information Security team
- **Service Principal Issues**: Identity & Access Management team

---

## 📚 Additional Resources

### Related Documentation
- **BAB CloudOps Guidelines**: `.github/copilot-instructions.md`
- **Azure PowerShell Scripts**: `Azure-Scripts/` directory
- **Terraform Modules**: `autoshutdown/main.tf`
- **VM Creation Procedures**: `VM-Creation/` directory

### External Links
- [Azure Resource Management Best Practices](https://docs.microsoft.com/en-us/azure/azure-resource-manager/management/best-practices)
- [Terraform Azure Provider](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs)
- [Azure DevOps Pipelines](https://docs.microsoft.com/en-us/azure/devops/pipelines/)
- [Azure Cost Management](https://docs.microsoft.com/en-us/azure/cost-management-billing/)

### Version History
- **v1.0** (Initial): Basic single resource group pipeline
- **v2.0** (Current): Added CSV bulk operations and enhanced state management
- **v2.1** (Latest): Improved error handling and comprehensive documentation

---

*Last Updated: November 2025*  
*Maintained by: BAB CloudOps Team*
