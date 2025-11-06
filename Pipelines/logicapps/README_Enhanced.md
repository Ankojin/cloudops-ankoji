# Azure Logic Apps - Enhanced VM Start Automation

This enhanced pipeline provides **dual deployment modes** for Azure Logic Apps that start Virtual Machines on a scheduled basis, supporting both single deployments and CSV-based bulk deployments.

## 🆕 What's New in Enhanced Version

### **Deployment Modes**
1. **Single Mode** - Deploy individual Logic Apps (same as original pipeline)
2. **CSV Mode** - Deploy multiple Logic Apps from a CSV file for bulk operations

### **Key Enhancements**
- ✅ **CSV-driven bulk deployment** - Deploy dozens of Logic Apps at once
- ✅ **Structured logging** - Following BAB CloudOps logging standards
- ✅ **Enhanced validation** - Comprehensive input validation for both modes
- ✅ **Parameterized resource groups** - No more hardcoded values
- ✅ **Error resilience** - Continue processing other deployments if one fails
- ✅ **Detailed reporting** - Success/failure summary for bulk operations

## 📋 Prerequisites

### Required Access
- Azure DevOps access with pipeline run permissions
- Azure subscription access (BAB_DEV or BAB_SIT)
- Logic Apps deployed to BAB_CORE subscription

### Required Variables
The following variable group must be configured in Azure DevOps: `cloud-subs`

Required variables:
- `AZURE_CLIENT_ID` - Service Principal Application ID
- `AZURE_CLIENT_SECRET` - Service Principal Secret
- `AZURE_TENANT_ID` - Azure AD Tenant ID
- `BAB_CORE_SUBSCRIPTION_ID` - Subscription ID for Logic Apps
- `BAB_DEV_SUBSCRIPTION_ID` - Subscription ID for DEV VMs
- `BAB_SIT_SUBSCRIPTION_ID` - Subscription ID for SIT VMs

## 🎛️ Pipeline Parameters

### **Deployment Mode Selection**
| Parameter | Description | Default | Values |
|-----------|-------------|---------|--------|
| **Deployment Mode** | Choose deployment method | Single | Single, CSV |

### **Environment Selection**
| Parameter | Description | Default | Required |
|-----------|-------------|---------|----------|
| **Environment** | Target environment for VMs | BAB_DEV | Yes |

Options: `BAB_DEV` or `BAB_SIT`

### **CSV Mode Parameters**
| Parameter | Description | Example | Required |
|-----------|-------------|---------|----------|
| **CSV File Path** | Path to CSV file (relative to repo root) | `Pipelines/logicapps/vm-deployments.csv` | Yes (CSV mode) |

### **Single Mode Parameters**
*Same as original pipeline - see below for details*

| Parameter | Description | Example | Required |
|-----------|-------------|---------|----------|
| **Logic App Prefix** | Naming prefix for Logic Apps | `BAB_RG_Env` | Yes (Single mode) |
| **Database Resource Group** | Resource group containing DB VMs | `myapp-db-rg` | Optional* |
| **Database VM Names** | Comma-separated list of DB VM names | `dbvm01,dbvm02` | Optional* |
| **DB Start Hour** | Hour to start DB VMs (0-23) | `7` | Optional* |
| **DB Start Minute** | Minute to start DB VMs (0-59) | `0` | Optional* |
| **App/Web Resource Group** | Resource group containing App/Web VMs | `myapp-web-rg` | Optional* |
| **App/Web VM Names** | Comma-separated list of App/Web VM names | `appvm01,webvm01` | Optional* |
| **App/Web Start Hour** | Hour to start App/Web VMs (0-23) | `8` | Optional* |
| **App/Web Start Minute** | Minute to start App/Web VMs (0-59) | `0` | Optional* |

*Set to `none` to skip

### **Common Parameters**
| Parameter | Description | Default | Required |
|-----------|-------------|---------|----------|
| **Logic App Subscription** | Subscription where Logic Apps are deployed | BAB_CORE | Yes |
| **Logic App Resource Group** | Resource group for Logic Apps | `bab-core-auto-weeu-rg-01` | Yes |
| **Week Days** | Days to run (comma-separated) | `Sunday,Monday,Tuesday,Wednesday,Thursday` | Yes |

