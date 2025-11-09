# VM Creation Pipeline

This pipeline automates Azure VM deployment using CSV files and Terraform. You can create new VMs or modify existing ones.

## Getting Started

1. Edit the CSV file at `core/simplified-vms.csv` with your VM requirements
2. Go to Azure DevOps Pipelines and run "Terraform-Apply-Modify-Working"
3. Set the pipeline parameters (action, environment, project, tags)

## CSV Configuration

Define your VMs in `core/simplified-vms.csv`. Here's the format:

```csv
vm_name,resource_group,vm_role,subnet_name,static_ip,vm_size,os_template,disk_1_size,disk_2_size,disk_3_size,create_rg
web-01,my-rg,web_server,snet-sit-nonpci-web-01,10.189.59.100,Standard_B2s,ubuntu-22.04,32,100,,TRUE
app-01,my-rg,app_server,snet-sit-nonpci-app-02,10.189.57.100,Standard_B4ms,windows-2019,64,500,,TRUE
db-01,my-rg,database,snet-sit-nonpci-db-02,10.189.58.100,Standard_D4s_v5,windows-2022,128,1000,2000,TRUE
```

## OS Templates

Pick from these pre-configured templates:

**Windows:** windows-2016, windows-2019, windows-2022  
**Ubuntu:** ubuntu-18.04, ubuntu-20.04, ubuntu-22.04  
**Red Hat:** rhel-7, rhel-8, rhel-9  
**Others:** centos-7, sles-15

## Pipeline Options

When running the pipeline:

- **Action:** `apply` for new VMs, `modify` for changes to existing VMs
- **Environment:** DEV or SIT  
- **Project Name:** Used to organize Terraform state files
- **Tags:** Required business metadata in JSON format

Example tags:
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

## Variable Groups Setup

You need these variable groups configured in Azure DevOps:

**TerraformVariables** - Contains Azure service principal credentials

**VM-Creation-DEV** and **VM-Creation-SIT** - Environment-specific settings:
```
subscription_id = your-subscription-guid
location = swedencentral
vnet_name = your-vnet-name  
vnet_rg = vnet-resource-group
subnet_rg = subnet-resource-group
keyvault_name = your-key-vault
keyvault_rg = keyvault-resource-group
dcr_name = data-collection-rule-name
dcr_rg = dcr-resource-group
diagnostics_storage = storage-account-name
diagnostics_storage_rg = storage-resource-group
script_storage_account = script-storage-name
script_storage_container = container-name
script_blob_name_linux = linux-setup-script.sh
script_blob_name_windows = windows-setup-script.ps1
shutdown_enabled = true
shutdown_time = 2000
shutdown_timezone = Arab Standard Time
```

## How to Use

**Creating new VMs:**
1. Add new rows to the CSV file
2. Run pipeline with action: apply
3. Make sure all 14 business tags are filled in

**Modifying existing VMs:**
1. Update the CSV rows you want to change
2. Run pipeline with action: modify  
3. Tags are optional for modify operations

**Changing VM size:**
1. Update the vm_size column in CSV
2. Use action: modify
3. The VM will restart during the resize

**Adding more disks:**
1. Fill in disk_2_size and/or disk_3_size columns
2. Use action: modify
3. New disks get attached automatically

## Behind the Scenes

**For new deployments (apply):**
1. Python script reads the CSV and converts OS templates to Azure marketplace images
2. Terraform configuration gets generated
3. Azure resources are created
4. State files are saved to `C:/TerraformState/Project/{project}/{env}/`

**For updates (modify):**
1. Existing state and configuration files are loaded
2. Only the changes you specified get applied
3. Everything else stays untouched
4. State files get updated

## Technical Specs

**Storage defaults:**
- OS disks use StandardSSD_LRS with ReadWrite caching
- Data disks use StandardSSD_LRS with no caching

**Built-in features:**
- Admin passwords come from Azure Key Vault
- All VMs get monitoring agents installed
- Auto-shutdown at 8 PM (configurable)
- Boot diagnostics enabled
- Custom setup scripts run post-deployment

## Troubleshooting

**CSV problems:**
- Double-check column names are spelled correctly
- Make sure no required fields are blank
- VM names must be unique

**State file issues:**
- Always run apply before modify
- Keep project names consistent between runs
- Check that state files exist in the expected location

**Network problems:**
- Verify subnet names exist in Azure
- Make sure IP addresses are available in the subnet range
- Check that NSG rules allow the traffic you need

**Tag validation errors:**
- All 14 tags are required when using apply action
- Tags must be valid JSON format
- No empty tag values allowed

## Directory Layout

```
VM-Creation/
├── pipelines/
│   └── Terraform-Apply-Modify-Working.yml    # Main pipeline
├── core/
│   ├── simplified-vms.csv                    # Your VM definitions
│   ├── generate-tf-v2-enhanced.py           # Terraform generator
│   └── Deployment-Cloud-init.yaml           # Linux startup config
└── Project/
    └── {project}/
        └── main-{env}.tf                     # Generated & saved permanently
```

## File Management

**CSV files:** You edit these manually in the repo  
**Terraform files:** Generated fresh each run, then saved permanently on build agents  
**State files:** Stored permanently at `C:/TerraformState/Project/{project}/{env}/`

The pipeline generates new Terraform configurations based on your CSV changes, but keeps the previous versions for state consistency during modify operations.

## Security Notes

- Don't put passwords or secrets in CSV files
- All credentials come from Azure Key Vault
- State files are stored securely on build agents
- Review pipeline logs before sharing with others