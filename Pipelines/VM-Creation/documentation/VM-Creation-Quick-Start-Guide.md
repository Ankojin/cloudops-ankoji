# VM Creation - Complete Quick Start Guide

## 🚀 Overview

Automated Azure VM creation using Terraform, Azure DevOps pipelines, and CSV-driven configuration with enterprise-grade security and multi-OS support.

### ✨ Key Features
- **CSV-driven VM specifications** - Easy bulk VM creation
- **Multi-OS support** - Windows and Linux with appropriate post-configuration
- **Azure Key Vault integration** - Secure credential management
- **Dynamic tagging** - Environment-specific tag configuration
- **Local state management** - No Azure Storage backend required
- **Cloud-init & post-config scripts** - Automated VM setup

## 🏗️ Architecture

```
CSV Input → Python Script → Terraform Config → Azure DevOps Pipeline → Azure VMs
     ↓              ↓              ↓                    ↓              ↓
   VM Specs    TF Generation   Infrastructure     Post-Config    Ready VMs
```

### 🔧 Core Components
- **Python Script**: `generate-tf-v2-enhanced.py` - Generates Terraform from CSV
- **CSV Template**: `simplified-vms.csv` - VM specifications
- **Pipelines**: Deploy and destroy automation
- **Post-Config Scripts**: OS-specific setup (domain join, disk formatting)
- **Cloud-init**: Linux VM initialization

## 📋 Prerequisites

### 🖥️ Agent Requirements (cloudops-agent)
- **Python 3.13+** with required modules
- **Terraform 1.11.4+** 
- **Azure CLI** with authentication
- **PowerShell** for pipeline tasks

### 🔐 Azure Requirements
- **Azure DevOps project** with agent pool
- **Service Principal** with VM creation permissions
- **Azure Key Vault** for domain join credentials
- **Storage Account** for post-configuration scripts

## ⚙️ Setup Instructions

### 1️⃣ Variable Groups Configuration

Create **3 variable groups** in Azure DevOps:

#### **TerraformVariables** (Global)
```yaml
ARM_CLIENT_ID: [SERVICE-PRINCIPAL-ID] (Secret)
ARM_CLIENT_SECRET: [SERVICE-PRINCIPAL-SECRET] (Secret)  
ARM_TENANT_ID: [TENANT-ID] (Secret)
```

#### **VM-Creation-DEV** (17 variables)
```yaml
# Infrastructure
subscription_id: [DEV-SUBSCRIPTION-ID] (Secret)
location: swedencentral
vnet_name: vnet-baas-dev-001
vnet_rg: rg-networking-dev
subnet_rg: rg-networking-dev
keyvault_name: kv-baas-dev-001
keyvault_rg: rg-security-dev
dcr_name: dcr-baas-dev-001
dcr_rg: rg-monitoring-dev
diagnostics_storage: stdiagnosticsdev001
diagnostics_storage_rg: rg-diagnostics-dev
script_storage_account: stscriptsdev001
script_storage_container: scripts
script_blob_name_linux: linuxpostconf.sh
script_blob_name_windows: windows-postconf-script-secure.ps1

# Subnets (JSON format)
subnets_config: {"app": ["subnet-app-dev-001", "subnet-app-dev-002"], "db": ["subnet-db-dev-001"], "web": ["subnet-web-dev-001", "subnet-web-dev-002"], "mgmt": ["subnet-mgmt-dev-001"]}

# Tags (JSON format - RECOMMENDED)
default_tags_json: {
  "Company": "BAB",
  "Department": "Information Technology", 
  "ProjectName": "BaaS Platform Migration",
  "ApplicationName": "Banking as a Service",
  "StartDate": "2025-01-01",
  "EndDate": "2025-12-31",
  "Region": "Sweden Central",
  "ApproverName": "IT Director",
  "RequesterName": "CloudOps Team",
  "BusinessOwner": "Banking Operations Manager",
  "TechnicalOwner": "Infrastructure Team Lead",
  "CostCenter": "IT-INFRA-001",
  "ServiceClass": "Development",
  "ManagedBy": "CloudOps Team"
}
```

