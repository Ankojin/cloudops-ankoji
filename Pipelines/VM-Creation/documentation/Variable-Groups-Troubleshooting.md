# Variable Groups Troubleshooting Guide

## Common Error: "script_storage_account is not recognized"

### Root Cause:
The pipeline is trying to access variables from Azure DevOps Variable Groups that haven't been created yet.

### Required Variable Groups:

#### 1. **TerraformVariables** (Global)
Create this variable group with these variables:
```
TF_STATE_PATH = C:/TerraformState/Project/$(project)/$(environment)
```

#### 2. **VM-Creation-SIT** (For SIT Environment)
Create this variable group with these variables:
```yaml
# Core Azure Configuration
subscription_id: "12345678-1234-1234-1234-123456789012"
location: "swedencentral"

# Network Configuration
vnet_name: "vnet-baas-sit-001"
vnet_rg: "rg-networking-sit"
subnet_rg: "rg-networking-sit"
subnets_config: '{"app": ["snet-sit-nonpci-app-01", "snet-sit-nonpci-app-02", "snet-sit-nonpci-app-03"], "db": ["snet-sit-nonpci-db-01", "snet-sit-nonpci-db-02"], "web": ["snet-sit-nonpci-web-01", "snet-sit-nonpci-web-02"]}'

# Key Vault Configuration
keyvault_name: "kv-baas-sit-001"
keyvault_rg: "rg-security-sit"

# Monitoring Configuration
dcr_name: "dcr-baas-sit-001"
dcr_rg: "rg-monitoring-sit"
diagnostics_storage: "stdiagnosticssit001"
diagnostics_storage_rg: "rg-diagnostics-sit"

# Script Storage Configuration
script_storage_account: "babcloudopsscripts"
script_storage_container: "vm-scripts"
script_blob_name_linux: "linux-postconf-script-secure.sh"
script_blob_name_windows: "windows-postconf-script-secure.ps1"

# Auto Shutdown Configuration
shutdown_enabled: "true"
shutdown_time: "2000"
shutdown_timezone: "Arab Standard Time"

# Legacy Tags (Keep empty - use GUI input)
default_tags: ""
```

#### 3. **VM-Creation-DEV** (For DEV Environment)
Same structure as SIT but with DEV-specific values.

## Step-by-Step Setup in Azure DevOps

### 1. Navigate to Variable Groups
1. Open your Azure DevOps project
2. Go to **Pipelines** → **Library**
3. Click **+ Variable group**

### 2. Create TerraformVariables Group
1. **Variable group name**: `TerraformVariables`
2. **Description**: `Global Terraform configuration variables`
3. Add variable:
   - **Name**: `TF_STATE_PATH`
   - **Value**: `C:/TerraformState/Project/$(project)/$(environment)`
4. Click **Save**

### 3. Create VM-Creation-SIT Group
1. **Variable group name**: `VM-Creation-SIT`
2. **Description**: `SIT environment variables for VM creation`
3. Add all variables listed above
4. **Important**: Mark `subscription_id` as **secret** (lock icon)
5. Click **Save**

### 4. Grant Pipeline Permissions
1. In each variable group, go to **Security**
2. Add your pipeline or project build service
3. Grant **User** permissions

## Validation Script

Run this to verify your setup:
```bash
# From the VM-Creation directory
python scripts/validate-azdo-config.py
```

## Quick Fix for Testing

If you want to test immediately without setting up full variable groups, you can temporarily use environment variables:

```powershell
# Set these environment variables on your agent for testing
$env:subscription_id = "your-subscription-id"
$env:vnet_name = "your-vnet-name"
$env:script_storage_account = "babcloudopsscripts"
# ... etc for all required variables
```

## Error Resolution Steps

### If you see "X is not recognized":
1. ✅ Check variable group name matches exactly: `VM-Creation-SIT` or `VM-Creation-DEV`
2. ✅ Check variable name matches exactly (case sensitive)
3. ✅ Verify pipeline has permissions to access variable group
4. ✅ Confirm variable group is linked in pipeline YAML

### If you see JSON parsing errors:
1. ✅ Validate `subnets_config` is valid JSON
2. ✅ Use single quotes around JSON in variable group
3. ✅ Escape any quotes inside the JSON properly

### If authentication fails:
1. ✅ Verify service connection is working
2. ✅ Check service principal has required permissions
3. ✅ Ensure subscription_id is correct

## Production Checklist

Before using in production:
- [ ] All variable groups created and populated
- [ ] Service principal permissions verified
- [ ] Agent has required tools (Python, Terraform, Azure CLI)
- [ ] State directory exists and is writable: `C:\TerraformState\`
- [ ] Network access to Azure resources confirmed
- [ ] CSV file contains valid VM specifications
- [ ] Cloud-init file exists and is properly formatted