## 📊 CSV Mode Configuration

### **CSV File Structure**

The CSV file must contain the following columns:

| Column | Description | Example | Required |
|--------|-------------|---------|----------|
| **LogicAppType** | Type identifier (Database/Application/Web) | `Database` | Yes |
| **LogicAppName** | Unique name for the Logic App | `bab_dev_hr_db_start` | Yes |
| **ResourceGroup** | Resource group containing the VMs | `bab-dev-hr-rg` | Yes |
| **VmNames** | Comma-separated VM names | `hrdb01,hrdb02` | Yes |
| **StartHour** | Hour to start VMs (0-23) | `6` | Yes |
| **StartMinute** | Minute to start VMs (0-59) | `30` | Yes |
| **WeekDays** | Days to run (comma-separated) | `Sunday,Monday,Tuesday,Wednesday,Thursday` | Optional* |
| **DefinitionFile** | Path to Logic App definition JSON | `Pipelines/logicapps/logicapp_start.json` | Optional* |

*Optional columns will use defaults if not provided

### **Sample CSV File**

```csv
LogicAppType,LogicAppName,ResourceGroup,VmNames,StartHour,StartMinute,WeekDays,DefinitionFile
Database,bab_dev_hr_db_start,bab-dev-hr-rg,hrdb01,hrdb02,6,30,"Sunday,Monday,Tuesday,Wednesday,Thursday",Pipelines/logicapps/logicapp_start.json
Application,bab_dev_hr_app_start,bab-dev-hr-rg,hrapp01,hrapp02,hrapp03,7,0,"Sunday,Monday,Tuesday,Wednesday,Thursday",Pipelines/logicapps/logicapp_start.json
Web,bab_dev_hr_web_start,bab-dev-hr-web-rg,hrweb01,hrweb02,7,15,"Sunday,Monday,Tuesday,Wednesday,Thursday",Pipelines/logicapps/logicapp_start.json
Database,bab_dev_fin_db_start,bab-dev-finance-rg,findb01,6,0,"Monday,Tuesday,Wednesday,Thursday,Friday",Pipelines/logicapps/logicapp_start.json
Application,bab_dev_fin_app_start,bab-dev-finance-rg,finapp01,finapp02,6,30,"Monday,Tuesday,Wednesday,Thursday,Friday",Pipelines/logicapps/logicapp_start.json
```

### **CSV Validation Rules**

1. **Required Columns**: All required columns must be present
2. **Data Types**: StartHour and StartMinute must be numeric
3. **VM Names**: Multiple VMs separated by commas (no spaces)
4. **Week Days**: Valid day names, comma-separated
5. **Logic App Names**: Must be unique within the deployment
6. **File Existence**: Definition files must exist

## 🚀 Usage Instructions

### **Step 1: Choose Your Deployment Mode**

#### **For Single Deployments** (1-2 Logic Apps)
- Use **Single Mode**
- Fill in the individual parameters
- Same workflow as original pipeline

#### **For Bulk Deployments** (Multiple Logic Apps)
- Use **CSV Mode**
- Prepare your CSV file
- Upload to the repository

### **Step 2: Prepare CSV File (CSV Mode Only)**

1. **Create CSV file** using the template above
2. **Save to repository** at `Pipelines/logicapps/your-file.csv`
3. **Commit and push** the CSV file
4. **Note the relative path** from repository root

### **Step 3: Run the Pipeline**

1. Open Azure DevOps → Pipelines → **Logic App Enhanced Start Automation**
2. Click **Run pipeline**
3. Select your **Deployment Mode**
4. Fill in the required parameters
5. Click **Run**

## 📝 Usage Examples

### **Example 1: CSV Mode - Bulk Deployment**

```
Deployment Mode: CSV
Environment: BAB_DEV
CSV File Path: Pipelines/logicapps/hr-system-deployments.csv
Logic App Resource Group: bab-core-auto-weeu-rg-01
Week Days: Sunday,Monday,Tuesday,Wednesday,Thursday
```

**Result:**
- Deploys all Logic Apps defined in the CSV file
- Each with its own schedule and VM list
- Detailed success/failure reporting

### **Example 2: Single Mode - Individual Deployment**