#### **VM-Creation-SIT** (17 variables)
Same as DEV but with:
- `subscription_id`: [SIT-SUBSCRIPTION-ID]
- Resource names: Replace `-dev-` with `-sit-`
- `tag_cost_center`: `IT-INFRA-002`
- `tag_service_class`: `Testing`
- `tag_managed_by`: `QA Team`

### 2️⃣ Azure Key Vault Setup

Store domain join password securely:

```powershell
# DEV Environment
Set-AzKeyVaultSecret -VaultName "kv-baas-dev-001" -Name "adjoin-password" -SecretValue (ConvertTo-SecureString "AdJo1n@!qaz@wsx" -AsPlainText -Force)

# SIT Environment  
Set-AzKeyVaultSecret -VaultName "kv-baas-sit-001" -Name "adjoin-password" -SecretValue (ConvertTo-SecureString "AdJo1n@!qaz@wsx" -AsPlainText -Force)
```

### 3️⃣ Storage Account Setup

Upload post-configuration scripts:

```bash
# Upload to DEV storage
az storage blob upload --account-name stscriptsdev001 --container-name scripts --file linuxpostconf.sh --name linuxpostconf.sh
az storage blob upload --account-name stscriptsdev001 --container-name scripts --file windows-postconf-script-secure.ps1 --name windows-postconf-script-secure.ps1

# Upload to SIT storage  
az storage blob upload --account-name stscriptssit001 --container-name scripts --file linuxpostconf.sh --name linuxpostconf.sh
az storage blob upload --account-name stscriptssit001 --container-name scripts --file windows-postconf-script-secure.ps1 --name windows-postconf-script-secure.ps1
```

## 📝 CSV Configuration

### Sample VM Specification (`simplified-vms.csv`):

```csv
vm_name,resource_group,location,vm_size,os_type,os_publisher,os_offer,os_sku,admin_username,subnet_name,vnet_name,vnet_rg,enable_boot_diagnostics,data_disk_count,data_disk_size_gb,tags,notes
web01-dev,rg-web-dev,swedencentral,Standard_B2s,linux,Canonical,0001-com-ubuntu-server-focal,20_04-lts-gen2,azureuser,subnet-web-dev-001,vnet-baas-dev-001,rg-networking-dev,true,2,128,Environment=DEV;Tier=Web,Web server
db01-dev,rg-db-dev,swedencentral,Standard_D2s_v3,windows,MicrosoftWindowsServer,WindowsServer,2022-datacenter-g2,azureuser,subnet-db-dev-001,vnet-baas-dev-001,rg-networking-dev,true,1,512,Environment=DEV;Tier=Database,Database server
```

### 📊 CSV Field Guide:

| Field | Description | Example | Required |
|-------|-------------|---------|----------|
| `vm_name` | VM name | `web01-dev` | Yes |
| `resource_group` | Target RG | `rg-web-dev` | Yes |
| `location` | Azure region | `swedencentral` | Yes |
| `vm_size` | VM SKU | `Standard_B2s` | Yes |
| `os_type` | `linux` or `windows` | `linux` | Yes |
| `os_publisher` | Image publisher | `Canonical` | Yes |
| `os_offer` | Image offer | `0001-com-ubuntu-server-focal` | Yes |
| `os_sku` | Image SKU | `20_04-lts-gen2` | Yes |
| `admin_username` | VM admin user | `azureuser` | Yes |
| `subnet_name` | Target subnet | `subnet-web-dev-001` | Yes |
| `vnet_name` | Virtual network | `vnet-baas-dev-001` | Yes |
| `vnet_rg` | VNet resource group | `rg-networking-dev` | Yes |
| `enable_boot_diagnostics` | `true` or `false` | `true` | Yes |
| `data_disk_count` | Number of data disks | `2` | Yes |
| `data_disk_size_gb` | Data disk size | `128` | Yes |
| `tags` | Additional tags | `Tier=Web;Owner=TeamA` | Optional |
| `notes` | Description | `Web server for app` | Optional |

## 🚀 Pipeline Execution

### Deploy VMs:
```yaml
# Navigate to Pipelines → VM-Creation → Terraform-Apply-Modify-Working
# Select Environment: DEV or SIT
# Select Project: vm-creation
# Run Pipeline
```

