# Azure DevOps Variable Groups Configuration Guide

## Required Variable Groups

The VM Creation pipeline requires the following variable groups to be configured in Azure DevOps:

### 1. **TerraformVariables** (Global/Shared)
```yaml
# Terraform State Configuration
TF_STATE_PATH: "C:/TerraformState/Project/$(project)/$(environment)"

# Python and Terraform Versions
pythonVersion: "3.9"
terraformVersion: "1.11.4"
```

### 2. **VM-Creation-DEV** (Development Environment)
```yaml
# Azure Subscription & Location
subscription_id: "your-dev-subscription-id"
location: "swedencentral"

# Networking Configuration
vnet_name: "vnet-baas-dev-001"
vnet_rg: "rg-networking-dev"
subnet_rg: "rg-networking-dev"
subnets_config: '{"app": ["snet-dev-nonpci-app-01", "snet-dev-nonpci-app-02"], "db": ["snet-dev-nonpci-db-01"], "web": ["snet-dev-nonpci-web-01"]}'

# Key Vault Configuration
keyvault_name: "kv-baas-dev-001"
keyvault_rg: "rg-security-dev"

# Monitoring Configuration
dcr_name: "dcr-baas-dev-001"
dcr_rg: "rg-monitoring-dev"
diagnostics_storage: "stdiagnosticsdev001"
diagnostics_storage_rg: "rg-monitoring-dev"

# Script Storage Configuration
script_storage_account: "babcloudopsscripts"
script_storage_container: "vm-scripts"
script_blob_name_linux: "linux-postconf-script-secure.sh"
script_blob_name_windows: "windows-postconf-script-secure.ps1"

# Auto Shutdown Configuration
shutdown_enabled: "true"
shutdown_time: "2000"
shutdown_timezone: "Arab Standard Time"

# Legacy Tags (DEPRECATED - Use GUI input instead)
default_tags: ""
```

### 3. **VM-Creation-SIT** (System Integration Test Environment)
```yaml
# Azure Subscription & Location
subscription_id: "12345678-1234-1234-1234-123456789012"
location: "swedencentral"

# Networking Configuration
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
diagnostics_storage_rg: "rg-monitoring-sit"

# Script Storage Configuration
script_storage_account: "babcloudopsscripts"
script_storage_container: "vm-scripts"
script_blob_name_linux: "linux-postconf-script-secure.sh"
script_blob_name_windows: "windows-postconf-script-secure.ps1"

# Auto Shutdown Configuration
shutdown_enabled: "true"
shutdown_time: "2000"
shutdown_timezone: "Arab Standard Time"

# Legacy Tags (DEPRECATED - Use GUI input instead)
default_tags: ""
```

## Service Principal Configuration

### Required Permissions for Pipeline Service Principal:
1. **Subscription Level**:
   - Contributor role (for resource deployment)
   - Key Vault Secrets User role (for accessing VM passwords)

2. **Specific Resource Access**:
   - Read access to VNet and Subnets
   - Read access to Key Vault secrets
   - Read access to Data Collection Rules
   - Write access to Storage Account (for diagnostics)

### Service Connection Configuration:
```yaml
# In Azure DevOps Project Settings > Service Connections
Service Connection Name: "azure-service-connection"
Subscription: [Target subscription]
Service Principal: [Dedicated SP for VM creation]
```

## Pipeline Parameters (GUI Input)

### Required User Input:
1. **action**: apply | modify
2. **environment**: DEV | SIT
3. **project**: BaaS-Platform (default)
4. **tags_json_override**: JSON with 14 mandatory tags

### Mandatory Tags JSON Format:
```json
{
  "Company": "BAB",
  "Department": "Information Technology",
  "ProjectName": "your-project",
  "ApplicationName": "your-app",
  "StartDate": "2025-11-08",
  "EndDate": "2025-11-08",
  "Region": "Sweden Central",
  "ApproverName": "approver-name",
  "RequesterName": "CloudOps Team",
  "BusinessOwner": "business-owner",
  "TechnicalOwner": "technical-owner",
  "CostCenter": "cost-center",
  "ServiceClass": "service-class",
  "ManagedBy": "CloudOps Team"
}
```

## Security Best Practices

### Variable Group Security:
1. Mark sensitive variables as secrets in Azure DevOps
2. Limit variable group access to specific teams
3. Use Azure Key Vault variable groups for sensitive data

### Sensitive Variables to Secure:
- `subscription_id` 
- Any storage account keys or connection strings
- Service principal credentials (if using)

## Validation Steps

### Pre-Deployment Checklist:
1. ✅ Variable groups created and populated
2. ✅ Service principal has required permissions
3. ✅ Azure resources (VNet, Key Vault, DCR) exist
4. ✅ Agent has access to Terraform state directory
5. ✅ CSV file is properly formatted
6. ✅ Cloud-init YAML file exists

### Post-Deployment Validation:
1. Terraform state file created/updated
2. VM resources deployed successfully
3. Monitoring agent installed
4. Auto-shutdown configured
5. Tags applied correctly