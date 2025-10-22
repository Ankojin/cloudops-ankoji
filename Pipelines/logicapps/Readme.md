# Azure Logic Apps - VM Start Automation

This pipeline automates the deployment of Azure Logic Apps that start Virtual Machines on a scheduled basis.

## Overview

This solution deploys Logic Apps that automatically start VMs based on a weekly schedule. You can deploy separate Logic Apps for:
- **Database VMs** - Typically started earlier in the day
- **Application/Web VMs** - Started after database VMs are running

## Prerequisites

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

## Pipeline Parameters

### Environment Selection
| Parameter | Description | Default | Required |
|-----------|-------------|---------|----------|
| **Environment** | Target environment for VMs | BAB_DEV | Yes |

Options: `BAB_DEV` or `BAB_SIT`

### Logic App Configuration
| Parameter | Description | Example | Required |
|-----------|-------------|---------|----------|
| **Logic App Prefix** | Naming prefix for Logic Apps | `BAB_RG_Env` | Yes |

This will create Logic Apps named:
- `{prefix}_vms_Scheduled_start_db`
- `{prefix}_vms_Scheduled_start_appweb`

### Database VM Configuration
| Parameter | Description | Example | Required |
|-----------|-------------|---------|----------|
| **Database Resource Group** | Resource group containing DB VMs | `myapp-db-rg` | Optional* |
| **Database VM Names** | Comma-separated list of DB VM names | `dbvm01,dbvm02,dbvm03` | Optional* |
| **DB Start Hour** | Hour to start DB VMs (0-23) | `7` | Optional* |
| **DB Start Minute** | Minute to start DB VMs (0-59) | `0` | Optional* |

*Set to `none` to skip DB Logic App deployment

### Application/Web VM Configuration
| Parameter | Description | Example | Required |
|-----------|-------------|---------|----------|
| **App/Web Resource Group** | Resource group containing App/Web VMs | `myapp-web-rg` | Optional* |
| **App/Web VM Names** | Comma-separated list of App/Web VM names | `appvm01,webvm01` | Optional* |
| **App/Web Start Hour** | Hour to start App/Web VMs (0-23) | `8` | Optional* |
| **App/Web Start Minute** | Minute to start App/Web VMs (0-59) | `0` | Optional* |

*Set to `none` to skip App/Web Logic App deployment

### Logic App Subscription
| Parameter | Description | Default | Required |
|-----------|-------------|---------|----------|
| **Logic App Subscription** | Subscription where Logic Apps are deployed | BAB_CORE | Yes |

## Usage Instructions

### Step 1: Navigate to the Pipeline
1. Open Azure DevOps
2. Go to **Pipelines** → **Pipelines**
3. Find and select the **Logic App Start Automation** pipeline

### Step 2: Run the Pipeline
1. Click **Run pipeline**
2. Fill in the required parameters (see examples below)
3. Click **Run**

### Step 3: Monitor Deployment
- The pipeline will show progress for each deployment step
- Check the **Deployment Summary** at the end for confirmation
- Logic Apps will be created in the `bab-core-auto-weeu-rg-01` resource group

## Usage Examples

### Example 1: Deploy Both DB and App/Web Logic Apps

```
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
- DB VMs start at 7:00 AM (Arab Standard Time)
- App/Web VMs start at 8:15 AM (Arab Standard Time)
- Logic Apps run Monday-Thursday

### Example 2: Deploy Only Database Logic App

```
Environment: BAB_DEV
Logic App Prefix: myapp_dev

Database Resource Group: myapp-db-rg
Database VM Names: dbvm01,dbvm02,dbvm03
DB Start Hour: 6
DB Start Minute: 30

App/Web Resource Group: none
App/Web VM Names: none
App/Web Start Hour: 8
App/Web Start Minute: 0
```

**Result:**
- Only DB Logic App is deployed
- DB VMs start at 6:30 AM (Arab Standard Time)
- App/Web Logic App is skipped

### Example 3: Deploy Only App/Web Logic App

```
Environment: BAB_SIT
Logic App Prefix: myapp_sit

Database Resource Group: none
Database VM Names: none
DB Start Hour: 7
DB Start Minute: 0

App/Web Resource Group: myapp-sit-web-rg
App/Web VM Names: sitwebvm01,sitwebvm02
App/Web Start Hour: 9
App/Web Start Minute: 0
```

**Result:**
- Only App/Web Logic App is deployed
- App/Web VMs start at 9:00 AM (Arab Standard Time)
- DB Logic App is skipped

## Schedule Configuration

### Default Schedule
- **Frequency:** Weekly
- **Days:** Sunday, Monday, Tuesday, Wednesday, Thursday
- **Time Zone:** Arab Standard Time

### Customizing Schedule
To modify the schedule (e.g., add Friday or Saturday), edit the `logicapp_start.json` file:

```json
"weekDays": ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday"]
```

## Troubleshooting

### Common Issues

#### Issue: "No valid VM names provided"
**Solution:** Ensure VM names are comma-separated with no spaces:
- ✅ Correct: `vm01,vm02,vm03`
- ❌ Incorrect: `vm01, vm02, vm03` (spaces after commas)

#### Issue: "Failed to set Azure context"
**Solution:** Verify that:
1. Service Principal credentials are valid
2. Service Principal has appropriate permissions
3. Subscription IDs in variable group are correct

#### Issue: "Logic App definition file not found"
**Solution:** Ensure `logicapp_start.json` exists in the repository at:
```
Pipelines/logicapps/logicapp_start.json
```

#### Issue: Logic App deployed but VMs not starting
**Solution:** Verify:
1. Azure Function endpoint in `logicapp_start.json` is correct
2. Logic App has permissions to start VMs in target subscription
3. VM names and resource group names are correct
4. VMs exist in the specified resource group

### Viewing Deployment Logs
1. Open the pipeline run
2. Click on each deployment step to see detailed logs
3. Look for VM Resource IDs to verify correct VMs are targeted

## File Structure

```
Pipelines/
└── logicapps/
    ├── README.md                      # This file
    ├── logicapp_start.yaml            # Pipeline definition
    ├── Deploy-LogicApp_start.ps1      # Deployment script
    └── logicapp_start.json            # Logic App template
```

## Azure Resources Created

After successful deployment, the following resources are created in Azure:

| Resource Type | Name Pattern | Resource Group |
|---------------|--------------|----------------|
| Logic App (DB) | `{prefix}_vms_Scheduled_start_db` | `bab-core-auto-weeu-rg-01` |
| Logic App (App/Web) | `{prefix}_vms_Scheduled_start_appweb` | `bab-core-auto-weeu-rg-01` |

## Viewing Logic Apps in Azure Portal

1. Go to [Azure Portal](https://portal.azure.com)
2. Navigate to **Resource Groups** → `bab-core-auto-weeu-rg-01`
3. Find your Logic Apps (filter by prefix)
4. Click on a Logic App to view:
   - Run history
   - Trigger schedule
   - Logic App designer

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review pipeline logs in Azure DevOps
3. Contact your Azure administrator or DevOps team

## Related Documentation

- [Azure Logic Apps Documentation](https://docs.microsoft.com/en-us/azure/logic-apps/)
- [Azure DevOps Pipelines Documentation](https://docs.microsoft.com/en-us/azure/devops/pipelines/)
- [Azure VM Start/Stop Solution](https://docs.microsoft.com/en-us/azure/automation/automation-solution-vm-management)

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-10-22 | Initial release - Start Logic Apps only |

---

**Note:** This pipeline deploys **start** Logic Apps only. For VM stop automation, use the corresponding stop pipeline.