### Destroy VMs:
```yaml
# Navigate to Pipelines → VM-Creation → Terraform-Destroy-pipeline  
# Select Environment: DEV or SIT
# Select Project: vm-creation
# Run Pipeline
```

## 🖥️ Post-Configuration Features

### 🐧 Linux VMs (`linuxpostconf.sh`)
- **Disk Management**: LVM with XFS formatting
- **Security**: Firewall and SELinux disable
- **User Management**: Creates `unixadmin` user
- **System Config**: Timezone, domain search setup
- **Mount Points**: `/u01`, `/u02`, etc. for data disks

### 🪟 Windows VMs (`windows-postconf-script-secure.ps1`)
- **Disk Management**: NTFS formatting with GPT
- **Domain Join**: Secure join using Key Vault credentials
- **Security**: Firewall disable, RemoteSigned execution policy
- **System Config**: Timezone setup
- **Drive Letters**: F:, G:, etc. for data disks

## 🔧 Testing

### Local Testing:
```bash
cd VM-Creation
python test-vm-creation.py
```

### Terraform Validation:
```bash
terraform validate
terraform plan -out=tfplan
```

## 🐛 Troubleshooting

### Common Issues:

#### **CSV Parsing Errors**
- **Cause**: Invalid CSV format, missing quotes
- **Solution**: Validate CSV with Excel, check for special characters

#### **Key Vault Access Denied**  
- **Cause**: VM managed identity not configured
- **Solution**: Enable system-assigned identity, grant Key Vault access

#### **Script Download Failed**
- **Cause**: Storage account permissions
- **Solution**: Verify blob exists, check SAS token/managed identity

#### **Domain Join Failed**
- **Cause**: Network connectivity, credentials
- **Solution**: Check DNS, verify Key Vault password, check domain controller

#### **Terraform State Lock**
- **Cause**: Previous run didn't clean up
- **Solution**: Delete `.terraform.lock.hcl` and state files

### 📊 Debugging Tips:

1. **Check Pipeline Logs**: Look for Python script output and Terraform logs
2. **Verify Variables**: Ensure all variable groups are correctly configured  
3. **Test Components**: Use `test-vm-creation.py` to validate Python script
4. **Check Resources**: Verify Key Vault, storage accounts, and networking exist
5. **VM Logs**: Check `C:\WindowsAzure\postconf.txt` (Windows) or `/var/log/` (Linux)

## 🎯 Best Practices

### ✅ Security
- **Never hardcode credentials** in scripts or CSV files
- **Use Key Vault** for all sensitive data
- **Enable managed identity** on VMs
- **Regular credential rotation**

### ✅ Maintenance  
- **Update CSV templates** for new VM patterns
- **Version control** all configuration files
- **Test in DEV** before SIT deployment
- **Monitor resource costs**

### ✅ Operations
- **Use descriptive VM names** with environment suffix
- **Consistent tagging** for cost management
- **Document network requirements** 
- **Plan capacity** for storage and compute

## 📈 Scaling & Extensions

### Future Enhancements:
- **Azure Monitor integration** for VM monitoring
- **Backup policy automation** 
- **Network Security Group** automation
- **Load balancer** configuration
- **Azure Update Management** enrollment

### Additional Features:
- **Multi-region deployment** support
- **Custom VM images** integration  
- **Disaster recovery** configuration
- **Cost optimization** rules

---

## 🎯 Quick Reference

### **Essential Files:**
- `generate-tf-v2-enhanced.py` - Main script
- `simplified-vms.csv` - VM specs
- `Terraform-Apply-Modify-Working.yml` - Deploy pipeline
- `Copy-Paste-Variable-Values.md` - Variable group setup

### **Key Commands:**
```bash
# Test locally
python test-vm-creation.py

# Validate Terraform  
terraform validate

# Check variable groups
# Azure DevOps → Project Settings → Pipelines → Variable Groups
```

### **Support:**
- **Logs**: Pipeline logs and VM post-config logs
- **Documentation**: This guide and `Copy-Paste-Variable-Values.md`
- **Testing**: Use test scripts before production deployment

**🎉 Your enterprise VM creation automation is ready!**