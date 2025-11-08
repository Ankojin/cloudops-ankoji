# Azure DevOps Variable Groups Setup Guide

## Quick Setup Steps

### 1. Create Variable Groups in Azure DevOps

Navigate to **Pipelines → Library → Variable groups** in your Azure DevOps project and create these groups:

#### **TerraformVariables** (Global)
```
TF_STATE_PATH = C:/TerraformState/Project/$(project)/$(environment)
pythonVersion = 3.9
terraformVersion = 1.11.4
```

#### **VM-Creation-SIT** (SIT Environment)
```
subscription_id = 12345678-1234-1234-1234-123456789012
location = swedencentral
vnet_name = vnet-baas-sit-001
vnet_rg = rg-networking-sit
subnet_rg = rg-networking-sit
subnets_config = {"app": ["snet-sit-nonpci-app-01", "snet-sit-nonpci-app-02", "snet-sit-nonpci-app-03"], "db": ["snet-sit-nonpci-db-01", "snet-sit-nonpci-db-02"], "web": ["snet-sit-nonpci-web-01", "snet-sit-nonpci-web-02"]}
keyvault_name = kv-baas-sit-001
keyvault_rg = rg-security-sit
dcr_name = dcr-baas-sit-001
dcr_rg = rg-monitoring-sit
diagnostics_storage = stdiagnosticssit001
diagnostics_storage_rg = rg-diagnostics-sit
script_storage_account = babcloudopsscripts
script_storage_container = vm-scripts
script_blob_name_linux = linux-postconf-script-secure.sh
script_blob_name_windows = windows-postconf-script-secure.ps1
shutdown_enabled = true
shutdown_time = 2000
shutdown_timezone = Arab Standard Time
default_tags = 
```

#### **VM-Creation-DEV** (DEV Environment)
```
subscription_id = your-dev-subscription-id
location = swedencentral
vnet_name = vnet-baas-dev-001
vnet_rg = rg-networking-dev
subnet_rg = rg-networking-dev
subnets_config = {"app": ["snet-dev-nonpci-app-01", "snet-dev-nonpci-app-02"], "db": ["snet-dev-nonpci-db-01"], "web": ["snet-dev-nonpci-web-01"]}
keyvault_name = kv-baas-dev-001
keyvault_rg = rg-security-dev
dcr_name = dcr-baas-dev-001
dcr_rg = rg-monitoring-dev
diagnostics_storage = stdiagnosticsdev001
diagnostics_storage_rg = rg-monitoring-dev
script_storage_account = babcloudopsscripts
script_storage_container = vm-scripts
script_blob_name_linux = linux-postconf-script-secure.sh
script_blob_name_windows = windows-postconf-script-secure.ps1
shutdown_enabled = true
shutdown_time = 2000
shutdown_timezone = Arab Standard Time
default_tags = 
```

### 2. Security Configuration

#### Service Connection Setup:
1. Go to **Project Settings → Service connections**
2. Create **Azure Resource Manager** connection
3. Select **Service principal (automatic)** or **Service principal (manual)**
4. Name it: `azure-service-connection`
5. Grant permissions to target subscription

#### Required Azure RBAC Permissions:
The service principal needs these roles:
- **Contributor** (on subscription or resource groups)
- **Key Vault Secrets User** (on Key Vault)
- **Monitoring Reader** (for Data Collection Rules)

### 3. Agent Configuration

#### CloudOps Agent Requirements:
The `cloudops-agent` must have:
- ✅ Python 3.9+ installed
- ✅ Terraform 1.11.4+ installed
- ✅ Azure CLI installed and configured
- ✅ Access to `C:/TerraformState/` directory
- ✅ Network access to Azure resources

#### Agent Setup Commands:
```powershell
# Create Terraform state directory
New-Item -Path "C:\TerraformState\Project" -ItemType Directory -Force

# Test agent access
terraform version
python --version
az version
```

### 4. Pipeline Permissions

#### Required Pipeline Permissions:
1. **Pipeline permissions** on variable groups
2. **Use** permission on service connection
3. **Queue builds** permission for users

#### Variable Group Security:
- Mark `subscription_id` as **secret variable**
- Limit access to **specific teams** only
- Enable **Settable at queue time** for testing variables

## Quick Validation

Run this command to validate your setup:
```bash
cd Pipelines/VM-Creation
python scripts/validate-azdo-config.py
```

## Ready for Deployment!

Once all variable groups are created and the validation passes, you can:

1. **Queue the pipeline** in Azure DevOps
2. **Select environment** (DEV or SIT)
3. **Provide mandatory tags** via GUI
4. **Monitor execution** and review Terraform plan
5. **Approve deployment** if plan looks correct

## Troubleshooting

### Common Issues:
- **Missing variable groups**: Create them with exact names shown above
- **JSON format errors**: Validate `subnets_config` JSON format
- **Permission denied**: Check service principal RBAC assignments
- **State file conflicts**: Ensure agent has write access to state directory
- **Resource not found**: Verify Azure resources exist before deployment