```
Deployment Mode: Single
Environment: BAB_DEV
Logic App Prefix: myapp_dev

Database Resource Group: myapp-db-rg
Database VM Names: dbvm01,dbvm02
DB Start Hour: 7
DB Start Minute: 0

App/Web Resource Group: myapp-web-rg
App/Web VM Names: appvm01,webvm01,webvm02
App/Web Start Hour: 8
App/Web Start Minute: 15
```

**Result:**
- Same as original pipeline
- Two Logic Apps deployed (DB and App/Web)

### **Example 3: CSV Mode - Mixed Schedules**

CSV content for different business units with varying schedules:

```csv
LogicAppType,LogicAppName,ResourceGroup,VmNames,StartHour,StartMinute,WeekDays
Database,hr_production_db,hr-prod-rg,hrdb01,hrdb02,5,30,"Monday,Tuesday,Wednesday,Thursday,Friday"
Application,hr_production_app,hr-prod-rg,hrapp01,hrapp02,6,0,"Monday,Tuesday,Wednesday,Thursday,Friday"
Database,finance_batch_db,fin-prod-rg,findb01,22,0,"Sunday"
Application,finance_batch_app,fin-prod-rg,finapp01,22,30,"Sunday"
Web,portal_weekend,portal-rg,portalweb01,8,0,"Saturday,Sunday"
```

## 🔍 Monitoring and Troubleshooting

### **Pipeline Logs**

The enhanced pipeline provides detailed logging:

- **CSV Validation**: Column validation and row count
- **Deployment Progress**: Step-by-step deployment status
- **Error Details**: Specific failure reasons for each Logic App
- **Summary Report**: Final success/failure counts

### **Common Issues and Solutions**

#### **CSV Mode Issues**

| Issue | Solution |
|-------|----------|
| "CSV file not found" | Verify the file path is relative to repository root |
| "Missing required CSV columns" | Ensure all required columns are present with correct names |
| "Failed to parse CSV" | Check for special characters, quotes, or encoding issues |
| "Some deployments failed" | Check individual error messages in pipeline logs |

#### **Single Mode Issues**

| Issue | Solution |
|-------|----------|
| "No valid VM names provided" | Remove spaces: `vm01,vm02` not `vm01, vm02` |
| "Logic App definition file not found" | Verify `logicapp_start.json` exists in repository |
| "Failed to set Azure context" | Check service principal credentials and permissions |

#### **General Issues**

| Issue | Solution |
|-------|----------|
| "Invalid weekday(s)" | Use full day names: `Monday,Tuesday` not `Mon,Tue` |
| "Azure CLI deployment failed" | Check Logic App resource group exists and permissions |
| "No valid weekdays provided" | Ensure at least one valid day is specified |

### **Viewing Deployment Results**

1. **Pipeline Summary**: Check the "Deployment Summary" step
2. **Individual Logs**: Expand each deployment step for details
3. **Azure Portal**: Verify Logic Apps in the target resource group
4. **Log Files**: Download pipeline logs for detailed analysis

## 📁 File Structure

```
Pipelines/
└── logicapps/
    ├── README_Enhanced.md                    # This file
    ├── logicapp_start_enhanced.yaml          # Enhanced pipeline
    ├── Deploy-LogicApp_start_enhanced.ps1    # Enhanced deployment script
    ├── vm-deployments.csv                    # Sample CSV file
    ├── logicapp_start.json                   # Logic App template
    │
    └── Original/                             # Original files (unchanged)
        ├── README.md                         # Original documentation
        ├── logicapp_start.yaml               # Original pipeline
        └── Deploy-LogicApp_start.ps1         # Original script
```

## 🔄 Migration from Original Pipeline

### **Backward Compatibility**

- ✅ **Single Mode** works identically to the original pipeline
- ✅ **Same parameters** and behavior for single deployments
- ✅ **Original files** remain unchanged and functional

### **Migration Steps**

1. **Test with Single Mode** first to ensure compatibility
2. **Create CSV files** for bulk deployments
3. **Run side-by-side** with original pipeline during transition
4. **Switch teams gradually** to the enhanced version

## 🔧 Advanced Configuration

### **Custom Definition Files**

You can use different Logic App definition templates:

1. Create custom JSON definition files
2. Reference them in the CSV `DefinitionFile` column
3. Ensure they follow the same structure as `logicapp_start.json`

