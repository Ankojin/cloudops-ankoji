# Updated Variable Groups Configuration

## Variable Group 1: `VM-Creation-DEV`
```yaml
# Subscription & Location
subscription_id: "43cc4f11-ffb1-4a0d-8420-0ba3746b4248"
location: "swedencentral"
environment: "DEV"

# Network Configuration (JSON format for multiple subnets)
vnet_name: "bab-dev-nw-swec-vnet-nonpci-01"
vnet_rg: "bab-dev-nw-swec-rg-01"
subnet_rg: "bab-dev-nw-swec-rg-01"

# Subnets JSON configuration
subnets_config: |
  {
    "app": [
      "snet-dev-nonpci-app-01",
      "snet-dev-nonpci-app-02", 
      "snet-dev-nonpci-app-03"
    ],
    "db": [
      "snet-dev-nonpci-db-02",
      "snet-dev-nonpci-db-03"
    ],
    "web": [
      "snet-dev-nonpci-web-01",
      "snet-dev-nonpci-web-02"
    ]
  }

# Key Vault Configuration
keyvault_name: "bab-dev-ssl-kv-swec-01"
keyvault_rg: "bab-dev-keyvault-swec-rg-01"
admin_password_secret: "azureadmin"

# Monitoring Configuration
dcr_name: "MSVMI-bab-dev-vm-monitoring-dcr"
dcr_rg: "bab-dev-wrkspace-swec-rg-01"

# Storage Configuration
diagnostics_storage: "babdevvmbootdiag02"
script_storage_container: "linux-disk-script"
script_blob_name: "adding-Disk-v2.sh"

# Auto Shutdown Configuration (still configurable per environment)
shutdown_enabled: "true"
shutdown_time: "2000"
shutdown_timezone: "Arab Standard Time"

# Default Tags for Environment
default_tags: |
  Environment=DEV
  Region=Sweden Central
  Approver name=Ahmed Jamil Alsaqa
  Requester name=Ibrahim Sharief Syed
  Business Owner=MailgroupDBI@Bankalbilad.com
  Technical owner=Ibrahim Sharief Syed
  Service class=low
  Managed by=Cloud Services
  Cost center=23BR006
  Company=BAB
  Department=Digital Banking & Innovation
```

## Variable Group 2: `VM-Creation-SIT`
```yaml
# Subscription & Location
subscription_id: "e48414cd-f96d-4414-ae9e-da7fec844f77"
location: "swedencentral" 
environment: "SIT"

# Network Configuration
vnet_name: "bab-sit-nw-swec-vnet-nonpci-01"
vnet_rg: "bab-sit-nw-swec-rg-01"
subnet_rg: "bab-sit-nw-swec-rg-01"

# Subnets JSON configuration
subnets_config: |
  {
    "app": [
      "snet-sit-nonpci-app-01",
      "snet-sit-nonpci-app-02",
      "snet-sit-nonpci-app-03"
    ],
    "db": [
      "snet-sit-nonpci-db-01", 
      "snet-sit-nonpci-db-02"
    ],
    "web": [
      "snet-sit-nonpci-web-01",
      "snet-sit-nonpci-web-02"
    ]
  }

# Key Vault Configuration
keyvault_name: "bab-sit-ssl-kv-swec-01"
keyvault_rg: "bab-sit-keyvault-swec-rg-01"
admin_password_secret: "azureadmin"

# Monitoring Configuration
dcr_name: "MSVMI-bab-sit-vm-monitoring-dcr"
dcr_rg: "bab-sit-wrkspace-swec-rg-01"

# Storage Configuration  
diagnostics_storage: "babsitvmbootdiag02"
script_storage_container: "linux-disk-script"
script_blob_name: "adding-Disk-v2.sh"

# Auto Shutdown Configuration
shutdown_enabled: "true"
shutdown_time: "2000" 
shutdown_timezone: "Arab Standard Time"

# Default Tags for Environment
default_tags: |
  Environment=SIT
  Region=Sweden Central
  Approver name=Ahmed Jamil Alsaqa
  Requester name=Ibrahim Sharief Syed
  Business Owner=MailgroupDBI@Bankalbilad.com
  Technical owner=Ibrahim Sharief Syed
  Service class=low
  Managed by=Cloud Services
  Cost center=23BR006
  Company=BAB
  Department=Digital Banking & Innovation
```

## Variable Group 3: `VM-Creation-Common` (REMOVED)
This variable group is no longer needed as:
- VM sizes are now specified per VM in CSV
- OS images are specified per VM in CSV  
- Storage standards are hardcoded in Python code

## Changes Made:
1. **VM Sizes**: Moved from variable groups to CSV (`vm_size` column)
2. **OS Images**: Moved from variable groups to CSV (`os_publisher`, `os_offer`, `os_sku`, `os_version` columns)
3. **Storage Standards**: Hardcoded in Python script for consistency:
   - `os_disk_type: "StandardSSD_LRS"`
   - `data_disk_type: "StandardSSD_LRS"`
   - `disk_caching: "ReadWrite"`
   - `data_disk_caching: "None"`

## Benefits:
- **Flexibility**: Each VM can have different sizes and OS versions as needed
- **Simplicity**: Reduced variable group complexity
- **Consistency**: Storage standards enforced across all deployments
- **Maintainability**: OS updates can be managed per VM in CSV