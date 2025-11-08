# VM Creation Pipeline Documentation

This pipeline creates Azure Virtual Machines using CSV configuration and Terraform. Supports new VM creation and modifications to existing VMs.

## Quick Setup

1. **Update CSV file**: Edit `core/simplified-vms.csv` with your VM specifications
2. **Run pipeline**: Azure DevOps → Pipelines → "Terraform-Apply-Modify-Working"
3. **Configure parameters**: Set action, environment, project name, and business tags

## CSV Format

Your VMs are defined in `core/simplified-vms.csv`:

```csv
vm_name,resource_group,vm_role,subnet_name,static_ip,vm_size,os_template,disk_1_size,disk_2_size,disk_3_size,create_rg
web-01,my-rg,web_server,snet-sit-nonpci-web-01,10.189.59.100,Standard_B2s,ubuntu-22.04,32,100,,TRUE
app-01,my-rg,app_server,snet-sit-nonpci-app-02,10.189.57.100,Standard_B4ms,windows-2019,64,500,,TRUE
db-01,my-rg,database,snet-sit-nonpci-db-02,10.189.58.100,Standard_D4s_v5,windows-2022,128,1000,2000,TRUE
```

## Available OS Templates

**Windows:**
- `windows-2016`, `windows-2019`, `windows-2022`

**Ubuntu:**
- `ubuntu-18.04`, `ubuntu-20.04`, `ubuntu-22.04`

**Red Hat:**
- `rhel-7`, `rhel-8`, `rhel-9`

**Others:**
- `centos-7`, `sles-15`

## Pipeline Parameters

**Action:**
- `apply` - Create new VMs
- `modify` - Update existing VMs

**Environment:**
- `DEV` - Development
- `SIT` - System Integration Test

**Project Name:**
- Used for organizing state files

**Tags (JSON):**
```json
{
  "Company": "BAB",
  "Department": "Information Technology",
  "ProjectName": "your-project",
  "ApplicationName": "your-app", 
  "StartDate": "2025-11-08",
  "EndDate": "2025-12-31",
  "Region": "Sweden Central",
  "ApproverName": "manager-name",
  "RequesterName": "your-name",
  "BusinessOwner": "business-owner",
  "TechnicalOwner": "technical-owner",
  "CostCenter": "cost-center",
  "ServiceClass": "production",
  "ManagedBy": "CloudOps Team"
}
```

## Variable Groups Required

**TerraformVariables:**
- Azure authentication credentials

**VM-Creation-DEV / VM-Creation-SIT:**
```
subscription_id = <subscription-id>
location = swedencentral
vnet_name = <vnet-name>
vnet_rg = <vnet-resource-group>
subnet_rg = <subnet-resource-group>
keyvault_name = <keyvault-name>
keyvault_rg = <keyvault-resource-group>
dcr_name = <data-collection-rule>
dcr_rg = <dcr-resource-group>
diagnostics_storage = <storage-account>
diagnostics_storage_rg = <storage-resource-group>
script_storage_account = <script-storage>
script_storage_container = <container-name>
script_blob_name_linux = <linux-script>
script_blob_name_windows = <windows-script>
shutdown_enabled = true
shutdown_time = 2000
shutdown_timezone = Arab Standard Time
```

## Common Operations

**Create new VMs:**
1. Add rows to CSV file
2. Run pipeline with `action: apply`
3. All 14 business tags required

**Modify existing VMs:**
1. Update CSV rows  
2. Run pipeline with `action: modify`
3. Tags optional

**Change VM size:**
1. Update `vm_size` in CSV
2. Use `action: modify`
3. VM will restart during resize

**Add data disks:**
1. Set `disk_2_size` and/or `disk_3_size`
2. Use `action: modify`
3. Disks attached automatically

## How It Works

**Apply (New VMs):**
1. Python reads CSV and resolves OS templates
2. Generates Terraform configuration
3. Creates Azure resources
4. Saves state to `C:/TerraformState/Project/{project}/{env}/`

**Modify (Existing VMs):**
1. Loads existing state and configuration
2. Applies only specified changes
3. Preserves unchanged resources
4. Updates state files

## Technical Details

**Storage:**
- OS disks: StandardSSD_LRS with ReadWrite caching
- Data disks: StandardSSD_LRS with None caching

**Security:**
- SSH keys from Azure Key Vault (Linux)
- Azure AD authentication (Windows)
- NSG rules applied automatically
- Diagnostic monitoring enabled

**Auto Features:**
- VM auto-shutdown at 8 PM
- Monitoring agent installation  
- Custom script execution
- Backup integration (if configured)

## Troubleshooting

**CSV Issues:**
- Check column names match exactly
- Verify no empty required fields
- Ensure unique VM names

**State Problems:**
- Run `apply` before `modify`
- Verify project name consistency
- Check state files exist

**Network Issues:**
- Confirm subnet names exist
- Verify IP addresses available
- Check NSG rules

**Tag Errors:**
- All 14 tags required for `apply`
- Valid JSON format needed
- No empty values allowed

## File Structure

```
VM-Creation/
├── pipelines/
│   └── Terraform-Apply-Modify-Working.yml
├── core/
│   ├── simplified-vms.csv
│   ├── generate-tf-v2-enhanced.py
│   └── Deployment-Cloud-init.yaml
└── Project/
    └── {project}/
        └── main-{env}.tf
```

## Security Notes

- Never put secrets in CSV files
- All credentials from Azure Key Vault
- State files stored securely on agents
- Review pipeline logs before sharing