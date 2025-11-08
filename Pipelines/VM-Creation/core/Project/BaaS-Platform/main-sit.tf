
terraform {
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
  
  # Local backend - state stored on agent server
  # Path: C:\TerraformState\Project\BaaS-Platform\SIT\terraform.tfstate
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    virtual_machine {
      delete_os_disk_on_deletion = true
    }
  }
  subscription_id = "12345678-1234-1234-1234-123456789012"
}

variable "location" {
  description = "Location for resources"
  type        = string
  default     = "swedencentral"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "SIT"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "BaaS-Platform"
}

# Common data sources
data "azurerm_virtual_network" "main_vnet" {
  name                = "vnet-baas-sit-001"
  resource_group_name = "rg-networking-sit"
}

data "azurerm_key_vault" "main_kv" {
  name                = "kv-baas-sit-001"
  resource_group_name = "rg-security-sit"
}

data "azurerm_monitor_data_collection_rule" "main_dcr" {
  name                = "dcr-baas-sit-001"
  resource_group_name = "rg-monitoring-sit"
}

# ==== Resource Groups ====

resource "azurerm_resource_group" "ankoji_test_01_rg" {
  name     = "ankoji-test-01"
  location = var.location

  tags = {
    "Company" = "BAB",
    "Department" = "Information Technology",
    "ProjectName" = "pilot-test",
    "ApplicationName" = "pilot-test",
    "StartDate" = "2025-11-08",
    "EndDate" = "2025-11-08",
    "Region" = "Sweden Central",
    "ApproverName" = "pilot-test",
    "RequesterName" = "CloudOps Team",
    "BusinessOwner" = "pilot-test",
    "TechnicalOwner" = "pilot-test",
    "CostCenter" = "pilot-test",
    "ServiceClass" = "pilot-test",
    "ManagedBy" = "CloudOps Team",
    "CreatedBy" = "Terraform",
    "CreationDate" = "2025-11-08",
    "Environment" = "SIT",
    "Project" = "BaaS-Platform"
  }
}

# ==== ankoji-test-01 Resources ====

# Subnet data source
data "azurerm_subnet" "ankoji-test-01_subnet" {
  name                 = "snet-sit-nonpci-app-02"
  virtual_network_name = data.azurerm_virtual_network.main_vnet.name
  resource_group_name  = "rg-networking-sit"
}

# Admin password from Key Vault
data "azurerm_key_vault_secret" "ankoji-test-01_admin_password" {
  name         = "azureadmin"
  key_vault_id = data.azurerm_key_vault.main_kv.id
}

# Network Interface
resource "azurerm_network_interface" "ankoji-test-01_nic" {
  name                = "ankoji-test-01-nic"
  location            = var.location
  resource_group_name = azurerm_resource_group.ankoji_test_01_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.ankoji-test-01_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.189.57.162"
  }

  tags = {
    "Company" = "BAB",
    "Department" = "Information Technology",
    "ProjectName" = "pilot-test",
    "ApplicationName" = "pilot-test",
    "StartDate" = "2025-11-08",
    "EndDate" = "2025-11-08",
    "Region" = "Sweden Central",
    "ApproverName" = "pilot-test",
    "RequesterName" = "CloudOps Team",
    "BusinessOwner" = "pilot-test",
    "TechnicalOwner" = "pilot-test",
    "CostCenter" = "pilot-test",
    "ServiceClass" = "pilot-test",
    "ManagedBy" = "CloudOps Team",
    "CreatedBy" = "Terraform",
    "CreationDate" = "2025-11-08",
    "Environment" = "SIT",
    "Project" = "BaaS-Platform"
  }
}

# Windows Virtual Machine
resource "azurerm_windows_virtual_machine" "ankoji-test-01" {
  name                = "ankoji-test-01"
  resource_group_name = azurerm_resource_group.ankoji_test_01_rg.name
  location            = var.location
  size                = "Standard_B2s"

  network_interface_ids = [
    azurerm_network_interface.ankoji-test-01_nic.id
  ]

  admin_username = "azureadmin"
  admin_password = data.azurerm_key_vault_secret.ankoji-test-01_admin_password.value
  license_type   = "Windows_Server"

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2019-Datacenter"
    version   = "latest"
  }
  
  boot_diagnostics {
    storage_account_uri = "https://stdiagnosticssit001.blob.core.windows.net/"
  }

  tags = {
    "Company" = "BAB",
    "Department" = "Information Technology",
    "ProjectName" = "pilot-test",
    "ApplicationName" = "pilot-test",
    "StartDate" = "2025-11-08",
    "EndDate" = "2025-11-08",
    "Region" = "Sweden Central",
    "ApproverName" = "pilot-test",
    "RequesterName" = "CloudOps Team",
    "BusinessOwner" = "pilot-test",
    "TechnicalOwner" = "pilot-test",
    "CostCenter" = "pilot-test",
    "ServiceClass" = "pilot-test",
    "ManagedBy" = "CloudOps Team",
    "CreatedBy" = "Terraform",
    "CreationDate" = "2025-11-08",
    "Environment" = "SIT",
    "Project" = "BaaS-Platform"
  }
}

