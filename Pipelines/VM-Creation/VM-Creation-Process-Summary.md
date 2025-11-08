# 🚀 VM Creation Process - Complete Summary
**Date:** November 7, 2025  
**Environment:** CloudOps Azure Infrastructure  
**Agent Pool:** `cloudops-agent` (Self-hosted Windows Agent)

## 📋 **Process Overview**

### **Architecture Components:**
1. **Azure DevOps Pipelines** - Orchestration layer
2. **Self-hosted Agent** - `cloudops-agent` pool for local state management
3. **Python Script** - Dynamic Terraform generation
4. **CSV Configuration** - VM specifications and flexibility
5. **Variable Groups** - Environment-specific secure configuration
6. **Local State Management** - Agent server file system storage

---

## 🔧 **Pipeline Configuration**

### **1. Apply/Modify Pipeline: `Terraform-Apply-Modify-Working.yml`**
```yaml
# Key Features:
- Agent Pool: cloudops-agent
- Environments: DEV, SIT
- Actions: apply, modify
- State Storage: C:\TerraformState\Project\{ProjectName}\{Environment}\
```

**Pipeline Flow:**
1. **Environment Setup** → Set variables based on environment parameter
2. **Azure Authentication** → Service Principal login using ARM credentials
3. **State Management** → Create/copy state files from persistent location
4. **Python Generation** → Execute CSV-to-Terraform conversion
5. **Terraform Execution** → Init → Validate → Plan → Apply
6. **State Persistence** → Copy state back to agent storage location
7. **Artifact Upload** → Store Terraform files for reference

### **2. Destroy Pipeline: `Terraform-Destroy-pipeline.yml`**
```yaml
# Key Features:
- Agent Pool: cloudops-agent
- Selective Destroy: Target specific resources if needed
- State Cleanup: Remove state files after successful destroy
```

**Pipeline Flow:**
1. **Environment Setup** → Load environment-specific configuration
2. **Azure Authentication** → Service Principal login
3. **State Preparation** → Copy existing state to working directory
4. **Python Generation** → Regenerate Terraform configuration
5. **Terraform Destroy** → Execute destroy operation
6. **State Cleanup** → Remove state files after successful destroy

---

## 🔐 **Authentication & Security**

### **Azure Authentication Method:**
```bash
# Service Principal Authentication (from Variable Groups)
az login --service-principal \
    -u $(ARM_CLIENT_ID) \
    -p $(ARM_CLIENT_SECRET) \
    --tenant $(ARM_TENANT_ID)
```

### **Variable Groups Structure:**
**TerraformVariables** (Shared):
- `ARM_CLIENT_ID` - Service Principal ID
- `ARM_CLIENT_SECRET` - Service Principal Secret
- `ARM_TENANT_ID` - Azure Tenant ID

**VM-Creation-DEV** (DEV Environment):
- `subscription_id` - DEV subscription
- `vnet_name`, `vnet_rg`, `subnet_rg` - Network configuration
- `keyvault_name`, `keyvault_rg` - Key Vault for secrets
- `location` - Azure region
- Environment-specific configurations

**VM-Creation-SIT** (SIT Environment):
- Same structure as DEV but with SIT-specific values
- Separate subscription, networks, and resources

---

## 💾 **Local State Management**

### **State Directory Structure:**
```
C:\TerraformState\
└── Project\
    └── BaaS-Platform\
        ├── DEV\
        │   ├── terraform.tfstate
        │   └── .terraform.lock.hcl
        └── SIT\
            ├── terraform.tfstate
            └── .terraform.lock.hcl
```

### **State Management Benefits:**
- ✅ **Fast Access** - No network latency
- ✅ **Simple Setup** - No storage account needed
- ✅ **Direct Control** - Files accessible on agent
- ✅ **Environment Isolation** - Separate directories per environment
- ✅ **Cost Effective** - No storage costs

### **State Operations:**
```bash
# During Apply/Modify:
1. Create state directory: mkdir -p "$(TF_STATE_PATH)"
2. Copy existing state: cp "$(TF_STATE_PATH)/terraform.tfstate" ./
3. Run Terraform operations
4. Save updated state: cp terraform.tfstate "$(TF_STATE_PATH)/"

# During Destroy:
1. Copy state to working directory
2. Run terraform destroy
3. Remove state files after successful destroy
```

---

## 📊 **CSV Configuration Structure**

### **File: `simplified-vms.csv` (17 Columns)**
| Column | Purpose | Example | Source |
|--------|---------|---------|---------|
| `vm_name` | VM identifier | `DABASDBRDDLV01` | Manual |
| `resource_group` | Target RG | `bab-dev-baas-swec-rg-01` | Manual |
| `vm_role` | VM function | `db_server` | Manual |
| `subnet_type` | Subnet category | `db`, `app`, `web` | Manual |
| `subnet_index` | Subnet instance | `0`, `1`, `2` | Manual |
| `static_ip` | Fixed IP | `10.189.56.223` | Manual |
| `vm_size` | Azure VM SKU | `Standard_E4s_v5` | **CSV** |
| `os_type` | OS category | `linux`, `windows` | **CSV** |
| `os_publisher` | Image publisher | `RedHat`, `MicrosoftWindowsServer` | **CSV** |
| `os_offer` | Image offer | `RHEL`, `WindowsServer` | **CSV** |
| `os_sku` | Image SKU | `92-gen2`, `2022-Datacenter` | **CSV** |
| `os_version` | Image version | `latest` | **CSV** |
| `disk_1_size` | OS disk size | `256` | **CSV** |
| `disk_2_size` | Data disk 1 | `512` | **CSV** |
| `disk_3_size` | Data disk 2 | `1024` | **CSV** |
| `custom_tags` | VM-specific tags | `Application name=BaaS Platform` | Manual |
| `create_rg` | Create RG flag | `true`, `false` | Manual |

