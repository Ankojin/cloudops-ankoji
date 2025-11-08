# Azure DevOps Variable Groups - Copy/Migration Methods

## ❌ **No Direct Copy Command**

Azure DevOps CLI doesn't provide a built-in command to copy entire variable groups. However, there are several effective approaches:

## 🔧 **Method 1: Azure DevOps CLI Export/Import (Recommended)**

### **Step 1: Export Existing Variable Group**
```bash
# Export variable group to JSON
az pipelines variable-group show --group-id <GROUP_ID> --project <PROJECT_NAME> --output json > variable-group-export.json

# Or export by name
az pipelines variable-group list --project <PROJECT_NAME> --query "[?name=='VM-Creation-DEV']" --output json > dev-variables.json
```

### **Step 2: Create New Variable Group from Export**
```bash
# Create new variable group from exported JSON (requires manual editing)
az pipelines variable-group create --name "VM-Creation-SIT" --variables @variables.json --project <PROJECT_NAME>
```

## 🔧 **Method 2: PowerShell Script Automation**

### **Create Variable Group Copy Script:**
```powershell
# Variable Group Copy Script
param(
    [string]$SourceGroupName = "VM-Creation-DEV",
    [string]$TargetGroupName = "VM-Creation-SIT", 
    [string]$ProjectName = "YourProject",
    [string]$Organization = "https://dev.azure.com/YourOrg"
)

# Get source variable group
$sourceGroup = az pipelines variable-group list --project $ProjectName --query "[?name=='$SourceGroupName']" | ConvertFrom-Json

if ($sourceGroup) {
    $variables = $sourceGroup[0].variables
    
    # Convert variables to creation format
    $variableArgs = @()
    foreach ($var in $variables.PSObject.Properties) {
        $name = $var.Name
        $value = $var.Value.value
        $isSecret = $var.Value.isSecret
        
        if ($isSecret) {
            $variableArgs += "$name=REPLACE_WITH_ACTUAL_SECRET"
        } else {
            $variableArgs += "$name=$value"
        }
    }
    
    # Create new variable group
    az pipelines variable-group create --name $TargetGroupName --variables $variableArgs --project $ProjectName
}
```

## 🔧 **Method 3: REST API Approach (Advanced)**

### **PowerShell with REST API:**
```powershell
# REST API Variable Group Copy
$pat = "YOUR_PERSONAL_ACCESS_TOKEN"
$org = "YourOrganization"
$project = "YourProject"
$headers = @{
    Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
    'Content-Type' = 'application/json'
}

# Get source variable group
$sourceGroupId = 123  # Replace with actual group ID
$getUri = "https://dev.azure.com/$org/$project/_apis/distributedtask/variablegroups/$sourceGroupId"
$sourceGroup = Invoke-RestMethod -Uri $getUri -Headers $headers -Method GET

# Modify for new group
$newGroup = $sourceGroup.PSObject.Copy()
$newGroup.name = "VM-Creation-SIT"
$newGroup.id = $null  # Remove ID to create new group

# Create new variable group
$createUri = "https://dev.azure.com/$org/$project/_apis/distributedtask/variablegroups"
$newGroupJson = $newGroup | ConvertTo-Json -Depth 10
Invoke-RestMethod -Uri $createUri -Headers $headers -Method POST -Body $newGroupJson
```

## 🔧 **Method 4: Manual with Copy-Paste Helper (Fastest)**

### **Use Our Prepared Values:**
Since you already have the complete variable configuration in `documentation/Copy-Paste-Variable-Values.md`, the fastest approach is:

1. **Create new variable group** in Azure DevOps UI
2. **Copy-paste values** from the documentation
3. **Modify environment-specific** values (DEV → SIT)

### **Quick Steps:**
```yaml
# 1. Open Azure DevOps → Pipelines → Library
# 2. Click "Variable group" → Create new
# 3. Name: "VM-Creation-SIT"  
# 4. Copy all variables from Copy-Paste-Variable-Values.md
# 5. Replace DEV-specific values with SIT values:
#    - Change resource names: -dev- → -sit-
#    - Update subscription_id (mark as secret)
#    - Modify cost center: IT-INFRA-001 → IT-INFRA-002
#    - Update service class: Development → Testing
#    - Change managed by: CloudOps Team → QA Team
```

## 📋 **Batch Variable Creation Script**

### **Create Multiple Variables at Once:**
```bash
# Create variable group with all variables in one command
az pipelines variable-group create \
  --name "VM-Creation-SIT" \
  --variables \
    location=swedencentral \
    vnet_name=vnet-baas-sit-001 \
    vnet_rg=rg-networking-sit \
    subnet_rg=rg-networking-sit \
    keyvault_name=kv-baas-sit-001 \
    keyvault_rg=rg-security-sit \
    dcr_name=dcr-baas-sit-001 \
    dcr_rg=rg-monitoring-sit \
    diagnostics_storage=stdiagnosticssit001 \
    diagnostics_storage_rg=rg-diagnostics-sit \
    script_storage_account=stscriptssit001 \
    script_storage_container=scripts \
    script_blob_name_linux=linuxpostconf.sh \
    script_blob_name_windows=windows-postconf-script-secure.ps1 \
  --project YourProject
```

## 🎯 **Recommended Approach for Your Setup**

Given that you have complete variable configurations documented:

### **Option A: Manual (Fastest - 10 minutes)**
1. Use Azure DevOps UI
2. Copy-paste from `Copy-Paste-Variable-Values.md`
3. Modify DEV → SIT values

### **Option B: CLI Script (Automated - 15 minutes setup)**
```bash
# Create both variable groups using prepared values
./create-variable-groups.sh
```

## 📝 **Variable Group Comparison Tool**

### **Verify Variable Groups Match:**
```bash
# Compare two variable groups
az pipelines variable-group show --group-id <DEV_GROUP_ID> --output table
az pipelines variable-group show --group-id <SIT_GROUP_ID> --output table
```

## 🔐 **Important Notes**

### **⚠️ Secret Variables:**
- **Cannot be exported** via CLI (security feature)
- **Must be manually set** in new variable groups  
- **Mark as secret** during creation:
  - `subscription_id`
  - `ARM_CLIENT_SECRET` (in TerraformVariables group)

### **✅ Best Practice:**
1. **Export non-secret** variables via CLI
2. **Manually handle** secret variables
3. **Document** the process for future use
4. **Test** variable groups after creation

## 🚀 **Quick Start Command**

For your specific setup, the fastest approach:

```bash
# 1. Export DEV group structure
az pipelines variable-group list --project YourProject --query "[?name=='VM-Creation-DEV']" --output json > dev-template.json

# 2. Use the Copy-Paste-Variable-Values.md for manual creation
# 3. Create SIT group manually with documented values
```

**Recommendation: Use the manual approach with your documented values for fastest and most reliable setup!** 🎯