# Azure Monitor Agent
resource "azurerm_virtual_machine_extension" "ankoji-test-01_ama" {
  name                       = "AzureMonitorWindowsAgent"
  virtual_machine_id         = azurerm_windows_virtual_machine.ankoji-test-01.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorWindowsAgent"
  type_handler_version       = "1.30"
  automatic_upgrade_enabled  = true

  tags = {
    "Company" = "BAB",
    "Department" = "Information Technology",
    "ProjectName" = "pilot-test",
    "ApplicationName" = "pilot-test",
    "StartDate" = "2025-11-08",
    "EndDate" = "2025-11-08",
    "Region" = "Sweden Central",
    "ApproverName" = "pilot-test",
    "RequesterName" = "CloudOps Team",
    "BusinessOwner" = "pilot-test",
    "TechnicalOwner" = "pilot-test",
    "CostCenter" = "pilot-test",
    "ServiceClass" = "pilot-test",
    "ManagedBy" = "CloudOps Team",
    "CreatedBy" = "Terraform",
    "CreationDate" = "2025-11-08",
    "Environment" = "SIT",
    "Project" = "BaaS-Platform"
  }
}

# Data Collection Rule Association
resource "azurerm_monitor_data_collection_rule_association" "ankoji-test-01_dcr_assoc" {
  name                    = "dcr-baas-sit-001"
  target_resource_id      = azurerm_windows_virtual_machine.ankoji-test-01.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.main_dcr.id
}

# Custom Script Extension
resource "azurerm_virtual_machine_extension" "ankoji-test-01_script" {
  name                 = "CustomScriptExtension"
  virtual_machine_id   = azurerm_windows_virtual_machine.ankoji-test-01.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.9"

  settings = jsonencode({
    fileUris = ["https://babcloudopsscripts.blob.core.windows.net/vm-scripts/windows-postconf-script-secure.ps1"]
    commandToExecute = "powershell -ExecutionPolicy Unrestricted -File windows-postconf-script-secure.ps1"
  })

  tags = {
    "Company" = "BAB",
    "Department" = "Information Technology",
    "ProjectName" = "pilot-test",
    "ApplicationName" = "pilot-test",
    "StartDate" = "2025-11-08",
    "EndDate" = "2025-11-08",
    "Region" = "Sweden Central",
    "ApproverName" = "pilot-test",
    "RequesterName" = "CloudOps Team",
    "BusinessOwner" = "pilot-test",
    "TechnicalOwner" = "pilot-test",
    "CostCenter" = "pilot-test",
    "ServiceClass" = "pilot-test",
    "ManagedBy" = "CloudOps Team",
    "CreatedBy" = "Terraform",
    "CreationDate" = "2025-11-08",
    "Environment" = "SIT",
    "Project" = "BaaS-Platform"
  }
}

# Data Disk 1
resource "azurerm_managed_disk" "ankoji-test-01_DataDisk_0" {
  name                 = "ankoji-test-01_DataDisk_0"
  location             = var.location
  resource_group_name  = azurerm_resource_group.ankoji_test_01_rg.name
  storage_account_type = "StandardSSD_LRS"
  disk_size_gb         = 16
  create_option        = "Empty"
}

resource "azurerm_virtual_machine_data_disk_attachment" "ankoji-test-01_disk_1_attach" {
  managed_disk_id    = azurerm_managed_disk.ankoji-test-01_DataDisk_0.id
  virtual_machine_id = azurerm_windows_virtual_machine.ankoji-test-01.id
  lun                = 0
  create_option      = "Attach"
  caching            = "None"
}

# Auto Shutdown Schedule (Hardcoded Configuration)
resource "azurerm_dev_test_global_vm_shutdown_schedule" "ankoji-test-01_shutdown" {
  virtual_machine_id = azurerm_windows_virtual_machine.ankoji-test-01.id
  location           = var.location
  enabled            = true

  daily_recurrence_time = "2000"
  timezone              = "Arab Standard Time"

  notification_settings {
    enabled = false
  }

  tags = {
    "Company" = "BAB",
    "Department" = "Information Technology",
    "ProjectName" = "pilot-test",
    "ApplicationName" = "pilot-test",
    "StartDate" = "2025-11-08",
    "EndDate" = "2025-11-08",
    "Region" = "Sweden Central",
    "ApproverName" = "pilot-test",
    "RequesterName" = "CloudOps Team",
    "BusinessOwner" = "pilot-test",
    "TechnicalOwner" = "pilot-test",
    "CostCenter" = "pilot-test",
    "ServiceClass" = "pilot-test",
    "ManagedBy" = "CloudOps Team",
    "CreatedBy" = "Terraform",
    "CreationDate" = "2025-11-08",
    "Environment" = "SIT",
    "Project" = "BaaS-Platform"
  }
}

# ==== Outputs ====

output "vm_private_ips" {
  description = "Private IP addresses of all VMs"
  value = {
    "ankoji-test-01" = azurerm_network_interface.ankoji-test-01_nic.private_ip_address
  }
}

output "vm_resource_groups" {
  description = "Resource groups containing the VMs"
  value = {
    "ankoji-test-01" = azurerm_network_interface.ankoji-test-01_nic.resource_group_name
  }
}

output "deployment_summary" {
  description = "Deployment summary information"
  value = {
    environment     = var.environment
    vm_count       = length(["ankoji-test-01"])
    project_name   = "BaaS-Platform"
    deployment_time = timestamp()
  }
}