### **Schedule Variations**

Each CSV row can have different schedules:

```csv
LogicAppName,ResourceGroup,VmNames,StartHour,StartMinute,WeekDays
early_birds,rg1,vm1,5,0,"Monday,Tuesday,Wednesday,Thursday,Friday"
normal_hours,rg2,vm2,8,0,"Monday,Tuesday,Wednesday,Thursday,Friday"
weekend_only,rg3,vm3,10,0,"Saturday,Sunday"
custom_schedule,rg4,vm4,6,30,"Monday,Wednesday,Friday"
```

### **Resource Group Management**

- Logic Apps are deployed to the specified `Logic App Resource Group`
- VMs can be in different resource groups per deployment
- Supports cross-subscription VM management (VMs in DEV/SIT, Logic Apps in CORE)

## 📊 Monitoring and Reporting

### **Success Metrics**

The pipeline tracks:
- Total deployments attempted
- Successful deployments
- Failed deployments
- Deployment duration
- Resource utilization

### **Error Reporting**

- Individual failure reasons
- Row-level error details
- Aggregated error summary
- Actionable error messages

## 🔐 Security Considerations

### **Follows BAB CloudOps Security Standards**

- ✅ **No hardcoded secrets** - Uses variable groups
- ✅ **Service Principal authentication** - Secure Azure access
- ✅ **Subscription isolation** - Clear separation of concerns
- ✅ **CSV sanitization** - Validate all inputs before processing
- ✅ **Audit logging** - Comprehensive deployment logging

### **CSV Security**

- **Review CSV files** before committing to repository
- **Avoid sensitive data** in CSV files
- **Use descriptive names** that don't reveal infrastructure details
- **Sanitize VM names** to follow naming conventions

## 📞 Support and Troubleshooting

### **Getting Help**

1. **Check logs** in the pipeline run details
2. **Review CSV structure** against the template
3. **Validate parameters** using the examples above
4. **Test with Single Mode** first if CSV mode fails

### **Common Success Patterns**

- **Start small**: Test with 1-2 CSV rows first
- **Validate locally**: Import CSV in PowerShell to check structure
- **Use consistent naming**: Follow organizational naming conventions
- **Group related VMs**: Keep VMs for the same application together

## 📈 Best Practices

### **CSV Management**

1. **Version control CSV files** - Track changes over time
2. **Use descriptive names** - `hr-prod-deployments.csv` not `file1.csv`
3. **Group by business unit** - Separate CSV files per team/application
4. **Document dependencies** - Note which VMs must start in order

### **Deployment Strategy**

1. **Test in DEV first** - Validate CSV structure and Logic Apps
2. **Deploy during maintenance windows** - Schedule for low-impact times
3. **Monitor first runs** - Verify Logic Apps trigger correctly
4. **Document schedules** - Maintain a schedule inventory

### **Maintenance**

1. **Regular CSV reviews** - Remove decommissioned VMs
2. **Update schedules seasonally** - Adjust for business requirements
3. **Monitor Logic App performance** - Check run history in Azure Portal
4. **Archive old deployments** - Clean up unused Logic Apps

---

## 🎯 Quick Start Checklist

### **For CSV Mode:**
- [ ] CSV file created with required columns
- [ ] CSV file uploaded to repository
- [ ] File path noted (relative to repo root)
- [ ] All VM names validated
- [ ] Schedule requirements confirmed

### **For Single Mode:**
- [ ] Logic App prefix defined
- [ ] VM resource groups identified
- [ ] VM names confirmed
- [ ] Start times planned
- [ ] Schedule days selected

### **For Both Modes:**
- [ ] Target environment selected (BAB_DEV/BAB_SIT)
- [ ] Logic App resource group confirmed
- [ ] Week days schedule defined
- [ ] Pipeline permissions verified

---

**🚀 Ready to deploy? Choose your mode and let's automate those VM startups!**

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 2.0 | 2024-11-06 | Enhanced version with CSV bulk deployment support |
| 1.0 | 2024-10-22 | Original single deployment pipeline |

---

**Note:** This enhanced pipeline maintains full backward compatibility with the original version while adding powerful bulk deployment capabilities through CSV files.