---

## 🐍 **Python Script: `generate-tf-v2-enhanced.py`**

### **Key Capabilities:**
1. **Environment Variables** → Reads from pipeline variable groups
2. **CSV Processing** → Parses VM specifications
3. **Terraform Generation** → Creates main.tf dynamically
4. **Local Backend** → Configures local state backend
5. **Standards Enforcement** → Hardcoded storage configurations

### **Hardcoded Standards:**
```python
storage_standards = {
    'os_disk_type': 'StandardSSD_LRS',        # Cost optimization
    'data_disk_type': 'StandardSSD_LRS',      # Consistency
    'disk_caching': 'ReadWrite',              # OS disk caching
    'data_disk_caching': 'None'               # Data disk caching
}
```

### **Auto-shutdown Configuration:**
```python
shutdown_config = {
    'enabled': True,                          # Always enabled
    'time': '2000',                          # 8 PM shutdown
    'timezone': 'W. Europe Standard Time'    # Swedish timezone
}
```

---

## 🏗️ **Generated Terraform Structure**

### **Main Components:**
1. **Provider Configuration** → Azure RM provider with subscription
2. **Data Sources** → Key Vault, VNet, Subnets, OS images
3. **Resource Groups** → Created based on CSV `create_rg` flag
4. **Virtual Machines** → Generated per CSV row
5. **Network Interfaces** → With static IP assignments
6. **Managed Disks** → OS and data disks per specifications
7. **Extensions** → Azure Monitor Agent, diagnostics
8. **Auto-shutdown** → Cost optimization schedules

### **Local Backend Configuration:**
```hcl
terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}
```

---

## 🔄 **Execution Workflow**

### **Apply/Modify Operation:**
```
1. Pipeline Trigger (Manual with parameters)
   ├── Environment: DEV/SIT
   ├── Action: apply/modify
   └── Project: BaaS-Platform

2. Environment Setup
   ├── Load variable group: VM-Creation-{ENV}
   ├── Set environment variables
   └── Create state directory structure

3. Azure Authentication
   ├── Service Principal login
   └── Subscription context switch

4. Python Terraform Generation
   ├── Read CSV file
   ├── Process environment variables
   ├── Generate main.tf
   └── Apply hardcoded standards

5. Terraform Execution
   ├── Copy existing state (if exists)
   ├── terraform init (local backend)
   ├── terraform validate
   ├── terraform plan
   └── terraform apply

6. State Management
   ├── Copy state to persistent location
   └── Preserve lock files

7. Artifact Storage
   └── Upload Terraform files for reference
```

### **Destroy Operation:**
```
1. Pipeline Trigger (Manual with environment)
2. Load existing state from agent storage
3. Generate Terraform configuration
4. Execute terraform destroy
5. Clean up state files after success
```

---

## ⚡ **Key Benefits**

### **Security:**
- ✅ Service Principal authentication
- ✅ Variable groups for credential management
- ✅ No hardcoded secrets in code

### **Flexibility:**
- ✅ CSV-driven VM specifications
- ✅ Environment-specific configurations
- ✅ Support for multiple VM sizes and OS types

### **Consistency:**
- ✅ Hardcoded storage standards
- ✅ Standardized tagging
- ✅ Enforced auto-shutdown policies

### **Reliability:**
- ✅ Local state management (fast, direct)
- ✅ Environment isolation
- ✅ Pipeline artifact preservation

### **Cost Optimization:**
- ✅ StandardSSD_LRS for cost efficiency
- ✅ Automatic VM shutdown at 8 PM
- ✅ No storage account costs for state

---

## 🚨 **Important Considerations**

### **Agent Dependencies:**
- **Self-hosted Agent Required** → Uses `cloudops-agent` pool
- **State Storage Location** → `C:\TerraformState\Project`
- **Agent Persistence** → State tied to specific agent server

### **Environment Requirements:**
- **Python 3.9** → Required for script execution
- **Terraform** → Must be installed on agent
- **Azure CLI** → For authentication and resource access

### **Backup Strategy:**
- **State Directory Backup** → Recommended for disaster recovery
- **CSV File Versioning** → Track VM specification changes
- **Pipeline Artifacts** → Preserved for audit and rollback

---

## 📈 **Usage Examples**

### **Deploy New VMs:**
```
Pipeline: Terraform-Apply-Modify-Working.yml
Parameters:
- Action: apply
- Environment: DEV
- Project: BaaS-Platform
```

### **Modify Existing VMs:**
```
Pipeline: Terraform-Apply-Modify-Working.yml
Parameters:
- Action: modify
- Environment: DEV
- Project: BaaS-Platform
```

### **Destroy All Resources:**
```
Pipeline: Terraform-Destroy-pipeline.yml
Parameters:
- Environment: DEV
- Destroy Specific Targets: No
```

### **Destroy Specific Resources:**
```
Pipeline: Terraform-Destroy-pipeline.yml
Parameters:
- Environment: DEV
- Destroy Specific Targets: Yes
- Destroy Targets: "azurerm_virtual_machine.vm_DABASDBRDDLV01"
```

This comprehensive VM creation process provides secure, scalable, and maintainable infrastructure automation for Azure environments.